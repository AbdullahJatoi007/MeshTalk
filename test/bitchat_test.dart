import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshtalk/bitchat/bc_mesh.dart';
import 'package:meshtalk/bitchat/bc_protocol.dart';

/// In-memory Bluetooth: connect(a, b) gives each side a link to the other.
class FakeAir {
  final Map<String, FakeBle> radios = {};
  FakeBle add(String name) => radios[name] = FakeBle(name, this);
  void connect(String a, String b) {
    radios[a]!._up('$a>$b', b);
    radios[b]!._up('$b>$a', a);
  }
}

class FakeBle implements BcLinkTransport {
  FakeBle(this.name, this.air);
  final String name;
  final FakeAir air;
  final Map<String, String> _links = {};
  int mtu = 185;

  @override
  void Function(String)? onLinkUp;
  @override
  void Function(String)? onLinkDown;
  @override
  void Function(String, Uint8List)? onData;

  void _up(String link, String peer) {
    _links[link] = peer;
    onLinkUp?.call(link);
  }

  @override
  Set<String> get links => _links.keys.toSet();
  @override
  int maxWrite(String link) => mtu - 3;
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<bool> send(String link, Uint8List data) async {
    final peer = _links[link];
    if (peer == null) return false;
    expect(data.length <= maxWrite(link), isTrue, reason: 'never exceed the link MTU');
    final copy = Uint8List.fromList(data);
    Future.microtask(() => air.radios[peer]!.onData?.call('$peer>$name', copy));
    return true;
  }
}

class Node {
  Node(this.mesh, this.ble);
  final BitchatMesh mesh;
  final FakeBle ble;
  final got = <BcPublicMessage>[];
  final bridged = <Uint8List>[];
}

final _ed = Ed25519();
final _x = X25519();

Future<Node> makeNode(FakeAir air, String name) async {
  final ble = air.add(name);
  final x = await _x.newKeyPair();
  final noise = Uint8List.fromList((await x.extractPublicKey()).bytes);
  final id = bcHex((await Sha256().hash(noise)).bytes.sublist(0, 8));
  final s = await _ed.newKeyPair();
  final signPub = Uint8List.fromList((await s.extractPublicKey()).bytes);
  late Node node;
  final mesh = BitchatMesh(
    selfId: id,
    noiseKey: noise,
    signingKey: signPub,
    sign: (m) async => Uint8List.fromList((await _ed.sign(m, keyPair: s)).bytes),
    verify: (m, sig, pk) => _ed.verify(m,
        signature: Signature(sig, publicKey: SimplePublicKey(pk, type: KeyPairType.ed25519))),
    transport: ble,
    nickname: () => name,
  );
  node = Node(mesh, ble);
  mesh.onPublicMessage = node.got.add;
  mesh.onBridgeOut = (enc, _) => node.bridged.add(enc);
  mesh.running = true; // start() without timers
  return node;
}

Future<void> settle([int ms = 600]) => Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  test('codec round trip, padding and signature preimage', () {
    final p = BcPacket(
      type: BcType.message,
      ttl: 7,
      timestamp: 1792332360000,
      senderID: bcUnhex('0102030405060708'),
      payload: Uint8List.fromList(utf8.encode('hello bitchat')),
      signature: Uint8List(64),
    );
    final enc = BcCodec.encode(p)!;
    expect(enc[0], 1);
    expect(enc[1], BcType.message);
    expect(BcCodec.frameLength(enc), enc.length);
    final back = BcCodec.decode(enc)!;
    expect(utf8.decode(back.payload), 'hello bitchat');
    expect(back.senderHex, '0102030405060708');
    final padded = BcCodec.encode(p, pad: true)!;
    expect(padded.length, 256);
    expect(BcCodec.decode(padded)!.payload, p.payload);
    // Preimage: ttl 0, no signature flag, padded to 256.
    final pre = BcCodec.signingPreimage(p.copyWith(ttl: 3))!;
    expect(pre.length, 256);
    expect(pre[2], 0);
    expect(pre[11] & BcFlags.hasSignature, 0);
  });

  test('announce stays below the compression threshold for any nickname', () {
    for (final nick in ['Ali', 'سلام دوستان من', '🙂' * 20, 'x' * 50]) {
      final a = BcAnnounce(
              nickname: nick, noiseKey: Uint8List(32), signingKey: Uint8List(32), isMeshTalk: true)
          .encode();
      expect(a.length < BcConst.compressionThreshold, isTrue, reason: nick);
      expect(BcAnnounce.decode(a)!.isMeshTalk, isTrue);
    }
  });

  test('peers discover each other and exchange public chat', () async {
    final air = FakeAir();
    final a = await makeNode(air, 'Ali');
    final b = await makeNode(air, 'Bushra');
    air.connect('Ali', 'Bushra');
    await a.mesh.sendAnnounce();
    await b.mesh.sendAnnounce();
    await settle();
    expect(b.mesh.peers[a.mesh.selfId]?.nickname, 'Ali');
    expect(a.mesh.peers[b.mesh.selfId]?.isMeshTalk, isTrue);

    await a.mesh.sendPublic('hi from MeshTalk');
    await settle();
    expect(b.got.single.text, 'hi from MeshTalk');
    expect(b.got.single.nickname, 'Ali');
    expect(b.got.single.hops, 1);
  });

  test('long messages go out in parts under 100 bytes', () async {
    final air = FakeAir();
    final a = await makeNode(air, 'A');
    final b = await makeNode(air, 'B');
    air.connect('A', 'B');
    await a.mesh.sendAnnounce();
    await settle();
    final long = List.filled(30, 'word').join(' '); // 149 bytes
    await a.mesh.sendPublic(long);
    await settle();
    expect(b.got.length, 2);
    // Receivers trim each part, so compare without spaces.
    expect(b.got.map((m) => m.text).join().replaceAll(' ', ''), long.replaceAll(' ', ''));
    expect(b.got.every((m) => utf8.encode(m.text).length < 100), isTrue);
  });

  test('relays across a 3-phone line, once each, with hop count', () async {
    final air = FakeAir();
    final a = await makeNode(air, 'A');
    final c = await makeNode(air, 'C');
    final b = await makeNode(air, 'B');
    air.connect('A', 'C');
    air.connect('C', 'B');
    await a.mesh.sendAnnounce();
    await settle();
    expect(b.mesh.peers.containsKey(a.mesh.selfId), isTrue, reason: 'announce relayed');
    await a.mesh.sendPublic('two hops');
    await settle();
    expect(b.got.length, 1);
    expect(b.got.single.hops, 2);
    expect(c.got.length, 1);
    expect(a.got, isEmpty, reason: 'no echo to sender');
  });

  test('forged, unsigned and replayed packets are rejected', () async {
    final air = FakeAir();
    final a = await makeNode(air, 'A');
    final b = await makeNode(air, 'B');
    air.connect('A', 'B');
    await a.mesh.sendAnnounce();
    await settle();

    // Unsigned public message claiming to be A.
    final unsigned = BcPacket(
      type: BcType.message,
      ttl: 7,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      senderID: bcUnhex(a.mesh.selfId),
      payload: Uint8List.fromList(utf8.encode('fake')),
    );
    await b.mesh.handleFrame('x', BcCodec.encode(unsigned)!);
    // Signed by the wrong key.
    final wrong = unsigned.copyWith(signature: Uint8List(64));
    await b.mesh.handleFrame('x', BcCodec.encode(wrong)!);
    await settle(100);
    expect(b.got, isEmpty);

    // A genuine message delivered twice is shown once.
    await a.mesh.sendPublic('real');
    await settle();
    expect(b.got.length, 1);
  });

  test('messages that arrive before the sender\'s announce are shown after it', () async {
    final air = FakeAir();
    final a = await makeNode(air, 'A');
    final b = await makeNode(air, 'B');
    air.connect('A', 'B');
    await a.mesh.sendPublic('early');
    await settle();
    expect(b.got, isEmpty);
    await a.mesh.sendAnnounce();
    await settle();
    expect(b.got.single.text, 'early');
  });

  test('packets bigger than the link are fragmented and reassembled', () async {
    final air = FakeAir();
    final a = await makeNode(air, 'A');
    final b = await makeNode(air, 'B');
    a.ble.mtu = 150; // small link: the ~167-byte announce must be split
    b.ble.mtu = 150;
    air.connect('A', 'B');
    await a.mesh.sendAnnounce();
    await settle();
    expect(b.mesh.peers.containsKey(a.mesh.selfId), isTrue);
    await a.mesh.sendPublic('fragmented hello');
    await settle();
    expect(b.got.single.text, 'fragmented hello');
  });

  test('bridge: packets go out over Nearby and come back in on another phone', () async {
    final air1 = FakeAir();
    final air2 = FakeAir();
    final a = await makeNode(air1, 'A'); // near bitchat user A…
    final m = await makeNode(air2, 'M'); // …MeshTalk phone M is elsewhere
    await a.mesh.sendAnnounce();
    await a.mesh.sendPublic('over the bridge');
    expect(a.bridged.length, 2, reason: 'announce + message handed to Nearby');
    for (final enc in a.bridged) {
      m.mesh.injectFromBridge(enc);
    }
    await settle();
    expect(m.mesh.peers.containsKey(a.mesh.selfId), isTrue);
    expect(m.got.single.text, 'over the bridge');
  });
}
