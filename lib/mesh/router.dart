import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'packet.dart';
import 'transport.dart';

/// What we know about another phone in the mesh (learned from `ann` packets).
class PeerInfo {
  final String nodeId;
  String name;
  String pubKey; // base64 X25519 public key
  int hops; // 1 = direct neighbour
  int lastSeen; // ms since epoch

  PeerInfo({
    required this.nodeId,
    required this.name,
    required this.pubKey,
    required this.hops,
    required this.lastSeen,
  });
}

/// The relay layer: flooding with TTL + dedup, store-and-forward,
/// priority send queues and the peer table.
///
/// Rules (same as bitchat / Bluetooth Mesh / Meshtastic):
///  * every packet has a unique id; ids already seen are dropped
///    (stops loops and the exponential echo of a flood);
///  * a relay forwards to every link except the one it came in on,
///    with ttl-1 / hops+1, and stops when ttl would hit 0;
///  * a dm addressed to us is delivered and not forwarded further;
///  * recent packets are kept and replayed to every new neighbour, so a
///    phone that walks into range later still gets them (store-and-forward).
class MeshRouter {
  MeshRouter({
    required this.selfId,
    required this.transport,
    this.maxTtl = 7,
    int Function()? clock,
  }) : _now = clock ?? (() => DateTime.now().millisecondsSinceEpoch) {
    transport.onData = _onData;
    transport.onLinkUp = _onLinkUp;
    transport.onLinkDown = _onLinkDown;
  }

  final String selfId;
  final MeshTransport transport;
  final int maxTtl;
  final int Function() _now;

  // ── tuning ────────────────────────────────────────────────────────────
  static const seenCapacity = 5000;
  static const seenTtlMs = 60 * 60 * 1000; // remember ids for 1 h
  static const bufferCapacity = 200;
  static const bufferTtlMs = 30 * 60 * 1000; // replay last 30 min
  static const peerExpiryMs = 100 * 1000; // ann every 30 s → 3 missed = gone
  static const maxClockSkewMs = 24 * 60 * 60 * 1000;

  final LinkedHashMap<String, int> _seen = LinkedHashMap(); // id → expiry
  final List<Packet> _buffer = []; // store-and-forward (relay-ready copies)
  final Map<String, PeerInfo> peers = {};
  final Map<String, List<_Queued>> _queues = {};
  final Set<String> _pumping = {};

  final _incoming = StreamController<Packet>.broadcast();
  final _changes = StreamController<void>.broadcast();

  /// Packets meant for this phone (broadcasts + dms to us). Includes
  /// `ann` packets so the UI can refresh the peer list.
  Stream<Packet> get incoming => _incoming.stream;

  /// Fires when links or the peer table change.
  Stream<void> get changes => _changes.stream;

  /// Called when a new neighbour appears, so the owner can announce.
  void Function()? onNeighbour;

  /// Binary call-audio frames from a direct neighbour (not relayed).
  void Function(String linkId, Uint8List data)? onRawFrame;

  /// The direct link to [nodeId], if it is a neighbour right now.
  String? linkFor(String nodeId) {
    for (final l in transport.links) {
      if (transport.nodeOf(l) == nodeId) return l;
    }
    return null;
  }

  /// Sends bytes straight to one link, skipping queues and relaying.
  /// Used for call audio, where a late frame is worse than a lost one.
  Future<bool> sendRaw(String linkId, Uint8List data) =>
      transport.send(linkId, data);

  /// Packet types replayed to new neighbours (store-and-forward).
  /// Announcements go stale, media chunks are too heavy to replay,
  /// call signalling is only meaningful live.
  static bool _replayable(String type) =>
      type != PacketType.ann && type != PacketType.blob && type != PacketType.call;

  Timer? _sweeper;

  void start() {
    _sweeper ??= Timer.periodic(const Duration(seconds: 15), (_) => sweep());
  }

  void dispose() {
    _sweeper?.cancel();
    _incoming.close();
    _changes.close();
  }

  int get linkCount => transport.links.length;

  /// Originate a packet from this phone.
  void send(Packet p) {
    _markSeen(p.id);
    if (_replayable(p.type)) _remember(p);
    for (final link in transport.links) {
      _enqueue(link, p);
    }
  }

  // ── inbound ───────────────────────────────────────────────────────────

  void _onData(String link, Uint8List data) {
    if (data.isNotEmpty && data[0] == kRawFrameMarker) {
      onRawFrame?.call(link, data);
      return;
    }
    final p = Packet.decode(data);
    if (p == null) return;
    if (p.src == selfId) return; // our own packet echoed back
    if (_isSeen(p.id)) return;
    _markSeen(p.id);

    // Ignore packets with wildly wrong timestamps (replays of ancient traffic).
    if ((p.ts - _now()).abs() > maxClockSkewMs) return;

    if (p.type == PacketType.ann) _learnPeer(p);

    final forMe = p.dst == null || p.dst == selfId;
    if (forMe) _incoming.add(p);

    // A dm/ack that reached its destination stops here.
    if (p.dst == selfId) return;

    if (p.ttl > 1) {
      final fwd = p.forwarded();
      if (_replayable(fwd.type)) _remember(fwd);
      for (final other in transport.links) {
        if (other != link) _enqueue(other, fwd);
      }
    }
  }

  void _learnPeer(Packet p) {
    final name = p.srcName;
    final pk = p.body['pk'];
    if (pk is! String) return;
    final dist = p.hops + 1;
    final existing = peers[p.src];
    if (existing == null) {
      peers[p.src] = PeerInfo(
          nodeId: p.src, name: name, pubKey: pk, hops: dist, lastSeen: _now());
    } else {
      existing
        ..name = name
        ..pubKey = pk
        ..hops = dist
        ..lastSeen = _now();
    }
    _changes.add(null);
  }

  void _onLinkUp(String link, String nodeId) {
    // Store-and-forward: replay recent traffic to the new neighbour.
    _pruneBuffer();
    for (final p in _buffer) {
      if (p.src != nodeId) _enqueue(link, p);
    }
    _changes.add(null);
    onNeighbour?.call();
  }

  void _onLinkDown(String link) {
    _queues.remove(link);
    _changes.add(null);
  }

  // ── send queues (priority: sos > dm/ack > chat > ann) ─────────────────

  int _seq = 0;

  void _enqueue(String link, Packet p) {
    final q = _queues.putIfAbsent(link, () => []);
    q.add(_Queued(p.priority, _seq++, p.encode()));
    q.sort((a, b) => a.priority != b.priority
        ? a.priority - b.priority
        : a.seq - b.seq);
    if (q.length > 500) q.removeLast(); // never let a dead link eat memory
    // Start the pump on the next microtask, so a burst of enqueues (e.g. the
    // store-and-forward replay) is fully sorted before the first send.
    scheduleMicrotask(() => _pump(link));
  }

  Future<void> _pump(String link) async {
    if (_pumping.contains(link)) return;
    _pumping.add(link);
    try {
      while (true) {
        final q = _queues[link];
        if (q == null || q.isEmpty) break;
        final item = q.removeAt(0);
        final ok = await transport.send(link, item.bytes);
        if (!ok && !transport.links.contains(link)) break;
      }
    } finally {
      _pumping.remove(link);
    }
  }

  // ── dedup + buffer + expiry ───────────────────────────────────────────

  bool _isSeen(String id) {
    final exp = _seen[id];
    return exp != null && exp > _now();
  }

  void _markSeen(String id) {
    _seen.remove(id);
    _seen[id] = _now() + seenTtlMs;
    while (_seen.length > seenCapacity) {
      _seen.remove(_seen.keys.first);
    }
  }

  void _remember(Packet p) {
    if (p.ttl < 1) return;
    _buffer.add(p);
    if (_buffer.length > bufferCapacity) _buffer.removeAt(0);
  }

  void _pruneBuffer() {
    final cutoff = _now() - bufferTtlMs;
    _buffer.removeWhere((p) => p.ts < cutoff);
  }

  /// Drops stale peers, buffered packets and seen-ids. Runs every 15 s.
  void sweep() {
    final now = _now();
    final before = peers.length;
    peers.removeWhere((_, p) => now - p.lastSeen > peerExpiryMs);
    _pruneBuffer();
    _seen.removeWhere((_, exp) => exp <= now);
    if (peers.length != before) _changes.add(null);
  }
}

class _Queued {
  final int priority;
  final int seq;
  final Uint8List bytes;
  _Queued(this.priority, this.seq, this.bytes);
}