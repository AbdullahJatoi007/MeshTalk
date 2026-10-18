import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// Packet types carried over the mesh.
class PacketType {
  /// Periodic "I'm here" broadcast: name + public key. Builds the peer list.
  static const ann = 'ann';

  /// Public group chat message.
  static const chat = 'chat';

  /// Emergency broadcast, forwarded before everything else.
  static const sos = 'sos';

  /// End-to-end encrypted private message (only `dst` can read it).
  static const dm = 'dm';

  /// Delivery receipt for a dm (or for a private photo / voice message).
  static const ack = 'ack';

  /// One chunk of a photo or voice message (public, or encrypted when `dst`
  /// is set). Big media is split into many of these and reassembled.
  static const blob = 'blob';

  /// Call signalling (offer / accept / decline / busy / end). Sent with
  /// ttl 1: calls are only between phones in direct range.
  static const call = 'call';

  /// A bitchat packet (base64 in `p`) carried across the Nearby mesh, so
  /// MeshTalk phones far from any bitchat user still bridge both networks.
  static const bc = 'bc';

  /// Live location update for an SOS: `sid` (the SOS message id), `lat`,
  /// `lon`, `acc` (metres).
  static const loc = 'loc';

  static const all = {ann, chat, sos, dm, ack, blob, call, bc, loc};
}

/// Largest encoded packet we accept or relay. Keeps the flood cheap.
/// (Nearby's own limit for a bytes payload is 32 KB.)
const int kMaxPacketBytes = 16 * 1024;

/// First byte of a binary call-audio frame. JSON packets start with '{'
/// (0x7B), so the two can never be confused. Audio frames go to one
/// direct neighbour only: never relayed, deduplicated or stored.
const int kRawFrameMarker = 0x01;

/// One mesh packet. Encoded as compact JSON (utf8) on the wire.
///
/// `ttl` = hops still allowed. `hops` = hops already travelled.
/// The originator sends hops=0, ttl=maxTtl. Every relay sends ttl-1, hops+1.
class Packet {
  final String id;
  final String type;
  final String src;
  final String srcName;
  final String? dst;
  final int ttl;
  final int hops;
  final int ts;
  final Map<String, dynamic> body;

  const Packet({
    required this.id,
    required this.type,
    required this.src,
    required this.srcName,
    this.dst,
    required this.ttl,
    this.hops = 0,
    required this.ts,
    this.body = const {},
  });

  static final _rand = Random.secure();

  /// 64-bit random id as 16 hex chars.
  static String newId() {
    final b = List<int>.generate(8, (_) => _rand.nextInt(256));
    return b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Lower number = sent first.
  int get priority {
    switch (type) {
      case PacketType.sos:
        return 0;
      case PacketType.dm:
      case PacketType.ack:
      case PacketType.call:
      case PacketType.loc:
        return 1;
      case PacketType.chat:
      case PacketType.bc:
        return 2;
      case PacketType.ann:
        return 3;
      default:
        // blob: big and least urgent, never delays text or SOS; an SOS voice
        // message is marked urgent (`u`: 1) and goes right after SOS text.
        return body['u'] == 1 ? 1 : 4;
    }
  }

  /// The copy a relay sends on: one hop further, one hop less to live.
  Packet forwarded() => Packet(
        id: id,
        type: type,
        src: src,
        srcName: srcName,
        dst: dst,
        ttl: ttl - 1,
        hops: hops + 1,
        ts: ts,
        body: body,
      );

  Map<String, dynamic> toJson() => {
        'v': 1,
        'id': id,
        't': type,
        's': src,
        'n': srcName,
        if (dst != null) 'd': dst,
        'ttl': ttl,
        'h': hops,
        'ts': ts,
        'b': body,
      };

  Uint8List encode() => Uint8List.fromList(utf8.encode(jsonEncode(toJson())));

  static final _hex16 = RegExp(r'^[0-9a-f]{16}$');

  static bool isNodeId(String? s) => s != null && _hex16.hasMatch(s);

  /// Returns null for anything malformed, oversized or of unknown type,
  /// so a broken or hostile peer can't crash the relay.
  static Packet? decode(Uint8List bytes) {
    if (bytes.length > kMaxPacketBytes) return null;
    try {
      final j = jsonDecode(utf8.decode(bytes));
      if (j is! Map<String, dynamic>) return null;
      final id = j['id'], t = j['t'], s = j['s'], n = j['n'];
      final ttl = j['ttl'], h = j['h'], ts = j['ts'], b = j['b'];
      final d = j['d'];
      if (id is! String || !_hex16.hasMatch(id)) return null;
      if (t is! String || !PacketType.all.contains(t)) return null;
      if (s is! String || !_hex16.hasMatch(s)) return null;
      if (d != null && (d is! String || !_hex16.hasMatch(d))) return null;
      if (n is! String || ttl is! int || h is! int || ts is! int) return null;
      if (ttl < 0 || ttl > 16 || h < 0 || h > 16) return null;
      if (b is! Map<String, dynamic>) return null;
      return Packet(
        id: id,
        type: t,
        src: s,
        srcName: n.length > 24 ? n.substring(0, 24) : n,
        dst: d as String?,
        ttl: ttl,
        hops: h,
        ts: ts,
        body: b,
      );
    } catch (_) {
      return null;
    }
  }
}
