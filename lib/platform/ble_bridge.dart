import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../bitchat/bc_mesh.dart';

/// Bluetooth LE links in bitchat's format, driven by BitchatBle.kt.
///
/// Events from Kotlin (channel `meshtalk/ble_events`):
///   {e:'up', link, mtu} · {e:'down', link} · {e:'mtu', link, mtu}
///   {e:'data', link, data} · {e:'state', on, error?}
class BleBitchatTransport implements BcLinkTransport {
  static const _ch = MethodChannel('meshtalk/native');
  static const _events = EventChannel('meshtalk/ble_events');

  @override
  void Function(String link)? onLinkUp;
  @override
  void Function(String link)? onLinkDown;
  @override
  void Function(String link, Uint8List data)? onData;

  /// Bluetooth turned off, unsupported, or a permission is missing.
  void Function(String? problem)? onState;

  final Map<String, int> _mtu = {};
  StreamSubscription? _sub;
  Timer? _retry;
  bool _wanted = false;

  @override
  Set<String> get links => _mtu.keys.toSet();

  @override
  int maxWrite(String link) => ((_mtu[link] ?? 23) - 3).clamp(20, 512).toInt();

  @override
  Future<void> start() async {
    _wanted = true;
    _sub ??= _events.receiveBroadcastStream().listen(_onEvent,
        onError: (Object e) => debugPrint('ble events: $e'));
    await _startNative();
    // Bluetooth may be off or busy now; keep trying quietly.
    _retry ??= Timer.periodic(const Duration(seconds: 20), (_) {
      if (_wanted) _startNative();
    });
  }

  Future<void> _startNative() async {
    try {
      await _ch.invokeMethod('bleStart');
    } on MissingPluginException {
      onState?.call('native code missing');
    } catch (e) {
      debugPrint('bleStart failed: $e');
    }
  }

  @override
  Future<void> stop() async {
    _wanted = false;
    _retry?.cancel();
    _retry = null;
    try {
      await _ch.invokeMethod('bleStop');
    } catch (_) {}
    final gone = _mtu.keys.toList();
    _mtu.clear();
    for (final l in gone) {
      onLinkDown?.call(l);
    }
  }

  @override
  Future<bool> send(String link, Uint8List data) async {
    if (!_mtu.containsKey(link)) return false;
    try {
      return await _ch.invokeMethod<bool>('bleSend', {'link': link, 'data': data}) ??
          false;
    } catch (e) {
      debugPrint('bleSend failed: $e');
      return false;
    }
  }

  void _onEvent(dynamic raw) {
    if (raw is! Map) return;
    final e = raw['e'];
    final link = raw['link'] as String?;
    switch (e) {
      case 'up':
        if (link == null) return;
        final isNew = !_mtu.containsKey(link);
        _mtu[link] = (raw['mtu'] as int?) ?? 23;
        if (isNew) onLinkUp?.call(link);
      case 'mtu':
        if (link != null && _mtu.containsKey(link)) {
          _mtu[link] = (raw['mtu'] as int?) ?? _mtu[link]!;
        }
      case 'down':
        if (link != null && _mtu.remove(link) != null) onLinkDown?.call(link);
      case 'data':
        final data = raw['data'];
        if (link != null && data is Uint8List) onData?.call(link, data);
      case 'state':
        onState?.call(raw['on'] == true ? null : (raw['error'] as String? ?? 'Bluetooth is off'));
    }
  }
}
