import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshtalk/mesh/media.dart';
import 'package:meshtalk/mesh/packet.dart';
import 'package:meshtalk/mesh/router.dart';
import 'package:meshtalk/mesh/transport.dart';

/// In-memory radio network. `connect(a, b)` is a direct link.
class FakeNet {
  final Map<String, FakeTransport> nodes = {};
  int sent = 0;

  FakeTransport add(String id) => nodes[id] = FakeTransport(id, this);

  void connect(String a, String b) {
    nodes[a]!._up('$a-$b', b);
    nodes[b]!._up('$b-$a', a);
  }

  void disconnect(String a, String b) {
    nodes[a]!._down('$a-$b');
    nodes[b]!._down('$b-$a');
  }
}

class FakeTransport implements MeshTransport {
  FakeTransport(this.id, this.net);
  final String id;
  final FakeNet net;
  final Map<String, String> _links = {}; // linkId → peer node

  @override
  void Function(String, String)? onLinkUp;
  @override
  void Function(String)? onLinkDown;
  @override
  void Function(String, Uint8List)? onData;

  void _up(String link, String peer) {
    _links[link] = peer;
    onLinkUp?.call(link, peer);
  }

  void _down(String link) {
    if (_links.remove(link) != null) onLinkDown?.call(link);
  }

  @override
  Set<String> get links => _links.keys.toSet();
  @override
  String? nodeOf(String linkId) => _links[linkId];
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}

  @override
  Future<bool> send(String linkId, Uint8List data) async {
    final peer = _links[linkId];
    if (peer == null) return false;
    net.sent++;
    final copy = Uint8List.fromList(data);
    scheduleMicrotask(() => net.nodes[peer]!.onData?.call('$peer-$id', copy));
    return true;
  }
}

/// 16-hex node ids.
String nid(int n) => n.toRadixString(16).padLeft(16, '0');

Packet pkt(String src, String type,
        {String? dst, int ttl = 7, Map<String, dynamic>? body, int? ts}) =>
    Packet(
      id: Packet.newId(),
      type: type,
      src: src,
      srcName: 'n$src',
      dst: dst,
      ttl: ttl,
      ts: ts ?? DateTime.now().millisecondsSinceEpoch,
      body: body ?? {'x': 'hi'},
    );

class Mesh {
  final net = FakeNet();
  final routers = <String, MeshRouter>{};
  final got = <String, List<Packet>>{};

  MeshRouter add(String id, {int maxTtl = 7}) {
    final t = net.add(id);
    final r = MeshRouter(selfId: id, transport: t, maxTtl: maxTtl);
    routers[id] = r;
    got[id] = [];
    r.incoming.listen(got[id]!.add);
    return r;
  }

  List<Packet> of(String id, String type) =>
      got[id]!.where((p) => p.type == type).toList();
}

Future<void> settle() async {
  for (var i = 0; i < 50; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test('packet encode/decode round-trip and rejects garbage', () {
    final p = pkt(nid(1), PacketType.chat, dst: nid(2));
    final back = Packet.decode(p.encode())!;
    expect(back.id, p.id);
    expect(back.dst, nid(2));
    expect(back.body['x'], 'hi');
    expect(Packet.decode(Uint8List.fromList([1, 2, 3])), isNull);
    final bad = Uint8List.fromList('{"id":"x","t":"chat"}'.codeUnits);
    expect(Packet.decode(bad), isNull);
    expect(Packet.decode(Uint8List(kMaxPacketBytes + 1)), isNull);
  });

  test('message crosses a 5-phone line (multi-hop) with correct hop count', () async {
    final m = Mesh();
    final ids = List.generate(5, (i) => nid(i + 1));
    for (final id in ids) {
      m.add(id);
    }
    for (var i = 0; i < 4; i++) {
      m.net.connect(ids[i], ids[i + 1]);
    }
    await settle();

    m.routers[ids[0]]!.send(pkt(ids[0], PacketType.chat));
    await settle();

    for (var i = 1; i < 5; i++) {
      final got = m.of(ids[i], PacketType.chat);
      expect(got.length, 1, reason: 'node $i should get it exactly once');
      expect(got.single.hops + 1, i, reason: 'node $i is $i hops away');
    }
  });

  test('dedup: a ring delivers once per node and the flood terminates', () async {
    final m = Mesh();
    final ids = List.generate(6, (i) => nid(i + 1));
    for (final id in ids) {
      m.add(id);
    }
    for (var i = 0; i < 6; i++) {
      m.net.connect(ids[i], ids[(i + 1) % 6]);
    }
    // plus some chords to create more loops
    m.net.connect(ids[0], ids[3]);
    m.net.connect(ids[1], ids[4]);
    await settle();

    final before = m.net.sent;
    m.routers[ids[0]]!.send(pkt(ids[0], PacketType.chat));
    await settle();

    for (var i = 1; i < 6; i++) {
      expect(m.of(ids[i], PacketType.chat).length, 1);
    }
    expect(m.of(ids[0], PacketType.chat), isEmpty, reason: 'no echo to sender');
    // each node forwards at most once to each of its links (8 links → ≤ 16 sends)
    expect(m.net.sent - before, lessThanOrEqualTo(16));
  });

  test('TTL limits how far a packet travels', () async {
    final m = Mesh();
    final ids = List.generate(6, (i) => nid(i + 1));
    for (final id in ids) {
      m.add(id);
    }
    for (var i = 0; i < 5; i++) {
      m.net.connect(ids[i], ids[i + 1]);
    }
    await settle();
    m.routers[ids[0]]!.send(pkt(ids[0], PacketType.chat, ttl: 3));
    await settle();
    expect(m.of(ids[1], PacketType.chat).length, 1);
    expect(m.of(ids[2], PacketType.chat).length, 1);
    expect(m.of(ids[3], PacketType.chat).length, 1);
    expect(m.of(ids[4], PacketType.chat), isEmpty);
    expect(m.of(ids[5], PacketType.chat), isEmpty);
  });

  test('dm is relayed but only delivered to its destination, and stops there', () async {
    final m = Mesh();
    final a = nid(1), b = nid(2), c = nid(3), d = nid(4);
    for (final id in [a, b, c, d]) {
      m.add(id);
    }
    m.net.connect(a, b);
    m.net.connect(b, c);
    m.net.connect(c, d);
    await settle();

    m.routers[a]!.send(pkt(a, PacketType.dm, dst: c));
    await settle();
    expect(m.of(b, PacketType.dm), isEmpty, reason: 'relay must not deliver');
    expect(m.of(c, PacketType.dm).length, 1);
    expect(m.of(d, PacketType.dm), isEmpty, reason: 'no forwarding past dst');
  });

  test('announcements build the peer table with hop distances', () async {
    final m = Mesh();
    final ids = List.generate(4, (i) => nid(i + 1));
    for (final id in ids) {
      m.add(id);
    }
    for (var i = 0; i < 3; i++) {
      m.net.connect(ids[i], ids[i + 1]);
    }
    await settle();
    for (final id in ids) {
      m.routers[id]!.send(pkt(id, PacketType.ann, body: {'pk': 'key-$id'}));
    }
    await settle();

    final table = m.routers[ids[0]]!.peers;
    expect(table.keys.toSet(), {ids[1], ids[2], ids[3]});
    expect(table[ids[1]]!.hops, 1);
    expect(table[ids[2]]!.hops, 2);
    expect(table[ids[3]]!.hops, 3);
    expect(table[ids[3]]!.pubKey, 'key-${ids[3]}');
  });

  test('store-and-forward: a phone that joins later still gets recent messages',
      () async {
    final m = Mesh();
    final a = nid(1), b = nid(2), c = nid(3);
    for (final id in [a, b, c]) {
      m.add(id);
    }
    m.net.connect(a, b);
    await settle();
    m.routers[a]!.send(pkt(a, PacketType.chat, body: {'x': 'before C arrived'}));
    m.routers[a]!.send(pkt(a, PacketType.ann, body: {'pk': 'k'}));
    await settle();
    expect(m.of(c, PacketType.chat), isEmpty);

    m.net.connect(b, c); // C walks into B's range
    await settle();
    final got = m.of(c, PacketType.chat);
    expect(got.length, 1);
    expect(got.single.body['x'], 'before C arrived');
    expect(got.single.hops + 1, 2);
    expect(m.of(c, PacketType.ann), isEmpty, reason: 'announcements are not replayed');
  });

  test('SOS jumps the queue ahead of chat', () async {
    final m = Mesh();
    final a = nid(1), b = nid(2);
    m.add(a);
    m.add(b);
    // queue up traffic before the link exists, then link: buffer replays
    for (var i = 0; i < 5; i++) {
      m.routers[a]!.send(pkt(a, PacketType.chat, body: {'x': 'chat $i'}));
    }
    m.routers[a]!.send(pkt(a, PacketType.sos, body: {'x': 'help'}));
    m.net.connect(a, b);
    await settle();
    final types = m.got[b]!.map((p) => p.type).toList();
    expect(types.first, PacketType.sos);
    expect(types.where((t) => t == PacketType.chat).length, 5);
  });

  test('own packets echoed back are ignored, stale peers expire', () async {
    var now = DateTime.now().millisecondsSinceEpoch;
    final net = FakeNet();
    final a = nid(1), b = nid(2);
    final ta = net.add(a), tb = net.add(b);
    final ra = MeshRouter(selfId: a, transport: ta, clock: () => now);
    final rb = MeshRouter(selfId: b, transport: tb, clock: () => now);
    final gotA = <Packet>[];
    ra.incoming.listen(gotA.add);
    net.connect(a, b);
    await settle();

    rb.send(pkt(b, PacketType.ann, body: {'pk': 'k'}, ts: now));
    await settle();
    expect(ra.peers.containsKey(b), isTrue);

    // B (maliciously or by bug) sends A's own packet back
    final mine = pkt(a, PacketType.chat, ts: now);
    tb.send('$b-$a', mine.encode());
    await settle();
    expect(gotA.where((p) => p.type == PacketType.chat), isEmpty);

    now += MeshRouter.peerExpiryMs + 1;
    ra.sweep();
    expect(ra.peers.containsKey(b), isFalse);
  });

  test('packets with absurd timestamps are dropped', () async {
    final m = Mesh();
    final a = nid(1), b = nid(2);
    m.add(a);
    m.add(b);
    m.net.connect(a, b);
    await settle();
    final old = DateTime.now().millisecondsSinceEpoch - 3 * 24 * 3600 * 1000;
    m.routers[a]!.send(pkt(a, PacketType.chat, ts: old));
    await settle();
    expect(m.of(b, PacketType.chat), isEmpty);
  });

  test('call audio frames go to the direct neighbour only, never relayed',
      () async {
    final m = Mesh();
    final a = nid(1), b = nid(2), c = nid(3);
    for (final id in [a, b, c]) {
      m.add(id);
    }
    final rawB = <Uint8List>[], rawC = <Uint8List>[];
    m.routers[b]!.onRawFrame = (_, d) => rawB.add(d);
    m.routers[c]!.onRawFrame = (_, d) => rawC.add(d);
    m.net.connect(a, b);
    m.net.connect(b, c);
    await settle();

    final ra = m.routers[a]!;
    final link = ra.linkFor(b)!;
    expect(ra.linkFor(c), isNull, reason: 'C is 2 hops away');
    final frame = Uint8List.fromList([kRawFrameMarker, 1, 2, 3, 4, 5, 6, 7, 8, 0, 0, 9, 9]);
    await ra.sendRaw(link, frame);
    await settle();
    expect(rawB.length, 1);
    expect(rawB.single, frame);
    expect(rawC, isEmpty);
    expect(m.got[b], isEmpty, reason: 'raw frames are not packets');
  });

  test('photo chunks and call signals are not replayed to late joiners',
      () async {
    final m = Mesh();
    final a = nid(1), b = nid(2), c = nid(3);
    for (final id in [a, b, c]) {
      m.add(id);
    }
    m.net.connect(a, b);
    await settle();
    m.routers[a]!.send(pkt(a, PacketType.blob,
        body: {'mid': nid(99), 'k': 'img', 'i': 0, 'cnt': 1, 'd': 'AAAA'}));
    m.routers[a]!.send(pkt(a, PacketType.chat, body: {'x': 'hello'}));
    await settle();
    expect(m.of(b, PacketType.blob).length, 1, reason: 'live delivery works');

    m.net.connect(b, c);
    await settle();
    expect(m.of(c, PacketType.chat).length, 1, reason: 'text is replayed');
    expect(m.of(c, PacketType.blob), isEmpty, reason: 'media is not');
  });

  test('call signal with ttl 1 reaches the neighbour but goes no further',
      () async {
    final m = Mesh();
    final a = nid(1), b = nid(2), c = nid(3);
    for (final id in [a, b, c]) {
      m.add(id);
    }
    m.net.connect(a, b);
    m.net.connect(b, c);
    await settle();
    m.routers[a]!.send(pkt(a, PacketType.call, dst: b, ttl: 1, body: {'a': 'offer', 'c': nid(7)}));
    m.routers[a]!.send(pkt(a, PacketType.call, dst: c, ttl: 1, body: {'a': 'offer', 'c': nid(8)}));
    await settle();
    expect(m.of(b, PacketType.call).length, 1);
    expect(m.of(c, PacketType.call), isEmpty);
  });

  group('media', () {
    test('split + reassemble in any order, duplicates harmless', () {
      final data = Uint8List.fromList(List.generate(20000, (i) => i % 251));
      final chunks = splitChunks(data);
      expect(chunks.length, 3);
      expect(chunks.every((c) => c.length <= kChunkBytes), isTrue);

      final asm = MediaAssembler();
      IncomingMedia? im;
      for (final i in [2, 0, 2, 1]) {
        im = asm.add(
            mediaId: nid(5), kind: MediaKind.image, index: i, total: 3,
            bytes: chunks[i], src: nid(1), now: 0);
      }
      expect(im!.complete, isTrue);
      expect(im.assemble(), data);
    });

    test('rejects bad chunks and expires incomplete media', () {
      final asm = MediaAssembler();
      final one = Uint8List.fromList([1, 2, 3]);
      expect(asm.add(mediaId: nid(5), kind: 'exe', index: 0, total: 2, bytes: one, src: nid(1), now: 0), isNull);
      expect(asm.add(mediaId: nid(5), kind: MediaKind.voice, index: 2, total: 2, bytes: one, src: nid(1), now: 0), isNull);
      expect(asm.add(mediaId: nid(5), kind: MediaKind.voice, index: 0, total: kMaxChunks + 1, bytes: one, src: nid(1), now: 0), isNull);
      final first = asm.add(mediaId: nid(5), kind: MediaKind.voice, index: 0, total: 2, bytes: one, src: nid(1), now: 0);
      expect(first!.progress, 0.5);
      // same id from a different sender: ignored
      expect(asm.add(mediaId: nid(5), kind: MediaKind.voice, index: 1, total: 2, bytes: one, src: nid(2), now: 0), isNull);
      asm.prune(kAssemblyTimeoutMs + 1);
      expect(asm.pendingCount, 0);
    });
  });
}
