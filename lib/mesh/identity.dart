import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// This phone's mesh identity.
///
/// The node id is the first 8 bytes of SHA-256(public key), so it is
/// self-certifying: nobody can claim your id without your private key,
/// and a dm can be checked against the id it says it came from.
class Identity {
  Identity._(this._keyPair, this.publicKey, this.nodeId);

  final SimpleKeyPair _keyPair;
  final Uint8List publicKey;
  final String nodeId;

  String get publicKeyB64 => base64Encode(publicKey);

  static final _x25519 = X25519();
  static final _aes = AesGcm.with256bits();
  static final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  static const _prefsKey = 'identity_seed_v1';

  /// Loads the saved key, or creates and saves a new one on first run.
  static Future<Identity> loadOrCreate() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_prefsKey);
    SimpleKeyPair kp;
    if (saved != null) {
      kp = await _x25519.newKeyPairFromSeed(base64Decode(saved));
    } else {
      kp = await _x25519.newKeyPair();
      final seed = await kp.extractPrivateKeyBytes();
      await prefs.setString(_prefsKey, base64Encode(seed));
    }
    final pub = Uint8List.fromList((await kp.extractPublicKey()).bytes);
    return Identity._(kp, pub, await nodeIdFor(pub));
  }

  static Future<String> nodeIdFor(List<int> publicKey) async {
    final h = await Sha256().hash(publicKey);
    return h.bytes
        .take(8)
        .map((x) => x.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  final Map<String, SecretKey> _sessionKeys = {};

  Future<SecretKey> _keyWith(String peerPubB64) async {
    final cached = _sessionKeys[peerPubB64];
    if (cached != null) return cached;
    final remote = SimplePublicKey(base64Decode(peerPubB64),
        type: KeyPairType.x25519);
    final shared =
    await _x25519.sharedSecretKey(keyPair: _keyPair, remotePublicKey: remote);
    final key = await _hkdf.deriveKey(
      secretKey: shared,
      nonce: utf8.encode('meshtalk-v1'),
      info: utf8.encode('dm'),
    );
    _sessionKeys[peerPubB64] = key;
    return key;
  }

  /// Encrypts [text] for the peer with public key [peerPubB64].
  /// [aad] binds the ciphertext to (src, dst, packet id) so it can't be
  /// replayed under another header.
  Future<Map<String, dynamic>> encrypt(
      String text, String peerPubB64, String aad) =>
      encryptBytes(utf8.encode(text), peerPubB64, aad);

  /// Same as [encrypt] for raw bytes (photo / voice chunks).
  Future<Map<String, dynamic>> encryptBytes(
      List<int> data, String peerPubB64, String aad) async {
    final key = await _keyWith(peerPubB64);
    final box =
    await _aes.encrypt(data, secretKey: key, aad: utf8.encode(aad));
    return {
      'pk': publicKeyB64,
      'n': base64Encode(box.nonce),
      'c': base64Encode(box.cipherText),
      'm': base64Encode(box.mac.bytes),
    };
  }

  /// Decrypts a dm body. Returns null if the sender key doesn't match
  /// [srcNodeId], or the message was tampered with.
  Future<String?> decrypt(
      Map<String, dynamic> body, String srcNodeId, String aad) async {
    final bytes = await decryptBytes(body, srcNodeId, aad);
    if (bytes == null) return null;
    try {
      return utf8.decode(bytes);
    } catch (_) {
      return null;
    }
  }

  /// Same as [decrypt] for raw bytes.
  Future<Uint8List?> decryptBytes(
      Map<String, dynamic> body, String srcNodeId, String aad) async {
    try {
      final pk = body['pk'] as String;
      if (await nodeIdFor(base64Decode(pk)) != srcNodeId) return null;
      final key = await _keyWith(pk);
      final box = SecretBox(
        base64Decode(body['c'] as String),
        nonce: base64Decode(body['n'] as String),
        mac: Mac(base64Decode(body['m'] as String)),
      );
      final clear =
      await _aes.decrypt(box, secretKey: key, aad: utf8.encode(aad));
      return Uint8List.fromList(clear);
    } catch (_) {
      return null;
    }
  }
}