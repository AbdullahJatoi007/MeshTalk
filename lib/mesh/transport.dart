import 'dart:typed_data';

/// A radio that gives us direct links to phones in range.
///
/// The router only talks to this interface, so Nearby Connections can be
/// swapped for a raw-BLE or Wi-Fi Aware transport later without touching
/// the relay logic.
abstract class MeshTransport {
  /// A direct link came up. [nodeId] is the neighbour's mesh id.
  void Function(String linkId, String nodeId)? onLinkUp;

  /// A direct link went away.
  void Function(String linkId)? onLinkDown;

  /// Bytes arrived on a link.
  void Function(String linkId, Uint8List data)? onData;

  /// Currently connected link ids.
  Set<String> get links;

  /// Neighbour node id for a link, if known.
  String? nodeOf(String linkId);

  Future<void> start();
  Future<void> stop();

  /// Sends bytes over one link. Returns false if it failed.
  Future<bool> send(String linkId, Uint8List data);
}
