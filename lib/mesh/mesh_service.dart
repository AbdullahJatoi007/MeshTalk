import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cryptography/dart.dart';

import '../bitchat/bc_mesh.dart';
import '../platform/ble_bridge.dart';
import '../platform/native_bridge.dart';
import 'identity.dart';
import 'media.dart';
import 'nearby_transport.dart';
import 'packet.dart';
import 'router.dart';

enum MessageKind { public, sos, dm }

class ChatMessage {
  final String id;
  final MessageKind kind;
  final String? peerId; // dm: the other person in the conversation
  final String fromId;
  final String fromName;
  final String text;
  final int ts;
  final bool mine;
  final int hops; // how far it travelled to reach us (0 for our own)
  bool delivered;

  /// Photo or voice message: MediaKind.image / MediaKind.voice, else null.
  final String? media;

  /// Local file once fully received (or sent).
  String? path;

  /// 0..1 while chunks are arriving.
  double progress;

  /// Voice message length.
  final int durMs;

  /// 'bitchat' when the message came over the bitchat Bluetooth network.
  final String? via;

  ChatMessage({
    required this.id,
    required this.kind,
    this.peerId,
    required this.fromId,
    required this.fromName,
    required this.text,
    required this.ts,
    required this.mine,
    this.hops = 0,
    this.delivered = false,
    this.media,
    this.path,
    this.progress = 1,
    this.durMs = 0,
    this.via,
  });

  bool get isMedia => media != null;
  bool get viaBitchat => via == 'bitchat';

  /// Short text for notifications and conversation lists.
  String get preview => media == MediaKind.image
      ? '📷 Photo'
      : media == MediaKind.voice
          ? '🎤 Voice message'
          : text;

  Map<String, dynamic> toJson() => {
        'id': id,
        'k': kind.name,
        if (peerId != null) 'p': peerId,
        'f': fromId,
        'fn': fromName,
        'x': text,
        'ts': ts,
        'm': mine,
        'h': hops,
        'd': delivered,
        if (media != null) 'md': media,
        if (path != null) 'pa': path,
        if (media != null) 'pr': progress,
        if (durMs > 0) 'du': durMs,
        if (via != null) 'v': via,
      };

  static ChatMessage? fromJson(Map<String, dynamic> j) {
    try {
      return ChatMessage(
        id: j['id'] as String,
        kind: MessageKind.values.byName(j['k'] as String),
        peerId: j['p'] as String?,
        fromId: j['f'] as String,
        fromName: j['fn'] as String,
        text: j['x'] as String,
        ts: j['ts'] as int,
        mine: j['m'] as bool,
        hops: (j['h'] as int?) ?? 0,
        delivered: (j['d'] as bool?) ?? false,
        media: j['md'] as String?,
        path: j['pa'] as String?,
        progress: ((j['pr'] as num?) ?? 1).toDouble(),
        durMs: (j['du'] as int?) ?? 0,
        via: j['v'] as String?,
      );
    } catch (_) {
      return null;
    }
  }
}

// ── calls ───────────────────────────────────────────────────────────────

enum CallPhase { outgoing, incoming, active }

class CallSession {
  CallSession({
    required this.id,
    required this.peerId,
    required this.peerName,
    required this.phase,
  });

  final String id; // 16 hex chars
  final String peerId;
  final String peerName;
  CallPhase phase;
  int? startedAt; // when audio started
  bool muted = false;
  bool speaker = false;
  int lastFrameAt = 0;
  int _seq = 0;
}

/// App-level glue: identity, transport, router, messages, media, calls,
/// notifications.
class MeshService extends ChangeNotifier with WidgetsBindingObserver {
  MeshService._(this.identity, this._prefs, this.nick);

  static const maxTextLength = 1000;
  static const _nickKey = 'nick_v1';
  static const _msgsKey = 'messages_v1';
  static const _maxStored = 500;
  static const _ringTimeoutMs = 30000;
  static const _callSilenceMs = 8000;
  static const _bitchatKey = 'bitchat_enabled_v1';

  /// Largest bitchat packet we carry across Nearby (text-sized traffic).
  static const _maxBridgeBytes = 8000;

  final Identity identity;
  final SharedPreferences _prefs;
  String? nick;

  NearbyTransport? _transport;
  MeshRouter? _router;
  StreamSubscription? _inSub, _chSub;
  Timer? _announceTimer, _saveTimer, _pruneTimer;

  bool running = false;
  String? lastError;
  bool _foreground = true;

  final List<ChatMessage> _messages = [];
  final Map<String, ChatMessage> _byId = {};
  final Map<String, int> unreadDm = {};
  String? openThread; // peer id of the dm screen currently open
  ChatMessage? sosAlert;

  final MediaAssembler _assembler = MediaAssembler();

  // ── bitchat compatibility (Bluetooth LE, public chat) ──
  BitchatMesh? _bitchat;
  bool bitchatEnabled = true;

  /// Why bitchat can't run right now (Bluetooth off, permission…), or null.
  String? bitchatProblem;

  CallSession? call;
  String? _callEndedReason;
  StreamSubscription<Uint8List>? _frameSub;
  Timer? _ringTimer, _callWatchdog;

  String get selfId => identity.nodeId;

  static Future<MeshService> create() async {
    final prefs = await SharedPreferences.getInstance();
    final id = await Identity.loadOrCreate();
    final dir = await NativeBridge.filesDir() ?? Directory.systemTemp.path;
    await MediaStore.init(dir);
    final s = MeshService._(id, prefs, prefs.getString(_nickKey));
    s.bitchatEnabled = prefs.getBool(_bitchatKey) ?? true;
    s._loadMessages();
    WidgetsBinding.instance.addObserver(s);
    return s;
  }

  // ── lifecycle ─────────────────────────────────────────────────────────

  Future<void> setNick(String value) async {
    final v = value.trim();
    nick = v.length > 20 ? v.substring(0, 20) : v;
    await _prefs.setString(_nickKey, nick!);
    _bitchat?.sendAnnounce();
    notifyListeners();
  }

  Future<void> start() async {
    if (running || nick == null) return;
    lastError = null;
    final t = NearbyTransport(selfId: selfId, nick: nick!);
    final r = MeshRouter(selfId: selfId, transport: t);
    t.onError = (m) {
      lastError = m;
      notifyListeners();
    };
    r.onNeighbour = _announce;
    r.onRawFrame = _onRawFrame;
    _inSub = r.incoming.listen(_onPacket);
    _chSub = r.changes.listen((_) {
      _updateServiceText();
      notifyListeners();
    });
    _transport = t;
    _router = r;
    r.start();
    await t.start();
    running = true;
    _announceTimer =
        Timer.periodic(const Duration(seconds: 30), (_) => _announce());
    _pruneTimer = Timer.periodic(const Duration(minutes: 1),
        (_) => _assembler.prune(DateTime.now().millisecondsSinceEpoch));
    _announce();
    await NativeBridge.startService();
    if (bitchatEnabled) await _startBitchat();
    notifyListeners();
  }

  Future<void> stop() async {
    if (!running) return;
    if (call != null) endCall('Mesh turned off');
    running = false;
    await _stopBitchat();
    _announceTimer?.cancel();
    _pruneTimer?.cancel();
    await _inSub?.cancel();
    await _chSub?.cancel();
    await _transport?.stop();
    _router?.dispose();
    _transport = null;
    _router = null;
    await NativeBridge.stopService();
    notifyListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _saveTimer?.cancel();
    _announceTimer?.cancel();
    _pruneTimer?.cancel();
    _ringTimer?.cancel();
    _callWatchdog?.cancel();
    _transport?.stop();
    super.dispose();
  }

  // ── state for the UI ──────────────────────────────────────────────────

  int get linkCount => _router?.linkCount ?? 0;

  List<PeerInfo> get peers {
    final list = _router?.peers.values.toList() ?? <PeerInfo>[];
    list.sort((a, b) =>
        a.hops != b.hops ? a.hops - b.hops : a.name.compareTo(b.name));
    return list;
  }

  PeerInfo? peer(String id) => _router?.peers[id];

  /// Public chat + SOS, oldest first.
  List<ChatMessage> get publicFeed =>
      _messages.where((m) => m.kind != MessageKind.dm).toList();

  List<ChatMessage> thread(String peerId) => _messages
      .where((m) => m.kind == MessageKind.dm && m.peerId == peerId)
      .toList();

  /// People we have a dm history with but who aren't in the mesh right now.
  List<ChatMessage> get offlineConversations {
    final online = _router?.peers.keys.toSet() ?? <String>{};
    final last = <String, ChatMessage>{};
    for (final m in _messages) {
      if (m.kind == MessageKind.dm && m.peerId != null) last[m.peerId!] = m;
    }
    return last.values.where((m) => !online.contains(m.peerId)).toList()
      ..sort((a, b) => b.ts - a.ts);
  }

  String nameFor(String peerId) {
    final p = _router?.peers[peerId];
    if (p != null) return p.name;
    for (final m in _messages.reversed) {
      if (m.peerId == peerId && !m.mine) return m.fromName;
    }
    return 'Unknown';
  }

  int get totalUnread => unreadDm.values.fold(0, (a, b) => a + b);

  void markRead(String peerId) {
    if (unreadDm.remove(peerId) != null) notifyListeners();
  }

  void dismissSos() {
    sosAlert = null;
    notifyListeners();
  }

  // ── sending: text ─────────────────────────────────────────────────────

  Packet _packet(String type,
          {String? id,
          String? dst,
          int? ttl,
          Map<String, dynamic> body = const {}}) =>
      Packet(
        id: id ?? Packet.newId(),
        type: type,
        src: selfId,
        srcName: nick ?? '?',
        dst: dst,
        ttl: ttl ?? _router?.maxTtl ?? 7,
        ts: DateTime.now().millisecondsSinceEpoch,
        body: body,
      );

  void _announce() {
    _router?.send(_packet(PacketType.ann, body: {'pk': identity.publicKeyB64}));
  }

  String _clip(String s) {
    final t = s.trim();
    return t.length > maxTextLength ? t.substring(0, maxTextLength) : t;
  }

  void sendPublic(String text) {
    _sendBroadcast(PacketType.chat, text);
    _bitchat?.sendPublic(_clip(text)); // also reaches bitchat users
  }

  void sendSos(String text) {
    _sendBroadcast(PacketType.sos, text);
    // bitchat has no SOS type: it arrives there as a public message.
    final t = _clip(text);
    if (t.isNotEmpty) _bitchat?.sendPublic('🆘 SOS: $t');
  }

  void _sendBroadcast(String type, String text) {
    final t = _clip(text);
    if (t.isEmpty || _router == null) return;
    final p = _packet(type, body: {'x': t});
    _router!.send(p);
    _add(ChatMessage(
      id: p.id,
      kind: type == PacketType.sos ? MessageKind.sos : MessageKind.public,
      fromId: selfId,
      fromName: nick ?? '?',
      text: t,
      ts: p.ts,
      mine: true,
    ));
  }

  PeerInfo _reachable(String peerId) {
    final peer = _router?.peers[peerId];
    if (_router == null || peer == null) {
      throw StateError('Not reachable right now');
    }
    return peer;
  }

  /// Throws [StateError] if the peer isn't currently in the mesh.
  Future<void> sendDm(String peerId, String text) async {
    final t = _clip(text);
    if (t.isEmpty) return;
    final peer = _reachable(peerId);
    final id = Packet.newId();
    final body =
        await identity.encrypt(t, peer.pubKey, _aad(selfId, peerId, id));
    final p = _packet(PacketType.dm, id: id, dst: peerId, body: body);
    _router!.send(p);
    _add(ChatMessage(
      id: id,
      kind: MessageKind.dm,
      peerId: peerId,
      fromId: selfId,
      fromName: nick ?? '?',
      text: t,
      ts: p.ts,
      mine: true,
    ));
  }

  static String _aad(String src, String dst, String id) => '$src>$dst#$id';

  // ── sending: photos and voice messages ────────────────────────────────

  /// [jpeg] is already compressed by the picker. [toPeer] = private.
  Future<void> sendImage(Uint8List jpeg, {String? toPeer}) async {
    if (jpeg.length > kMaxMediaBytes) {
      throw StateError('Photo is too large to send over the mesh');
    }
    final id = Packet.newId();
    final path = await MediaStore.write(id, MediaKind.image, jpeg);
    await _sendMedia(id, MediaKind.image, jpeg, path, toPeer: toPeer);
  }

  /// [recordingPath] is the file the recorder just wrote.
  Future<void> sendVoice(String recordingPath, int durMs,
      {String? toPeer}) async {
    final bytes = await File(recordingPath).readAsBytes();
    if (bytes.length > kMaxMediaBytes) {
      throw StateError('Voice message is too large');
    }
    final id = Packet.newId();
    // Keep it under its message id, like received media.
    final path = MediaStore.pathFor(id, MediaKind.voice);
    await File(recordingPath).rename(path);
    await _sendMedia(id, MediaKind.voice, bytes, path,
        toPeer: toPeer, durMs: durMs.clamp(0, kMaxVoiceMs).toInt());
  }

  Future<void> _sendMedia(
      String mediaId, String kind, Uint8List data, String path,
      {String? toPeer, int durMs = 0}) async {
    final r = _router;
    if (r == null) throw StateError('Mesh is off');
    final peer = toPeer == null ? null : _reachable(toPeer);
    final chunks = splitChunks(data);

    _add(ChatMessage(
      id: mediaId,
      kind: toPeer == null ? MessageKind.public : MessageKind.dm,
      peerId: toPeer,
      fromId: selfId,
      fromName: nick ?? '?',
      text: '',
      ts: DateTime.now().millisecondsSinceEpoch,
      mine: true,
      media: kind,
      path: path,
      durMs: durMs,
    ));

    for (var i = 0; i < chunks.length; i++) {
      final pid = Packet.newId();
      final body = <String, dynamic>{
        'mid': mediaId,
        'k': kind,
        'i': i,
        'cnt': chunks.length,
        if (durMs > 0) 'dur': durMs,
      };
      if (peer != null) {
        body['e'] = await identity.encryptBytes(
            chunks[i], peer.pubKey, _aad(selfId, toPeer!, pid));
      } else {
        body['d'] = base64Encode(chunks[i]);
      }
      r.send(_packet(PacketType.blob, id: pid, dst: toPeer, body: body));
    }
  }

  // ── receiving ─────────────────────────────────────────────────────────

  String? _text(Packet p) {
    final x = p.body['x'];
    if (x is! String) return null;
    final t = x.trim();
    if (t.isEmpty) return null;
    return t.length > maxTextLength ? t.substring(0, maxTextLength) : t;
  }

  Future<void> _onPacket(Packet p) async {
    switch (p.type) {
      case PacketType.chat:
        final t = _text(p);
        if (t == null) return;
        _dropBitchatCopies(p.src, t);
        _add(ChatMessage(
          id: p.id,
          kind: MessageKind.public,
          fromId: p.src,
          fromName: p.srcName,
          text: t,
          ts: p.ts,
          mine: false,
          hops: p.hops + 1,
        ));
        break;

      case PacketType.sos:
        final t = _text(p);
        if (t == null || _byId.containsKey(p.id)) return;
        final m = ChatMessage(
          id: p.id,
          kind: MessageKind.sos,
          fromId: p.src,
          fromName: p.srcName,
          text: t,
          ts: p.ts,
          mine: false,
          hops: p.hops + 1,
        );
        _add(m);
        sosAlert = m;
        HapticFeedback.heavyImpact();
        NativeBridge.notify('🆘 SOS from ${p.srcName}',
            '$t\n(${p.hops + 1} hop${p.hops == 0 ? '' : 's'} away)',
            urgent: true);
        notifyListeners();
        break;

      case PacketType.dm:
        if (p.dst != selfId) return;
        if (!_byId.containsKey(p.id)) {
          final t =
              await identity.decrypt(p.body, p.src, _aad(p.src, selfId, p.id));
          if (t == null) return; // forged or tampered
          _add(ChatMessage(
            id: p.id,
            kind: MessageKind.dm,
            peerId: p.src,
            fromId: p.src,
            fromName: p.srcName,
            text: t,
            ts: p.ts,
            mine: false,
            hops: p.hops + 1,
          ));
          _onNewPrivate(p.src, p.srcName, t);
        }
        // Receipt (sent again for duplicates, in case the first one was lost).
        _sendAck(p.src, p.id);
        break;

      case PacketType.ack:
        if (p.dst != selfId) return;
        final m = _byId[p.body['r']];
        if (m != null && m.mine && m.peerId == p.src && !m.delivered) {
          m.delivered = true;
          _scheduleSave();
          notifyListeners();
        }
        break;

      case PacketType.blob:
        await _onBlob(p);
        break;

      case PacketType.call:
        _onCallSignal(p);
        break;

      case PacketType.bc:
        final raw = p.body['p'];
        if (raw is! String || _bitchat == null) return;
        try {
          _bitchat!.injectFromBridge(base64Decode(raw));
        } catch (_) {}
        break;
    }
  }

  void _sendAck(String to, String ref) =>
      _router?.send(_packet(PacketType.ack, dst: to, body: {'r': ref}));

  void _onNewPrivate(String from, String fromName, String preview) {
    if (openThread != from || !_foreground) {
      unreadDm[from] = (unreadDm[from] ?? 0) + 1;
    }
    if (!_foreground) NativeBridge.notify(fromName, preview);
    notifyListeners();
  }

  Future<void> _onBlob(Packet p) async {
    final b = p.body;
    final mid = b['mid'], kind = b['k'], i = b['i'], cnt = b['cnt'];
    if (mid is! String || !Packet.isNodeId(mid)) return;
    if (kind is! String || !MediaKind.all.contains(kind)) return;
    if (i is! int || cnt is! int) return;
    if (p.dst != null && p.dst != selfId) return;
    final isPrivate = p.dst == selfId;

    // Already have the whole thing (a late duplicate chunk).
    final existing = _byId[mid];
    if (existing != null && existing.path != null) {
      if (isPrivate && i == cnt - 1) _sendAck(p.src, mid);
      return;
    }

    Uint8List? bytes;
    if (isPrivate) {
      final e = b['e'];
      if (e is! Map<String, dynamic>) return;
      bytes =
          await identity.decryptBytes(e, p.src, _aad(p.src, selfId, p.id));
    } else {
      final d = b['d'];
      if (d is! String) return;
      try {
        bytes = base64Decode(d);
      } catch (_) {
        return;
      }
    }
    if (bytes == null) return;

    final im = _assembler.add(
      mediaId: mid,
      kind: kind,
      index: i,
      total: cnt,
      bytes: bytes,
      src: p.src,
      now: DateTime.now().millisecondsSinceEpoch,
    );
    if (im == null) return;

    var m = _byId[mid];
    if (m != null && m.path != null) return; // completed while we decrypted
    if (m == null) {
      final dur = b['dur'];
      m = ChatMessage(
        id: mid,
        kind: isPrivate ? MessageKind.dm : MessageKind.public,
        peerId: isPrivate ? p.src : null,
        fromId: p.src,
        fromName: p.srcName,
        text: '',
        ts: p.ts,
        mine: false,
        hops: p.hops + 1,
        media: kind,
        progress: im.progress,
        durMs: dur is int ? dur.clamp(0, kMaxVoiceMs).toInt() : 0,
      );
      _add(m);
    } else {
      m.progress = im.progress;
    }

    if (im.complete) {
      _assembler.remove(mid);
      m.path = await MediaStore.write(mid, kind, im.assemble());
      m.progress = 1;
      _scheduleSave();
      if (isPrivate) {
        _sendAck(p.src, mid);
        _onNewPrivate(p.src, p.srcName, m.preview);
      }
    }
    notifyListeners();
  }

  // ── calls (direct neighbours only) ────────────────────────────────────

  /// Calls need a direct link: audio is never relayed through other phones.
  bool canCall(String peerId) =>
      running &&
      call == null &&
      _router?.peers[peerId]?.hops == 1 &&
      _router?.linkFor(peerId) != null;

  /// Why the last call ended (shown once by the UI, then cleared).
  String? takeCallEndedReason() {
    final r = _callEndedReason;
    _callEndedReason = null;
    return r;
  }

  Future<void> startCall(String peerId) async {
    if (call != null) throw StateError('Already in a call');
    if (!canCall(peerId)) {
      throw StateError('Calls work only with phones in direct range');
    }
    call = CallSession(
      id: Packet.newId(),
      peerId: peerId,
      peerName: nameFor(peerId),
      phase: CallPhase.outgoing,
    );
    _sendCall(peerId, 'offer', call!.id);
    _startRingTimer('No answer');
    notifyListeners();
  }

  Future<void> acceptCall() async {
    final c = call;
    if (c == null || c.phase != CallPhase.incoming) return;
    if (_router?.linkFor(c.peerId) == null) {
      _clearCall('Connection lost');
      return;
    }
    _sendCall(c.peerId, 'accept', c.id);
    await _beginAudio();
  }

  void declineCall() {
    final c = call;
    if (c == null) return;
    _sendCall(c.peerId, 'decline', c.id);
    _clearCall('Call declined');
  }

  void endCall([String reason = 'Call ended']) {
    final c = call;
    if (c == null) return;
    _sendCall(c.peerId, 'end', c.id);
    _clearCall(reason);
  }

  void setMuted(bool on) {
    final c = call;
    if (c == null) return;
    c.muted = on;
    NativeBridge.callMute(on);
    notifyListeners();
  }

  void setSpeaker(bool on) {
    final c = call;
    if (c == null) return;
    c.speaker = on;
    NativeBridge.callSpeaker(on);
    notifyListeners();
  }

  void _sendCall(String peerId, String action, String callId) {
    _router?.send(_packet(PacketType.call,
        dst: peerId, ttl: 1, body: {'a': action, 'c': callId}));
  }

  void _startRingTimer(String reason) {
    _ringTimer?.cancel();
    _ringTimer = Timer(const Duration(milliseconds: _ringTimeoutMs), () {
      final c = call;
      if (c != null && c.phase != CallPhase.active) {
        if (c.phase == CallPhase.outgoing) _sendCall(c.peerId, 'end', c.id);
        _clearCall(reason);
      }
    });
  }

  void _onCallSignal(Packet p) {
    if (p.dst != selfId) return;
    final action = p.body['a'], cid = p.body['c'];
    if (action is! String || cid is! String || !Packet.isNodeId(cid)) return;
    final c = call;

    switch (action) {
      case 'offer':
        if (p.hops != 0) return; // not a direct neighbour
        if (c != null) {
          if (c.id != cid) _sendCall(p.src, 'busy', cid);
          return;
        }
        call = CallSession(
          id: cid,
          peerId: p.src,
          peerName: p.srcName,
          phase: CallPhase.incoming,
        );
        _startRingTimer('Missed call from ${p.srcName}');
        HapticFeedback.heavyImpact();
        if (!_foreground) {
          NativeBridge.notify('📞 Incoming call', '${p.srcName} is calling you');
        }
        notifyListeners();
        break;
      case 'accept':
        if (c != null && c.id == cid && c.phase == CallPhase.outgoing) {
          _beginAudio();
        }
        break;
      case 'decline':
        if (c != null && c.id == cid) _clearCall('${c.peerName} declined');
        break;
      case 'busy':
        if (c != null && c.id == cid) _clearCall('${c.peerName} is busy');
        break;
      case 'end':
        if (c != null && c.id == cid) {
          _clearCall(c.phase == CallPhase.incoming
              ? 'Missed call from ${c.peerName}'
              : 'Call ended');
        }
        break;
    }
  }

  Future<void> _beginAudio() async {
    final c = call;
    if (c == null) return;
    _ringTimer?.cancel();
    c.phase = CallPhase.active;
    c.startedAt = DateTime.now().millisecondsSinceEpoch;
    c.lastFrameAt = c.startedAt!;
    notifyListeners();

    _frameSub = NativeBridge.callFrames.listen(_onMicFrame);
    final ok = await NativeBridge.callStart(speaker: c.speaker);
    if (!ok) {
      endCall('Microphone unavailable');
      return;
    }
    NativeBridge.serviceMic(true);
    _callWatchdog = Timer.periodic(const Duration(seconds: 2), (_) {
      final cc = call;
      if (cc == null) return;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (_router?.linkFor(cc.peerId) == null ||
          now - cc.lastFrameAt > _callSilenceMs) {
        endCall('Connection lost');
      }
    });
  }

  /// Our microphone → the peer, straight over the direct link.
  /// Frame: [0x01][call id, 8 bytes][seq, 2 bytes][ADPCM audio]
  void _onMicFrame(Uint8List adpcm) {
    final c = call;
    final r = _router;
    if (c == null || r == null || c.phase != CallPhase.active) return;
    final link = r.linkFor(c.peerId);
    if (link == null) return;
    final frame = Uint8List(11 + adpcm.length);
    frame[0] = kRawFrameMarker;
    frame.setRange(1, 9, _hexBytes(c.id));
    final seq = c._seq++ & 0xFFFF;
    frame[9] = seq & 0xFF;
    frame[10] = seq >> 8;
    frame.setRange(11, frame.length, adpcm);
    r.sendRaw(link, frame);
  }

  /// The peer's microphone → our speaker.
  void _onRawFrame(String link, Uint8List data) {
    final c = call;
    if (c == null || c.phase != CallPhase.active) return;
    if (data.length <= 11) return;
    if (_transport?.nodeOf(link) != c.peerId) return;
    final id = _hexBytes(c.id);
    for (var i = 0; i < 8; i++) {
      if (data[1 + i] != id[i]) return; // frame from another / old call
    }
    c.lastFrameAt = DateTime.now().millisecondsSinceEpoch;
    NativeBridge.callPlay(Uint8List.sublistView(data, 11));
  }

  static Uint8List _hexBytes(String hex16) {
    final out = Uint8List(8);
    for (var i = 0; i < 8; i++) {
      out[i] = int.parse(hex16.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  void _clearCall(String reason) {
    final c = call;
    if (c == null) return;
    _ringTimer?.cancel();
    _callWatchdog?.cancel();
    _frameSub?.cancel();
    _frameSub = null;
    if (c.phase == CallPhase.active) {
      NativeBridge.callStop();
      NativeBridge.serviceMic(false);
    }
    call = null;
    _callEndedReason = reason;
    notifyListeners();
  }

  // ── bitchat compatibility ─────────────────────────────────────────────
  // Public chat with bitchat users over Bluetooth LE. Everything else
  // (Nearby mesh, photos, voice, calls, private messages) is unchanged.

  int get bitchatLinkCount => _bitchat?.linkCount ?? 0;

  /// bitchat-network people who aren't already in the MeshTalk peer list.
  List<BcPeer> get bitchatPeers {
    final mine = _router?.peers.keys.toSet() ?? <String>{};
    final list = (_bitchat?.peers.values ?? const <BcPeer>[])
        .where((p) => p.id != selfId && !mine.contains(p.id))
        .toList()
      ..sort((a, b) => a.hops != b.hops ? a.hops - b.hops : a.nickname.compareTo(b.nickname));
    return list;
  }

  Future<void> setBitchatEnabled(bool on) async {
    bitchatEnabled = on;
    await _prefs.setBool(_bitchatKey, on);
    if (!running) {
      notifyListeners();
      return;
    }
    if (on) {
      await _startBitchat();
    } else {
      await _stopBitchat();
    }
    notifyListeners();
  }

  Future<void> _startBitchat() async {
    if (_bitchat != null) return;
    final ble = BleBitchatTransport();
    final b = BitchatMesh(
      selfId: selfId,
      noiseKey: identity.publicKey,
      signingKey: identity.signingPublicKey,
      sign: identity.sign,
      verify: Identity.verifySignature,
      transport: ble,
      nickname: () => nick ?? 'meshtalk',
    );
    ble.onState = (problem) {
      if (problem != bitchatProblem) {
        bitchatProblem = problem;
        notifyListeners();
      }
    };
    b.onPeersChanged = () {
      _updateServiceText();
      notifyListeners();
    };
    b.onPublicMessage = _onBitchatMessage;
    b.onBridgeOut = _bridgeOut;
    _bitchat = b;
    try {
      await b.start();
    } catch (e) {
      debugPrint('bitchat start failed: $e');
    }
  }

  Future<void> _stopBitchat() async {
    final b = _bitchat;
    _bitchat = null;
    for (final t in _heldBitchat.values) {
      t.cancel();
    }
    _heldBitchat.clear();
    bitchatProblem = null;
    if (b != null) await b.stop();
  }

  /// Carries a bitchat packet across the Nearby mesh. The MeshTalk packet
  /// id comes from the bitchat dedup key, so several MeshTalk phones
  /// bridging the same packet produce one Nearby flood, not several.
  void _bridgeOut(Uint8List encoded, String dedupKey) {
    final r = _router;
    if (r == null || encoded.length > _maxBridgeBytes) return;
    final id = _hex8(const DartSha256().hashSync(utf8.encode(dedupKey)).bytes);
    r.send(_packet(PacketType.bc, id: id, body: {'p': base64Encode(encoded)}));
  }

  static String _hex8(List<int> b) =>
      b.take(8).map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  /// bitchat copies of messages from MeshTalk phones, held briefly in case
  /// the same message also arrives over Nearby (then only one is shown).
  final Map<String, Timer> _heldBitchat = {};
  final Map<String, BcPublicMessage> _heldMessages = {};

  void _onBitchatMessage(BcPublicMessage m) {
    if (m.senderId == selfId) return;
    if (m.fromMeshTalk) {
      if (_hasNearbyCopy(m.senderId, m.text, m.timestamp)) return;
      if (_heldBitchat.containsKey(m.key)) return;
      _heldMessages[m.key] = m;
      _heldBitchat[m.key] = Timer(const Duration(seconds: 4), () {
        _heldBitchat.remove(m.key);
        final held = _heldMessages.remove(m.key);
        if (held != null && !_hasNearbyCopy(held.senderId, held.text, held.timestamp)) {
          _showBitchat(held);
        }
      });
      return;
    }
    _showBitchat(m);
  }

  void _showBitchat(BcPublicMessage m) {
    final id = _hex8(const DartSha256().hashSync(utf8.encode(m.key)).bytes);
    _add(ChatMessage(
      id: id,
      kind: MessageKind.public,
      fromId: m.senderId,
      fromName: m.nickname,
      text: m.text,
      ts: m.timestamp,
      mine: false,
      hops: m.hops,
      via: 'bitchat',
    ));
  }

  /// A MeshTalk sender's long message reaches bitchat as several parts, so
  /// "same message" means the Nearby text contains the bitchat text.
  bool _hasNearbyCopy(String sender, String text, int ts) => _messages.any((x) =>
      x.kind == MessageKind.public &&
      !x.viaBitchat &&
      x.fromId == sender &&
      x.text.contains(text) &&
      (x.ts - ts).abs() < 10 * 60 * 1000);

  /// A Nearby chat arrived: forget bitchat copies of it that are waiting.
  void _dropBitchatCopies(String sender, String text) {
    final drop = _heldMessages.entries
        .where((e) => e.value.senderId == sender && text.contains(e.value.text))
        .map((e) => e.key)
        .toList();
    for (final k in drop) {
      _heldMessages.remove(k);
      _heldBitchat.remove(k)?.cancel();
    }
  }

  // ── message list ──────────────────────────────────────────────────────

  void _add(ChatMessage m) {
    if (_byId.containsKey(m.id)) return; // already have it (e.g. replay)
    _byId[m.id] = m;
    _messages.add(m);
    _messages.sort((a, b) => a.ts - b.ts);
    if (_messages.length > _maxStored) {
      final removed = _messages.removeAt(0);
      _byId.remove(removed.id);
      final path = removed.path;
      if (path != null) File(path).delete().catchError((_) => File(path));
    }
    _scheduleSave();
    notifyListeners();
  }

  // ── persistence ───────────────────────────────────────────────────────

  void _loadMessages() {
    final raw = _prefs.getString(_msgsKey);
    if (raw == null) return;
    try {
      for (final j in (jsonDecode(raw) as List)) {
        final m = ChatMessage.fromJson(j as Map<String, dynamic>);
        if (m != null && !_byId.containsKey(m.id)) {
          _byId[m.id] = m;
          _messages.add(m);
        }
      }
      _messages.sort((a, b) => a.ts - b.ts);
    } catch (_) {}
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 1), () {
      _prefs.setString(
          _msgsKey, jsonEncode(_messages.map((m) => m.toJson()).toList()));
    });
  }

  Future<void> clearHistory() async {
    _messages.clear();
    _byId.clear();
    unreadDm.clear();
    await _prefs.remove(_msgsKey);
    await MediaStore.clear();
    notifyListeners();
  }

  // ── foreground-service notification text ──────────────────────────────

  String _lastServiceText = '';

  void _updateServiceText() {
    final n = _router?.peers.length ?? 0;
    final bc = bitchatPeers.length;
    final text =
        '$linkCount direct link${linkCount == 1 ? '' : 's'} · $n ${n == 1 ? 'person' : 'people'} in mesh'
        '${bc > 0 ? ' · $bc on bitchat' : ''}';
    if (text == _lastServiceText) return;
    _lastServiceText = text;
    NativeBridge.updateService(text);
  }
}
