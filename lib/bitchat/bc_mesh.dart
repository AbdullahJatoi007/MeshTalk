// bitchat-compatible mesh over Bluetooth LE: lets MeshTalk users and bitchat
// users see each other and exchange public chat. Runs next to (not instead
// of) MeshTalk's Nearby mesh. Behaviour follows bitchat's WHITEPAPER.md and
// public-domain iOS sources.

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/dart.dart';

import 'bc_protocol.dart';

/// Direct BLE links to nearby bitchat-speaking phones (BitchatBle.kt).
abstract class BcLinkTransport {
  void Function(String link)? onLinkUp;
  void Function(String link)? onLinkDown;
  void Function(String link, Uint8List data)? onData;

  Set<String> get links;

  /// Largest single write/notification for [link] (ATT MTU - 3).
  int maxWrite(String link);

  Future<void> start();
  Future<void> stop();
  Future<bool> send(String link, Uint8List data);
}

class BcPeer {
  BcPeer({
    required this.id,
    required this.nickname,
    required this.noiseKey,
    required this.signingKey,
    required this.isMeshTalk,
    required this.lastSeen,
    required this.hops,
  });

  final String id; // 16 hex chars, same scheme as MeshTalk node ids
  String nickname;
  Uint8List noiseKey;
  Uint8List signingKey;
  bool isMeshTalk;
  int lastSeen;
  int hops; // approximate
}

class BcPublicMessage {
  BcPublicMessage({
    required this.key,
    required this.senderId,
    required this.nickname,
    required this.text,
    required this.timestamp,
    required this.hops,
    required this.fromMeshTalk,
  });

  final String key; // bitchat dedup key
  final String senderId;
  final String nickname;
  final String text;
  final int timestamp;
  final int hops;
  final bool fromMeshTalk;
}

typedef BcSign = Future<Uint8List> Function(List<int> message);
typedef BcVerify = Future<bool> Function(
    List<int> message, List<int> signature, List<int> publicKey);

class BitchatMesh {
  BitchatMesh({
    required this.selfId,
    required this.noiseKey,
    required this.signingKey,
    required this.sign,
    required this.verify,
    required this.transport,
    required this.nickname,
    int Function()? clock,
    Random? random,
  })  : _now = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
        _rand = random ?? Random() {
    transport.onData = _onLinkData;
    transport.onLinkUp = _onLinkUp;
    transport.onLinkDown = _onLinkDown;
  }

  final String selfId;
  final Uint8List noiseKey;
  final Uint8List signingKey;
  final BcSign sign;
  final BcVerify verify;
  final BcLinkTransport transport;
  final String Function() nickname;
  final int Function() _now;
  final Random _rand;

  // ── tuning (bitchat values where it has them) ─────────────────────────
  static const seenCapacity = 1000;
  static const seenTtlMs = 5 * 60 * 1000;
  static const peerTtlMs = 90 * 1000;
  static const maxClockSkewMs = 6 * 60 * 60 * 1000; // public history window
  static const pendingTtlMs = 2 * 60 * 1000;
  static const bridgeLink = 'bridge';

  /// Packet types we never relay (link-local in bitchat).
  static const _noRelay = {BcType.requestSync};

  // ── callbacks ─────────────────────────────────────────────────────────
  void Function(BcPublicMessage m)? onPublicMessage;
  void Function()? onPeersChanged;

  /// A packet that should also travel over MeshTalk's Nearby mesh so
  /// MeshTalk phones far from any bitchat user can bridge it. Receives the
  /// encoded packet (ttl already decremented for the hop).
  void Function(Uint8List encoded, String dedupKey)? onBridgeOut;

  final Map<String, BcPeer> peers = {};
  final LinkedHashMap<String, int> _seen = LinkedHashMap();
  final Map<String, BcStreamAssembler> _assemblers = {};
  final BcFragmentAssembler _fragments = BcFragmentAssembler();
  final Map<String, List<BcPacket>> _pendingUnverified = {};
  Timer? _announceTimer, _sweepTimer;
  bool running = false;

  Uint8List get _selfBytes => bcUnhex(selfId);
  int get linkCount => transport.links.length;

  // ── lifecycle ─────────────────────────────────────────────────────────

  Future<void> start() async {
    if (running) return;
    running = true;
    await transport.start();
    _scheduleAnnounce(initial: true);
    _sweepTimer = Timer.periodic(const Duration(seconds: 10), (_) => sweep());
  }

  Future<void> stop() async {
    running = false;
    _announceTimer?.cancel();
    _sweepTimer?.cancel();
    await transport.stop();
    _assemblers.clear();
    if (peers.isNotEmpty) {
      peers.clear();
      onPeersChanged?.call();
    }
  }

  /// bitchat announces every few seconds while isolated, every ~15–30 s
  /// once connected.
  void _scheduleAnnounce({bool initial = false}) {
    _announceTimer?.cancel();
    if (!running) return;
    final ms = initial
        ? 800
        : linkCount == 0
            ? 8000
            : 15000 + _rand.nextInt(15000);
    _announceTimer = Timer(Duration(milliseconds: ms), () async {
      await sendAnnounce();
      _scheduleAnnounce();
    });
  }

  // ── sending ───────────────────────────────────────────────────────────

  Future<BcPacket> _signed(int type, Uint8List payload) async {
    final p = BcPacket(
      type: type,
      ttl: BcConst.defaultTtl,
      timestamp: _now(),
      senderID: _selfBytes,
      payload: payload,
    );
    final pre = BcCodec.signingPreimage(p)!;
    p.signature = await sign(pre);
    return p;
  }

  Future<void> sendAnnounce() async {
    if (!running) return;
    final payload = BcAnnounce(
      nickname: nickname(),
      noiseKey: noiseKey,
      signingKey: signingKey,
      isMeshTalk: true,
    ).encode();
    final p = await _signed(BcType.announce, payload);
    _originate(p);
  }

  /// Sends public chat to bitchat users. Long text goes out as several
  /// messages of < 100 bytes each (see BcConst.maxSignedPayload).
  Future<void> sendPublic(String text) async {
    if (!running) return;
    final t = text.trim();
    if (t.isEmpty) return;
    for (final part in bcSplitText(t, BcConst.maxSignedPayload)) {
      final p = await _signed(BcType.message, Uint8List.fromList(utf8.encode(part)));
      _originate(p);
      // Keep parts in order: distinct millisecond timestamps.
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
  }

  void _originate(BcPacket p) {
    final enc = BcCodec.encode(p);
    if (enc == null) return;
    final key = p.dedupKey(_digest(p.payload));
    _markSeen(key);
    for (final l in transport.links) {
      _sendOnLink(l, p, enc);
    }
    onBridgeOut?.call(enc, key);
  }

  /// Sends [enc] on [link], fragmenting when it doesn't fit the link.
  void _sendOnLink(String link, BcPacket p, Uint8List enc) {
    final limit = transport.maxWrite(link);
    if (enc.length <= limit) {
      transport.send(link, enc);
      return;
    }
    // Same overhead budget as bitchat's fragmentChunkSize(forLinkLimit:).
    final chunk = max(32, limit - (BcConst.v1Header + 8 + 8 + BcFragments.headerBytes + 8));
    for (final f in BcFragments.split(p, enc, chunk)) {
      final fe = BcCodec.encode(f);
      if (fe != null && fe.length <= limit) transport.send(link, fe);
    }
  }

  // ── receiving ─────────────────────────────────────────────────────────

  void _onLinkUp(String link) {
    _assemblers[link] = BcStreamAssembler();
    // Announce soon so the new neighbour learns who we are.
    _announceTimer?.cancel();
    _announceTimer = Timer(Duration(milliseconds: 300 + _rand.nextInt(400)), () async {
      await sendAnnounce();
      _scheduleAnnounce();
    });
    onPeersChanged?.call();
  }

  void _onLinkDown(String link) {
    _assemblers.remove(link);
    onPeersChanged?.call();
  }

  void _onLinkData(String link, Uint8List data) {
    final asm = _assemblers.putIfAbsent(link, () => BcStreamAssembler());
    for (final frame in asm.add(data, _now())) {
      handleFrame(link, frame);
    }
  }

  /// A bitchat packet carried over MeshTalk's Nearby mesh by another
  /// MeshTalk phone.
  void injectFromBridge(Uint8List encoded) => handleFrame(bridgeLink, encoded);

  /// [relayToLinks] is false for a packet we rebuilt from fragments: the
  /// fragments themselves are already being relayed on Bluetooth.
  Future<void> handleFrame(String link, Uint8List frame,
      {bool relayToLinks = true}) async {
    final p = BcCodec.decode(frame);
    if (p == null) return;
    if (p.senderHex == selfId) return; // our own packet came back

    final key = p.dedupKey(_digest(p.payload));
    if (_isSeen(key)) return;
    _markSeen(key);

    final now = _now();
    final fresh = (p.timestamp - now).abs() <= maxClockSkewMs;

    var relayOk = true;
    switch (p.type) {
      case BcType.announce:
        relayOk = fresh && await _handleAnnounce(p);
      case BcType.message:
        if (fresh) await _handleMessage(p);
      case BcType.leave:
        relayOk = await _handleLeave(p);
      case BcType.fragment:
        final whole = _fragments.add(p, now);
        if (whole != null) {
          // Process the reassembled packet like any other (it carries its
          // own dedup key). The fragments themselves are relayed below.
          unawaited(handleFrame(link, whole, relayToLinks: false));
        }
      default:
        // Private (Noise), files, voice, sync…: not shown in MeshTalk yet,
        // but relayed so bitchat users can still reach each other through us.
        break;
    }
    if (relayOk) _relay(link, p, key, toLinks: relayToLinks);
  }

  Future<bool> _handleAnnounce(BcPacket p) async {
    final a = BcAnnounce.decode(p.payload);
    final sig = p.signature;
    if (a == null || sig == null) return false;
    // The sender id must be derived from the announced key…
    final derived = bcHex(_sha256(a.noiseKey).sublist(0, 8));
    if (derived != p.senderHex) return false;
    // …and signed by the announced signing key.
    final pre = BcCodec.signingPreimage(p);
    if (pre == null || !await verify(pre, sig, a.signingKey)) return false;

    final hops = _hopsFor(p);
    final existing = peers[p.senderHex];
    if (existing == null) {
      peers[p.senderHex] = BcPeer(
        id: p.senderHex,
        nickname: a.nickname,
        noiseKey: a.noiseKey,
        signingKey: a.signingKey,
        isMeshTalk: a.isMeshTalk,
        lastSeen: _now(),
        hops: hops,
      );
    } else {
      existing
        ..nickname = a.nickname
        ..noiseKey = a.noiseKey
        ..signingKey = a.signingKey
        ..isMeshTalk = a.isMeshTalk
        ..lastSeen = _now()
        ..hops = hops;
    }
    onPeersChanged?.call();

    // Messages that arrived before this announce can be checked now.
    final waiting = _pendingUnverified.remove(p.senderHex);
    if (waiting != null) {
      for (final m in waiting) {
        await _handleMessage(m);
      }
    }
    return true;
  }

  Future<void> _handleMessage(BcPacket p) async {
    if (!p.isBroadcast) return; // private/legacy forms are not public chat
    final sig = p.signature;
    if (sig == null) return; // bitchat requires signed public messages
    final peer = peers[p.senderHex];
    if (peer == null) {
      // No announce yet: hold it briefly until we learn the sender's key.
      final list = _pendingUnverified.putIfAbsent(p.senderHex, () => []);
      if (list.length < 20) list.add(p);
      return;
    }
    final pre = BcCodec.signingPreimage(p);
    if (pre == null || !await verify(pre, sig, peer.signingKey)) return;
    String text;
    try {
      text = utf8.decode(p.payload).trim();
    } catch (_) {
      return;
    }
    if (text.isEmpty) return;
    if (text.length > 2000) text = text.substring(0, 2000);
    onPublicMessage?.call(BcPublicMessage(
      key: p.dedupKey(_digest(p.payload)),
      senderId: p.senderHex,
      nickname: peer.nickname,
      text: text,
      timestamp: p.timestamp,
      hops: _hopsFor(p),
      fromMeshTalk: peer.isMeshTalk,
    ));
  }

  Future<bool> _handleLeave(BcPacket p) async {
    final peer = peers[p.senderHex];
    final sig = p.signature;
    if (peer == null || sig == null) return false;
    final pre = BcCodec.signingPreimage(p);
    if (pre == null || !await verify(pre, sig, peer.signingKey)) return false;
    peers.remove(p.senderHex);
    onPeersChanged?.call();
    return true;
  }

  int _hopsFor(BcPacket p) => (BcConst.defaultTtl + 1 - p.ttl).clamp(1, 7).toInt();

  // ── relaying (bitchat RelayController, simplified) ────────────────────

  void _relay(String ingress, BcPacket p, String key, {bool toLinks = true}) {
    if (_noRelay.contains(p.type)) return;
    if (p.recipientHex == selfId) return;
    final degree = linkCount;
    final ttlCap = min(p.ttl, BcConst.defaultTtl);
    if (ttlCap <= 1) return;

    final directed = p.recipientID != null && !p.isBroadcast;
    int newTtl;
    int delayMs;
    if (directed || p.type == BcType.noiseHandshake) {
      newTtl = ttlCap - 1;
      delayMs = 20 + _rand.nextInt(40);
    } else if (p.type == BcType.fragment || p.type == BcType.voiceFrame) {
      final cap = degree >= 6 ? 5 : 7;
      final limit = min(ttlCap, cap);
      if (limit <= 1) return;
      newTtl = limit - 1;
      delayMs = 10 + _rand.nextInt(40);
    } else {
      int limit;
      if (degree >= 6) {
        limit = max(2, min(ttlCap, 5));
      } else if (degree <= 2) {
        limit = ttlCap;
      } else {
        limit = max(2, min(ttlCap, p.type == BcType.announce ? 7 : 6));
      }
      newTtl = limit - 1;
      delayMs = degree <= 2
          ? 10 + _rand.nextInt(30)
          : degree <= 5
              ? 60 + _rand.nextInt(90)
              : 80 + _rand.nextInt(140);
    }
    if (newTtl < 1) return;

    final out = p.copyWith(ttl: newTtl);
    final enc = BcCodec.encode(out);
    if (enc == null) return;
    Timer(Duration(milliseconds: delayMs), () {
      if (!running) return;
      if (toLinks) {
        for (final l in transport.links) {
          if (l != ingress) _sendOnLink(l, out, enc);
        }
      }
      // Carry it over Nearby too, unless it just came from there. Fragments
      // are bridged as the reassembled packet instead (one bigger packet,
      // fewer Nearby messages); request-sync is link-local.
      if (ingress != bridgeLink && p.type != BcType.fragment) {
        onBridgeOut?.call(enc, key);
      }
    });
  }

  // ── housekeeping ──────────────────────────────────────────────────────

  bool _isSeen(String key) {
    final exp = _seen[key];
    return exp != null && exp > _now();
  }

  void _markSeen(String key) {
    _seen.remove(key);
    _seen[key] = _now() + seenTtlMs;
    while (_seen.length > seenCapacity) {
      _seen.remove(_seen.keys.first);
    }
  }

  void sweep() {
    final now = _now();
    final before = peers.length;
    peers.removeWhere((_, p) => now - p.lastSeen > peerTtlMs);
    _seen.removeWhere((_, exp) => exp <= now);
    _pendingUnverified.removeWhere((_, list) {
      list.removeWhere((m) => now - m.timestamp > pendingTtlMs);
      return list.isEmpty;
    });
    if (peers.length != before) onPeersChanged?.call();
  }

  static Uint8List _sha256(List<int> d) =>
      Uint8List.fromList(const DartSha256().hashSync(d).bytes);

  static String _digest(List<int> payload) => bcHex(_sha256(payload).sublist(0, 4));
}
