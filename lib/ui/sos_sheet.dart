import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../mesh/media.dart';
import '../platform/native_bridge.dart';
import 'theme.dart';
import 'widgets.dart';

/// A finished recording.
class VoiceClip {
  final String path;
  final int durMs;

  const VoiceClip(this.path, this.durMs);
}

/// Shown right after an SOS is sent: records 10 seconds of voice
/// automatically, then closes with the clip. "Send now" stops early,
/// "Skip" closes without sending anything.
///
/// Returns a [VoiceClip], or null if skipped / recording failed.
Future<VoiceClip?> showSosRecorder(BuildContext context) =>
    showModalBottomSheet<VoiceClip>(
      context: context,
      isDismissible: false,
      enableDrag: false,
      useSafeArea: true,
      builder: (_) => const _SosRecorderSheet(),
    );

class _SosRecorderSheet extends StatefulWidget {
  const _SosRecorderSheet();

  @override
  State<_SosRecorderSheet> createState() => _SosRecorderSheetState();
}

class _SosRecorderSheetState extends State<_SosRecorderSheet> {
  String? _path;
  DateTime? _start;
  Timer? _tick;
  StreamSubscription<void>? _limitSub;
  bool _done = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _begin();
  }

  Future<void> _begin() async {
    final path = MediaStore.newRecordingPath();
    final ok = await NativeBridge.recStart(path, maxMs: kMaxVoiceMs + 500);
    if (!mounted) {
      if (ok) NativeBridge.recCancel();
      return;
    }
    if (!ok) {
      setState(() => _error =
          "Couldn't start the microphone. Your SOS and location were still sent.");
      return;
    }
    setState(() {
      _path = path;
      _start = DateTime.now();
    });
    _limitSub = NativeBridge.onRecordLimit.listen((_) => _finish());
    _tick = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!mounted) return;
      if (_elapsedMs >= kMaxVoiceMs) {
        _finish();
      } else {
        setState(() {});
      }
    });
  }

  int get _elapsedMs =>
      _start == null ? 0 : DateTime.now().difference(_start!).inMilliseconds;

  void _stopTimers() {
    _tick?.cancel();
    _limitSub?.cancel();
    _tick = null;
    _limitSub = null;
  }

  Future<void> _finish() async {
    if (_done || _path == null) return;
    _done = true;
    _stopTimers();
    final dur = await NativeBridge.recStop();
    if (!mounted) return;
    if (dur < 700) {
      try {
        await File(_path!).delete();
      } catch (_) {}
      if (mounted) Navigator.pop(context);
      return;
    }
    Navigator.pop(context, VoiceClip(_path!, dur));
  }

  Future<void> _skip() async {
    if (_done) return;
    _done = true;
    _stopTimers();
    if (_path != null) await NativeBridge.recCancel();
    if (mounted) Navigator.pop(context);
  }

  @override
  void dispose() {
    _stopTimers();
    if (!_done && _path != null) NativeBridge.recCancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final ms = _elapsedMs.clamp(0, kMaxVoiceMs).toInt();
    final left = ((kMaxVoiceMs - ms) / 1000).ceil();
    return PopScope(
      canPop: false, // back button = Skip, so the recorder is always released
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _skip();
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.mic, color: kSosRed, size: 40),
            const SizedBox(height: 8),
            Text('SOS sent. Recording a voice message',
                textAlign: TextAlign.center,
                style: t.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(
              _error ??
                  'Say what happened and where you are. It goes to everyone '
                      'automatically after 10 seconds.',
              textAlign: TextAlign.center,
            ),
            if (_error == null) ...[
              const SizedBox(height: 20),
              Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox(
                    width: 96,
                    height: 96,
                    child: CircularProgressIndicator(
                      value: _start == null ? null : ms / kMaxVoiceMs,
                      strokeWidth: 6,
                      color: kSosRed,
                    ),
                  ),
                  Text('$left',
                      style: t.textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          fontFeatures: const [FontFeature.tabularFigures()])),
                ],
              ),
              const SizedBox(height: 8),
              Text('${durationLabel(ms)} / 0:10',
                  style: t.textTheme.labelMedium),
            ],
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _skip,
                    child: Text(_error == null ? 'Skip' : 'Close'),
                  ),
                ),
                if (_error == null) ...[
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(backgroundColor: kSosRed),
                      onPressed: _start == null ? null : _finish,
                      icon: const Icon(Icons.send_rounded),
                      label: const Text('Send now'),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
