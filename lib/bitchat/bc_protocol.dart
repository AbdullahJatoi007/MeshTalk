// bitchat wire protocol (binary packets), written from the public-domain
// bitchat iOS sources and WHITEPAPER.md (Unlicense):
// https://github.com/permissionlesstech/bitchat
//
// Packet (all multi-byte values big-endian):
//   version(1) type(1) ttl(1) timestamp(8, ms) flags(1) payloadLength(2 | 4 for v2)
//   senderID(8) [recipientID(8)] [route: count(1) + count*8, v2 only]
//   [originalSize(2 | 4) when compressed] payload [signature(64)]
//
// Flags: 0x01 recipient, 0x02 signature, 0x04 compressed, 0x08 route, 0x10 RSR.

import 'dart:convert';
import 'dart:io' show ZLibCodec;
import 'dart:math';
import 'dart:typed_data';

class BcType {
  static const announce = 0x01;
  static const message = 0x02;
  static const leave = 0x03;
  static const noiseHandshake = 0x10;
  static const noiseEncrypted = 0x11;
  static const fragment = 0x20;
  static const requestSync = 0x21;
  static const fileTransfer = 0x22;
  static const voiceFrame = 0x29;
}

class BcFlags {
  static const hasRecipient = 0x01;
  static const hasSignature = 0x02;
  static const isCompressed = 0x04;
  static const hasRoute = 0x08;
  static const isRSR = 0x10;
}

class BcConst {
  static const v1Header = 14;
  static const v2Header = 16;
  static const idSize = 8;
  static const sigSize = 64;
  static const defaultTtl = 7;

  /// bitchat compresses payloads of 100+ bytes (Constants.compressionThresholdBytes).
  static const compressionThreshold = 100;

  /// Largest payload we accept when decoding (bitchat's own cap for files is
  /// ~1 MiB; we only need text, but must still relay what others send).
  static const maxPayload = 1100 * 1024;

  /// Signed payloads we ORIGINATE stay below the compression threshold. iOS
  /// re-encodes (and so re-compresses with Apple's zlib) when it checks a
  /// signature; our deflate output would differ byte for byte, so a
  /// compressed MeshTalk packet could fail verification on iPhones.
  static const maxSignedPayload = compressionThreshold - 1;

  static final broadcastRecipient = Uint8List.fromList(List.filled(8, 0xFF));
}

String bcHex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Uint8List bcUnhex(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

// ── compression (Apple COMPRESSION_ZLIB == raw DEFLATE, RFC 1951) ────────

class BcCompression {
  static final _codec = ZLibCodec(raw: true);

  /// Same rule as bitchat's CompressionUtil.shouldCompress.
  static bool shouldCompress(List<int> data) {
    if (data.length < BcConst.compressionThreshold) return false;
    final unique = data.toSet().length;
    final sample = min(data.length, 256);
    return unique / sample < 0.9;
  }

  static Uint8List? compress(List<int> data) {
    try {
      final c = _codec.encode(data);
      if (c.isEmpty || c.length >= data.length) return null;
      return Uint8List.fromList(c);
    } catch (_) {
      return null;
    }
  }

  static final _wrapped = ZLibCodec();

  /// Raw DEFLATE first (what bitchat sends), zlib-wrapped as a fallback.
  static Uint8List? decompress(List<int> data, int originalSize) {
    for (final codec in [_codec, _wrapped]) {
      try {
        final d = codec.decode(data);
        if (d.length == originalSize) return Uint8List.fromList(d);
      } catch (_) {}
    }
    return null;
  }
}

// ── padding (PKCS#7-style to 256/512/1024/2048 buckets) ──────────────────

class BcPadding {
  static const blocks = [256, 512, 1024, 2048];

  static int optimalBlockSize(int size) {
    final total = size + 16;
    for (final b in blocks) {
      if (total <= b) return b;
    }
    return size;
  }

  static Uint8List pad(Uint8List data, int target) {
    if (data.length >= target) return data;
    final n = target - data.length;
    if (n <= 0 || n > 255) return data;
    final out = Uint8List(target)..setRange(0, data.length, data);
    out.fillRange(data.length, target, n);
    return out;
  }

  static Uint8List unpad(Uint8List data) {
    if (data.isEmpty) return data;
    final n = data.last;
    if (n == 0 || n > data.length) return data;
    for (var i = data.length - n; i < data.length; i++) {
      if (data[i] != n) return data;
    }
    return Uint8List.sublistView(data, 0, data.length - n);
  }
}

// ── packet ───────────────────────────────────────────────────────────────

class BcPacket {
  BcPacket({
    this.version = 1,
    required this.type,
    required this.ttl,
    required this.timestamp,
    required this.senderID,
    this.recipientID,
    required this.payload,
    this.signature,
    this.route,
    this.isRSR = false,
    this.wirePayload,
    this.wireOriginalSize,
  });

  int version;
  int type;
  int ttl;
  int timestamp; // ms since epoch
  Uint8List senderID; // 8 bytes
  Uint8List? recipientID; // 8 bytes
  Uint8List payload; // decoded (decompressed) payload
  Uint8List? signature; // 64 bytes
  List<Uint8List>? route; // v2 only
  bool isRSR;

  /// The payload exactly as it arrived (compressed bytes) when the sender
  /// compressed it, so relays and signature checks reuse the originator's
  /// bytes instead of re-compressing.
  Uint8List? wirePayload;
  int? wireOriginalSize;

  String get senderHex => bcHex(senderID);
  String? get recipientHex => recipientID == null ? null : bcHex(recipientID!);

  bool get isBroadcast =>
      recipientID == null ||
      _sameBytes(recipientID!, BcConst.broadcastRecipient);

  BcPacket copyWith({int? ttl, Uint8List? signature, bool clearSignature = false}) =>
      BcPacket(
        version: version,
        type: type,
        ttl: ttl ?? this.ttl,
        timestamp: timestamp,
        senderID: senderID,
        recipientID: recipientID,
        payload: payload,
        signature: clearSignature ? null : (signature ?? this.signature),
        route: route,
        isRSR: isRSR,
        wirePayload: wirePayload,
        wireOriginalSize: wireOriginalSize,
      );

  /// Key bitchat uses to drop duplicates: sender-timestamp-type-digest.
  /// [digest] = first 4 bytes of SHA-256(payload), hex (computed by caller).
  String dedupKey(String digestHex) => '$senderHex-$timestamp-$type-$digestHex';
}

class BcCodec {
  static int? headerSize(int version) => version == 1
      ? BcConst.v1Header
      : version == 2
          ? BcConst.v2Header
          : null;

  /// Encodes a packet. [allowCompression] follows bitchat's rule
  /// (payload >= 100 bytes and compressible) unless the packet already
  /// carries the originator's compressed bytes.
  static Uint8List? encode(BcPacket p,
      {bool pad = false, bool allowCompression = true}) {
    final v = p.version;
    if (v != 1 && v != 2) return null;
    final lenBytes = v == 2 ? 4 : 2;

    Uint8List body = p.payload;
    int? originalSize;
    if (p.wirePayload != null && p.wireOriginalSize != null) {
      body = p.wirePayload!;
      originalSize = p.wireOriginalSize;
    } else if (allowCompression && BcCompression.shouldCompress(p.payload)) {
      final c = BcCompression.compress(p.payload);
      if (c != null) {
        body = c;
        originalSize = p.payload.length;
      }
    }
    final compressed = originalSize != null;

    final route = v >= 2 ? (p.route ?? const <Uint8List>[]) : const <Uint8List>[];
    if (route.length > 255) return null;
    final payloadDataSize = body.length + (compressed ? lenBytes : 0);
    if (v == 1 && payloadDataSize > 0xFFFF) return null;

    final b = BytesBuilder(copy: false);
    b.addByte(v);
    b.addByte(p.type & 0xFF);
    b.addByte(p.ttl & 0xFF);
    final ts = ByteData(8)..setUint64(0, p.timestamp);
    b.add(ts.buffer.asUint8List());
    var flags = 0;
    if (p.recipientID != null) flags |= BcFlags.hasRecipient;
    if (p.signature != null) flags |= BcFlags.hasSignature;
    if (compressed) flags |= BcFlags.isCompressed;
    if (route.isNotEmpty) flags |= BcFlags.hasRoute;
    if (p.isRSR) flags |= BcFlags.isRSR;
    b.addByte(flags);
    if (v == 2) {
      b.add((ByteData(4)..setUint32(0, payloadDataSize)).buffer.asUint8List());
    } else {
      b.add((ByteData(2)..setUint16(0, payloadDataSize)).buffer.asUint8List());
    }
    b.add(_fixed8(p.senderID));
    if (p.recipientID != null) b.add(_fixed8(p.recipientID!));
    if (route.isNotEmpty) {
      b.addByte(route.length);
      for (final hop in route) {
        b.add(_fixed8(hop));
      }
    }
    if (originalSize != null) {
      if (v == 2) {
        b.add((ByteData(4)..setUint32(0, originalSize)).buffer.asUint8List());
      } else {
        b.add((ByteData(2)..setUint16(0, originalSize)).buffer.asUint8List());
      }
    }
    b.add(body);
    if (p.signature != null) b.add(p.signature!.sublist(0, BcConst.sigSize));
    final out = b.takeBytes();
    return pad ? BcPadding.pad(out, BcPadding.optimalBlockSize(out.length)) : out;
  }

  static Uint8List _fixed8(Uint8List d) {
    if (d.length == 8) return d;
    final out = Uint8List(8);
    out.setRange(0, min(8, d.length), d);
    return out;
  }

  /// Decodes a packet; tries as-is, then with padding removed.
  static BcPacket? decode(Uint8List data) {
    final p = _decodeCore(data);
    if (p != null) return p;
    final unpadded = BcPadding.unpad(data);
    if (unpadded.length == data.length) return null;
    return _decodeCore(unpadded);
  }

  /// Total encoded length of the frame at the start of [d], or null if
  /// there aren't enough bytes yet to tell. Returns -1 if [d] can't be a
  /// frame start (unknown version).
  static int? frameLength(Uint8List d) {
    if (d.isEmpty) return null;
    final v = d[0];
    final hs = headerSize(v);
    if (hs == null) return -1;
    if (d.length < hs) return null;
    final flags = d[BcConst.v1Header - 3];
    final bd = ByteData.sublistView(d);
    final payloadLen = v == 2 ? bd.getUint32(12) : bd.getUint16(12);
    var len = hs + BcConst.idSize + payloadLen;
    if (flags & BcFlags.hasRecipient != 0) len += BcConst.idSize;
    if (flags & BcFlags.hasSignature != 0) len += BcConst.sigSize;
    if (v >= 2 && flags & BcFlags.hasRoute != 0) {
      final routeAt = hs + BcConst.idSize +
          (flags & BcFlags.hasRecipient != 0 ? BcConst.idSize : 0);
      if (d.length <= routeAt) return null;
      len += 1 + d[routeAt] * BcConst.idSize;
    }
    return len;
  }

  static BcPacket? _decodeCore(Uint8List raw) {
    if (raw.length < BcConst.v1Header + BcConst.idSize) return null;
    final bd = ByteData.sublistView(raw);
    var o = 0;
    bool need(int n) => o + n <= raw.length;

    final v = raw[o++];
    if (v != 1 && v != 2) return null;
    final hs = headerSize(v)!;
    if (raw.length < hs + BcConst.idSize) return null;
    final lenBytes = v == 2 ? 4 : 2;
    final type = raw[o++];
    final ttl = raw[o++];
    final ts = bd.getUint64(o);
    o += 8;
    final flags = raw[o++];
    final hasRecipient = flags & BcFlags.hasRecipient != 0;
    final hasSignature = flags & BcFlags.hasSignature != 0;
    final isCompressed = flags & BcFlags.isCompressed != 0;
    final hasRoute = v >= 2 && flags & BcFlags.hasRoute != 0;
    final isRSR = flags & BcFlags.isRSR != 0;
    final int payloadLen;
    if (v == 2) {
      payloadLen = bd.getUint32(o);
      o += 4;
    } else {
      payloadLen = bd.getUint16(o);
      o += 2;
    }
    if (payloadLen > BcConst.maxPayload) return null;
    if (!need(8)) return null;
    final sender = Uint8List.fromList(raw.sublist(o, o + 8));
    o += 8;
    Uint8List? recipient;
    if (hasRecipient) {
      if (!need(8)) return null;
      recipient = Uint8List.fromList(raw.sublist(o, o + 8));
      o += 8;
    }
    List<Uint8List>? route;
    if (hasRoute) {
      if (!need(1)) return null;
      final n = raw[o++];
      if (n > 0) {
        if (!need(n * 8)) return null;
        route = [
          for (var i = 0; i < n; i++)
            Uint8List.fromList(raw.sublist(o + i * 8, o + i * 8 + 8))
        ];
        o += n * 8;
      }
    }
    Uint8List payload;
    Uint8List? wire;
    int? wireOrig;
    if (isCompressed) {
      if (payloadLen < lenBytes || !need(payloadLen)) return null;
      final orig = v == 2 ? bd.getUint32(o) : bd.getUint16(o);
      o += lenBytes;
      final cLen = payloadLen - lenBytes;
      if (cLen <= 0 || orig > BcConst.maxPayload || orig > cLen * 50) return null;
      wire = Uint8List.fromList(raw.sublist(o, o + cLen));
      o += cLen;
      final d = BcCompression.decompress(wire, orig);
      if (d == null) return null;
      payload = d;
      wireOrig = orig;
    } else {
      if (!need(payloadLen)) return null;
      payload = Uint8List.fromList(raw.sublist(o, o + payloadLen));
      o += payloadLen;
    }
    Uint8List? sig;
    if (hasSignature) {
      if (!need(BcConst.sigSize)) return null;
      sig = Uint8List.fromList(raw.sublist(o, o + BcConst.sigSize));
      o += BcConst.sigSize;
    }
    return BcPacket(
      version: v,
      type: type,
      ttl: ttl,
      timestamp: ts,
      senderID: sender,
      recipientID: recipient,
      payload: payload,
      signature: sig,
      route: route,
      isRSR: isRSR,
      wirePayload: wire,
      wireOriginalSize: wireOrig,
    );
  }

  /// Bytes bitchat signs: the packet with ttl 0, no signature, no RSR flag,
  /// encoded WITH padding (BitchatPacket.toBinaryDataForSigning).
  static Uint8List? signingPreimage(BcPacket p) {
    final unsigned = BcPacket(
      version: p.version,
      type: p.type,
      ttl: 0,
      timestamp: p.timestamp,
      senderID: p.senderID,
      recipientID: p.recipientID,
      payload: p.payload,
      signature: null,
      route: p.route,
      isRSR: false,
      wirePayload: p.wirePayload,
      wireOriginalSize: p.wireOriginalSize,
    );
    // The signer encodes and sends the same bytes, so the preimage follows
    // the wire form exactly: compressed iff it arrived compressed. Our own
    // packets never compress (payload < 100 bytes).
    return encode(unsigned, pad: true, allowCompression: false);
  }
}

// ── stream assembly (several BLE chunks may make one frame) ──────────────

class BcStreamAssembler {
  static const cap = 64 * 1024;
  final _buf = BytesBuilder(copy: true);
  int _startedAt = 0;

  /// Feeds one BLE write/notification. Returns complete decoded frames.
  List<Uint8List> add(Uint8List chunk, int nowMs) {
    if (chunk.isEmpty) return const [];
    // Fast path: the chunk is exactly one frame (the normal case).
    if (_buf.isEmpty) {
      final fl = BcCodec.frameLength(chunk);
      if (fl != null && fl > 0 && fl <= chunk.length) {
        final frames = <Uint8List>[Uint8List.sublistView(chunk, 0, fl)];
        if (fl < chunk.length) {
          frames.addAll(add(Uint8List.sublistView(chunk, fl), nowMs));
        }
        return frames;
      }
    }
    if (_buf.isNotEmpty && nowMs - _startedAt > 5000) _buf.clear();
    if (_buf.isEmpty) _startedAt = nowMs;
    _buf.add(chunk);
    if (_buf.length > cap) {
      _buf.clear();
      return const [];
    }
    final frames = <Uint8List>[];
    var data = _buf.toBytes();
    while (data.isNotEmpty) {
      final fl = BcCodec.frameLength(data);
      if (fl == null) break; // need more bytes
      if (fl == -1) {
        // Not a frame start: drop trailing PKCS#7 padding or one stray byte.
        final n = data[0];
        var skip = 1;
        if (n > 0 && n <= data.length && data.sublist(0, n).every((b) => b == n)) {
          skip = n;
        }
        data = Uint8List.sublistView(data, skip);
        continue;
      }
      if (fl > data.length) break;
      frames.add(Uint8List.fromList(data.sublist(0, fl)));
      data = Uint8List.sublistView(data, fl);
    }
    _buf.clear();
    if (data.isNotEmpty) _buf.add(data);
    return frames;
  }
}

// ── fragments ────────────────────────────────────────────────────────────
// payload = fragmentID(8) index(2) total(2) originalType(1) chunk

class BcFragments {
  static const headerBytes = 13;
  static const maxTotal = 256;
  static final _rand = Random.secure();

  /// Splits an already-encoded packet into fragment packets.
  static List<BcPacket> split(BcPacket original, Uint8List encoded, int chunk) {
    final id = Uint8List.fromList(List.generate(8, (_) => _rand.nextInt(256)));
    final out = <BcPacket>[];
    final total = (encoded.length + chunk - 1) ~/ chunk;
    for (var i = 0; i < total; i++) {
      final part = encoded.sublist(i * chunk, min((i + 1) * chunk, encoded.length));
      final pl = BytesBuilder(copy: false)
        ..add(id)
        ..add((ByteData(2)..setUint16(0, i)).buffer.asUint8List())
        ..add((ByteData(2)..setUint16(0, total)).buffer.asUint8List())
        ..addByte(original.type)
        ..add(part);
      out.add(BcPacket(
        version: 1,
        type: BcType.fragment,
        ttl: original.ttl,
        timestamp: original.timestamp,
        senderID: original.senderID,
        recipientID: original.recipientID,
        payload: pl.takeBytes(),
      ));
    }
    return out;
  }
}

class _Assembly {
  _Assembly(this.total, this.startedAt);
  final int total;
  final int startedAt;
  final Map<int, Uint8List> parts = {};
  int bytes = 0;
}

class BcFragmentAssembler {
  static const timeoutMs = 30000;
  static const maxAssemblies = 128;
  static const maxBytes = 1024 * 1024 + 4096;
  final Map<String, _Assembly> _pending = {};

  /// Returns the reassembled original packet bytes when complete.
  Uint8List? add(BcPacket frag, int nowMs) {
    final p = frag.payload;
    if (p.length <= BcFragments.headerBytes) return null;
    final bd = ByteData.sublistView(p);
    final id = bcHex(p.sublist(0, 8));
    final index = bd.getUint16(8);
    final total = bd.getUint16(10);
    if (total == 0 || total > BcFragments.maxTotal || index >= total) return null;
    final key = '${frag.senderHex}:$id';
    _pending.removeWhere((_, a) => nowMs - a.startedAt > timeoutMs);
    if (!_pending.containsKey(key) && _pending.length >= maxAssemblies) return null;
    final a = _pending.putIfAbsent(key, () => _Assembly(total, nowMs));
    if (a.total != total) return null;
    if (a.parts.containsKey(index)) return null;
    final chunk = Uint8List.fromList(p.sublist(BcFragments.headerBytes));
    a.bytes += chunk.length;
    if (a.bytes > maxBytes) {
      _pending.remove(key);
      return null;
    }
    a.parts[index] = chunk;
    if (a.parts.length < total) return null;
    _pending.remove(key);
    final b = BytesBuilder(copy: false);
    for (var i = 0; i < total; i++) {
      b.add(a.parts[i]!);
    }
    return b.takeBytes();
  }
}

// ── announcement TLVs ────────────────────────────────────────────────────

class BcAnnounce {
  BcAnnounce({
    required this.nickname,
    required this.noiseKey,
    required this.signingKey,
    this.isMeshTalk = false,
  });

  final String nickname;
  final Uint8List noiseKey; // 32-byte Curve25519
  final Uint8List signingKey; // 32-byte Ed25519
  final bool isMeshTalk;

  static const _tNickname = 0x01, _tNoise = 0x02, _tSigning = 0x03;

  /// Private TLV marking MeshTalk phones. bitchat skips TLVs it doesn't know.
  static const _tMeshTalk = 0xF7;

  /// Largest nickname (UTF-8 bytes) that keeps the announce under the
  /// 100-byte compression threshold: 2+n + 34 + 34 + 3 <= 99.
  static const maxNickBytes = 26;

  static String clipNick(String nick) {
    var s = nick.trim();
    while (utf8.encode(s).length > maxNickBytes && s.isNotEmpty) {
      s = String.fromCharCodes(s.runes.toList()..removeLast());
    }
    return s.isEmpty ? 'meshtalk' : s;
  }

  Uint8List encode() {
    final nick = utf8.encode(clipNick(nickname));
    final b = BytesBuilder(copy: false)
      ..addByte(_tNickname)
      ..addByte(nick.length)
      ..add(nick)
      ..addByte(_tNoise)
      ..addByte(noiseKey.length)
      ..add(noiseKey)
      ..addByte(_tSigning)
      ..addByte(signingKey.length)
      ..add(signingKey);
    if (isMeshTalk) {
      b
        ..addByte(_tMeshTalk)
        ..addByte(1)
        ..addByte(1);
    }
    return b.takeBytes();
  }

  static BcAnnounce? decode(Uint8List d) {
    var o = 0;
    String? nick;
    Uint8List? noise, signing;
    var meshtalk = false;
    while (o + 2 <= d.length) {
      final t = d[o], len = d[o + 1];
      o += 2;
      if (o + len > d.length) return null;
      final v = d.sublist(o, o + len);
      o += len;
      switch (t) {
        case _tNickname:
          try {
            nick = utf8.decode(v);
          } catch (_) {
            return null;
          }
        case _tNoise:
          noise = Uint8List.fromList(v);
        case _tSigning:
          signing = Uint8List.fromList(v);
        case _tMeshTalk:
          meshtalk = true;
      }
    }
    if (nick == null || noise == null || signing == null) return null;
    if (noise.length != 32 || signing.length != 32) return null;
    return BcAnnounce(
        nickname: nick.length > 32 ? nick.substring(0, 32) : nick,
        noiseKey: noise,
        signingKey: signing,
        isMeshTalk: meshtalk);
  }
}

/// Splits [text] into UTF-8 pieces of at most [maxBytes] bytes, never
/// cutting a character in half.
List<String> bcSplitText(String text, int maxBytes) {
  final out = <String>[];
  final cur = StringBuffer();
  var curBytes = 0;
  for (final r in text.runes) {
    final ch = String.fromCharCode(r);
    final n = utf8.encode(ch).length;
    if (curBytes + n > maxBytes && cur.isNotEmpty) {
      out.add(cur.toString());
      cur.clear();
      curBytes = 0;
    }
    cur.write(ch);
    curBytes += n;
  }
  if (cur.isNotEmpty) out.add(cur.toString());
  return out;
}
