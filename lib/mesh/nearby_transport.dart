import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:nearby_connections/nearby_connections.dart';

import 'packet.dart';
import 'transport.dart';

/// Direct links via Google Nearby Connections (P2P_CLUSTER).
///
/// Nearby handles discovery + encrypted links over BLE / Bluetooth / Wi-Fi,
/// but only to phones in range. Multi-hop is done by MeshRouter on top.
///
/// Stability rules (from Nearby issue reports and open-source mesh projects):
///  * cap direct links per phone (clusters get flaky with many links);
///    the relay layer reaches everyone else;
///  * only one side initiates (lower node id), so two phones don't
///    request each other at the same moment and collide;
///  * stop advertising + discovery while at the cap, restart below it;
///  * restart discovery periodically, since it can silently stall;
///  * back off and retry failed connection attempts.
class NearbyTransport implements MeshTransport {
  NearbyTransport({required this.selfId, required String nick, this.maxLinks = 4})
      : _endpointName = '$selfId|${_shortNick(nick)}';

  static const serviceId = 'com.example.meshtalk.mesh';

  final String selfId;
  final int maxLinks;
  final String _endpointName;
  final Nearby _nearby = Nearby();

  @override
  void Function(String linkId, String nodeId)? onLinkUp;
  @override
  void Function(String linkId)? onLinkDown;
  @override
  void Function(String linkId, Uint8List data)? onData;

  /// Called with a human-readable problem (radio off, permission missing).
  void Function(String message)? onError;

  final Map<String, String> _found = {}; // endpointId → nodeId (in range)
  final Map<String, int> _foundAt = {}; // endpointId → first seen ms
  final Map<String, String> _linked = {}; // endpointId → nodeId (connected)
  final Map<String, String> _pending = {}; // endpointId → nodeId (connecting)
  final Set<String> _requestedByMe = {};
  final Map<String, int> _retryAt = {};
  final Map<String, int> _failures = {};

  bool _advertising = false;
  bool _discovering = false;
  bool _running = false;
  int _lastDiscoveryRestart = 0;
  Timer? _maintainTimer;

  static String _shortNick(String n) {
    final clean = n.replaceAll('|', ' ').trim();
    return clean.length > 20 ? clean.substring(0, 20) : clean;
  }

  static String? _nodeFromName(String? name) {
    if (name == null) return null;
    final id = name.split('|').first;
    return Packet.isNodeId(id) ? id : null;
  }

  int get _now => DateTime.now().millisecondsSinceEpoch;

  @override
  Set<String> get links => _linked.keys.toSet();

  @override
  String? nodeOf(String linkId) => _linked[linkId];

  int get _busy => _linked.length + _pending.length;

  @override
  Future<void> start() async {
    _running = true;
    await _ensureRadios();
    _maintainTimer ??=
        Timer.periodic(const Duration(seconds: 8), (_) => _maintain());
  }

  @override
  Future<void> stop() async {
    _running = false;
    _maintainTimer?.cancel();
    _maintainTimer = null;
    await _stopAdvertising();
    await _stopDiscovery();
    try {
      await _nearby.stopAllEndpoints();
    } catch (_) {}
    for (final id in _linked.keys.toList()) {
      onLinkDown?.call(id);
    }
    _linked.clear();
    _pending.clear();
    _found.clear();
  }

  @override
  Future<bool> send(String linkId, Uint8List data) async {
    if (!_linked.containsKey(linkId)) return false;
    try {
      await _nearby.sendBytesPayload(linkId, data);
      return true;
    } catch (e) {
      debugPrint('mesh: send to $linkId failed: $e');
      return false;
    }
  }

  // ── radios ────────────────────────────────────────────────────────────

  Future<void> _ensureRadios() async {
    if (!_running) return;
    if (_busy >= maxLinks) {
      await _stopAdvertising();
      await _stopDiscovery();
      return;
    }
    if (!_advertising) await _startAdvertising();
    if (!_discovering) await _startDiscovery();
  }

  Future<void> _startAdvertising() async {
    try {
      _advertising = await _nearby.startAdvertising(
        _endpointName,
        Strategy.P2P_CLUSTER,
        onConnectionInitiated: _onConnectionInitiated,
        onConnectionResult: _onConnectionResult,
        onDisconnected: _onDisconnected,
        serviceId: serviceId,
      );
    } catch (e) {
      _advertising = false;
      _report('Could not start advertising: $e');
    }
  }

  Future<void> _startDiscovery() async {
    try {
      _discovering = await _nearby.startDiscovery(
        _endpointName,
        Strategy.P2P_CLUSTER,
        onEndpointFound: _onEndpointFound,
        onEndpointLost: _onEndpointLost,
        serviceId: serviceId,
      );
      _lastDiscoveryRestart = _now;
    } catch (e) {
      _discovering = false;
      _report('Could not start discovery (is Bluetooth/Location on?): $e');
    }
  }

  Future<void> _stopAdvertising() async {
    if (!_advertising) return;
    _advertising = false;
    try {
      await _nearby.stopAdvertising();
    } catch (_) {}
  }

  Future<void> _stopDiscovery() async {
    if (!_discovering) return;
    _discovering = false;
    try {
      await _nearby.stopDiscovery();
    } catch (_) {}
  }

  void _report(String msg) {
    debugPrint('mesh: $msg');
    onError?.call(msg);
  }

  // ── discovery ─────────────────────────────────────────────────────────

  void _onEndpointFound(String endpointId, String endpointName, String sid) {
    final node = _nodeFromName(endpointName);
    if (node == null || node == selfId) return;
    _found[endpointId] = node;
    _foundAt.putIfAbsent(endpointId, () => _now);
    _maybeConnect(endpointId);
  }

  void _onEndpointLost(String? endpointId) {
    if (endpointId == null) return;
    _found.remove(endpointId);
    _foundAt.remove(endpointId);
  }

  bool _alreadyLinkedTo(String node) =>
      _linked.containsValue(node) || _pending.containsValue(node);

  Future<void> _maybeConnect(String endpointId) async {
    if (!_running) return;
    final node = _found[endpointId];
    if (node == null) return;
    if (_linked.containsKey(endpointId) || _pending.containsKey(endpointId)) {
      return;
    }
    if (_alreadyLinkedTo(node) || _busy >= maxLinks) return;
    if ((_retryAt[endpointId] ?? 0) > _now) return;

    // Lower id initiates. The higher id only steps in if the other side
    // hasn't connected after 30 s (it may be at its own link cap… or
    // waiting on us because its discovery stalled).
    final iInitiate = selfId.compareTo(node) < 0 ||
        _now - (_foundAt[endpointId] ?? _now) > 30000;
    if (!iInitiate) return;

    _pending[endpointId] = node;
    _requestedByMe.add(endpointId);
    try {
      await _nearby.requestConnection(
        _endpointName,
        endpointId,
        onConnectionInitiated: _onConnectionInitiated,
        onConnectionResult: _onConnectionResult,
        onDisconnected: _onDisconnected,
      );
    } catch (e) {
      debugPrint('mesh: requestConnection $endpointId failed: $e');
      _pending.remove(endpointId);
      _requestedByMe.remove(endpointId);
      _backoff(endpointId);
    }
  }

  void _backoff(String endpointId) {
    final n = (_failures[endpointId] ?? 0) + 1;
    _failures[endpointId] = n;
    final delay = (2000 * (1 << (n > 5 ? 5 : n))); // 4 s … 64 s
    _retryAt[endpointId] = _now + delay;
  }

  // ── connection lifecycle ──────────────────────────────────────────────

  void _onConnectionInitiated(String endpointId, ConnectionInfo info) {
    final node = _nodeFromName(info.endpointName);
    final mine = _requestedByMe.contains(endpointId);
    if (!mine) {
      // Incoming request: enforce the cap and one link per phone.
      if (node == null ||
          node == selfId ||
          _busy >= maxLinks ||
          _alreadyLinkedTo(node)) {
        _nearby.rejectConnection(endpointId).catchError((_) => false);
        return;
      }
      _pending[endpointId] = node;
    } else if (node != null) {
      _pending[endpointId] = node;
    }
    _nearby
        .acceptConnection(
          endpointId,
          onPayLoadRecieved: (eid, payload) {
            if (payload.type == PayloadType.BYTES && payload.bytes != null) {
              onData?.call(eid, payload.bytes!);
            }
          },
          onPayloadTransferUpdate: (eid, update) {},
        )
        .catchError((e) {
      debugPrint('mesh: accept $endpointId failed: $e');
      return false;
    });
  }

  void _onConnectionResult(String endpointId, Status status) {
    final node = _pending.remove(endpointId) ?? _found[endpointId];
    _requestedByMe.remove(endpointId);
    if (status == Status.CONNECTED && node != null) {
      if (_linked.containsValue(node)) {
        // Both sides connected at once: keep the first link only.
        _nearby.disconnectFromEndpoint(endpointId).catchError((_) {});
      } else {
        _linked[endpointId] = node;
        _failures.remove(endpointId);
        onLinkUp?.call(endpointId, node);
      }
    } else {
      _backoff(endpointId);
    }
    _ensureRadios();
  }

  void _onDisconnected(String endpointId) {
    _pending.remove(endpointId);
    _requestedByMe.remove(endpointId);
    if (_linked.remove(endpointId) != null) {
      onLinkDown?.call(endpointId);
    }
    _ensureRadios();
  }

  // ── periodic upkeep ───────────────────────────────────────────────────

  Future<void> _maintain() async {
    if (!_running) return;
    await _ensureRadios();
    // Discovery can stall without errors; restart it every 60 s while
    // we still want more links.
    if (_busy < maxLinks &&
        _discovering &&
        _now - _lastDiscoveryRestart > 60000) {
      await _stopDiscovery();
      await _startDiscovery();
    }
    for (final id in _found.keys.toList()) {
      await _maybeConnect(id);
    }
  }
}
