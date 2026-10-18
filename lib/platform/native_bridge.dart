import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Talks to the Kotlin side (MainActivity.kt): foreground service,
/// notifications, voice recording / playback and live call audio.
///
/// If MainActivity.kt isn't the MeshTalk one (wrong folder/package, or the
/// app was hot-restarted after copying the Kotlin files instead of fully
/// rebuilt), every call fails with MissingPluginException. We then mark the
/// bridge unavailable once, stop calling it, and the UI shows a notice.
class NativeBridge {
  static const _ch = MethodChannel('meshtalk/native');
  static const _frames = EventChannel('meshtalk/call_frames');

  /// False once we know the native side isn't there.
  static bool available = true;
  static bool _warned = false;

  /// Path of the voice message playing right now (null = nothing playing).
  static final ValueNotifier<String?> playing = ValueNotifier(null);

  static final _recLimit = StreamController<void>.broadcast();

  /// Fires when a recording hits its maximum length.
  static Stream<void> get onRecordLimit => _recLimit.stream;

  static Stream<Uint8List>? _frameStream;

  /// ADPCM microphone frames during a live call (one every 100 ms).
  static Stream<Uint8List> get callFrames => _frameStream ??= _frames
      .receiveBroadcastStream()
      .where((e) => e is Uint8List)
      .cast<Uint8List>()
      .handleError((Object e) => debugPrint('call frames: $e'));

  /// Call once at startup: receives events pushed from Kotlin.
  static void init() {
    _ch.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'recLimit':
          _recLimit.add(null);
        case 'playDone':
          if (playing.value == call.arguments) playing.value = null;
      }
      return null;
    });
  }

  // ── basics ──────────────────────────────────────────────────────────

  static Future<int> sdkInt() async => await _invoke<int>('sdkInt') ?? 0;

  /// App-private storage folder (null if the native side is missing).
  static Future<String?> filesDir() => _invoke<String>('filesDir');

  // ── foreground service + notifications ──────────────────────────────

  /// Keeps the process alive while the app is in the background, so the
  /// mesh keeps relaying. Shows a persistent "Mesh is running" notification.
  static Future<void> startService() => _invoke<void>('startService');

  static Future<void> stopService() => _invoke<void>('stopService');

  static Future<void> updateService(String text) =>
      _invoke<void>('updateService', {'text': text});

  /// Adds the microphone type to the service during a call.
  static Future<void> serviceMic(bool on) =>
      _invoke<void>('serviceMic', {'on': on});

  /// Adds the location type to the service while an SOS shares live location.
  static Future<void> serviceLocation(bool on) =>
      _invoke<void>('serviceLocation', {'on': on});

  /// Posts a notification (used for SOS, private messages, calls).
  static Future<void> notify(String title, String body,
          {bool urgent = false}) =>
      _invoke<void>(
          'notify', {'title': title, 'body': body, 'urgent': urgent});

  // ── location (SOS) ──────────────────────────────────────────────────

  /// Whether GPS or network location is switched on.
  static Future<bool> locEnabled() async =>
      await _invoke<bool>('locEnabled') ?? false;

  /// Last cached position, instantly (may be old or null).
  static Future<GeoFix?> locLast() async =>
      GeoFix.fromMap(await _invoke<Map>('locLast'));

  /// A fresh position: waits up to [timeoutMs] for a fix accurate to ~30 m,
  /// otherwise returns the best fix seen (or the cached one, or null).
  static Future<GeoFix?> locCurrent({int timeoutMs = 15000}) async =>
      GeoFix.fromMap(await _invoke<Map>('locCurrent', {'timeoutMs': timeoutMs}));

  /// Opens a position in the phone's maps app. False if nothing could open it.
  static Future<bool> openMap(double lat, double lon, {String label = 'SOS'}) async =>
      await _invoke<bool>('openMap', {'lat': lat, 'lon': lon, 'label': label}) ??
      false;

  // ── voice messages ──────────────────────────────────────────────────

  static Future<bool> recStart(String path, {int maxMs = 10500}) async =>
      await _invoke<bool>('recStart', {'path': path, 'maxMs': maxMs}) ?? false;

  /// Length of the recording in ms, or -1 if it failed / was too short.
  static Future<int> recStop() async => await _invoke<int>('recStop') ?? -1;

  static Future<void> recCancel() => _invoke<void>('recCancel');

  static Future<bool> play(String path) async {
    final ok = await _invoke<bool>('play', {'path': path}) ?? false;
    playing.value = ok ? path : null;
    return ok;
  }

  static Future<void> stopPlay() async {
    playing.value = null;
    await _invoke<void>('stopPlay');
  }

  // ── live calls ──────────────────────────────────────────────────────

  static Future<bool> callStart({bool speaker = false}) async {
    playing.value = null;
    return await _invoke<bool>('callStart', {'speaker': speaker}) ?? false;
  }

  static Future<void> callPlay(Uint8List frame) =>
      _invoke<void>('callPlay', {'data': frame});

  static Future<void> callMute(bool on) => _invoke<void>('callMute', {'on': on});

  static Future<void> callSpeaker(bool on) =>
      _invoke<void>('callSpeaker', {'on': on});

  static Future<void> callStop() => _invoke<void>('callStop');

  // ── plumbing ────────────────────────────────────────────────────────

  static Future<T?> _invoke<T>(String m, [Map<String, dynamic>? args]) async {
    if (!available) return null;
    try {
      return await _ch.invokeMethod<T>(m, args);
    } on MissingPluginException {
      _markMissing();
    } catch (e) {
      debugPrint('native $m failed: $e');
    }
    return null;
  }

  static void _markMissing() {
    available = false;
    if (_warned) return;
    _warned = true;
    debugPrint('MeshTalk: native channel "meshtalk/native" not found. '
        'Check MainActivity.kt is the MeshTalk version in your package folder, '
        'then stop the app and run "flutter run" again '
        '(hot restart does not reload Kotlin code).');
  }
}

/// One GPS / network position.
class GeoFix {
  final double lat, lon;

  /// Accuracy radius in metres (0 = unknown).
  final double acc;

  /// When the fix was taken (ms since epoch).
  final int ts;

  const GeoFix(this.lat, this.lon, this.acc, this.ts);

  static GeoFix? fromMap(Map? m) {
    if (m == null) return null;
    final lat = (m['lat'] as num?)?.toDouble();
    final lon = (m['lon'] as num?)?.toDouble();
    if (lat == null || lon == null) return null;
    return GeoFix(lat, lon, (m['acc'] as num?)?.toDouble() ?? 0,
        (m['ts'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch);
  }
}
