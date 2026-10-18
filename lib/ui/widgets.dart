import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../mesh/media.dart';
import '../mesh/mesh_service.dart';
import '../platform/native_bridge.dart';
import '../platform/permissions.dart';
import 'theme.dart';

class Avatar extends StatelessWidget {
  const Avatar(
      {super.key, required this.id, required this.name, this.radius = 20});

  final String id;
  final String name;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    return CircleAvatar(
      radius: radius,
      backgroundColor: colorForId(id, b),
      child: Text(
        name.isEmpty ? '?' : name.characters.first.toUpperCase(),
        style: TextStyle(color: Colors.white, fontSize: radius * 0.8),
      ),
    );
  }
}

String durationLabel(int ms) {
  final s = (ms / 1000).round();
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

void showError(BuildContext context, Object e) {
  ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(e is StateError ? e.message : '$e')));
}

// ── composer ────────────────────────────────────────────────────────────

/// Text field + photo button + mic (voice message, 10 s max) + send.
class Composer extends StatefulWidget {
  const Composer({
    super.key,
    required this.onSend,
    this.onSendImage,
    this.onSendVoice,
    this.enabled = true,
    this.hint,
  });

  final Future<void> Function(String text) onSend;
  final Future<void> Function(Uint8List jpeg)? onSendImage;
  final Future<void> Function(String path, int durMs)? onSendVoice;
  final bool enabled;
  final String? hint;

  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> {
  final _ctrl = TextEditingController();
  bool _busy = false;

  // recording state
  bool _recording = false;
  bool _stopping = false;
  String? _recPath;
  DateTime? _recStart;
  Timer? _tick;
  StreamSubscription<void>? _limitSub;

  @override
  void dispose() {
    _tick?.cancel();
    _limitSub?.cancel();
    if (_recording) NativeBridge.recCancel();
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _guard(Future<void> Function() job) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await job();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendText() async {
    final t = _ctrl.text.trim();
    if (t.isEmpty) return;
    await _guard(() async {
      await widget.onSend(t);
      _ctrl.clear();
    });
  }

  // ── photo ──

  Future<void> _pickImage() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take a photo'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from gallery'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;
    // Shrunk and compressed on the phone (~50–120 KB) before it goes out.
    final file = await ImagePicker().pickImage(
      source: source,
      maxWidth: 800,
      maxHeight: 800,
      imageQuality: 55,
      requestFullMetadata: false,
    );
    if (file == null) return;
    final bytes = await file.readAsBytes();
    await _guard(() => widget.onSendImage!(bytes));
  }

  // ── voice ──

  Future<void> _startRecording() async {
    if (!await requestMicrophone()) {
      if (mounted)
        showError(context, StateError('Microphone permission is needed'));
      return;
    }
    final path = MediaStore.newRecordingPath();
    final ok = await NativeBridge.recStart(path, maxMs: kMaxVoiceMs + 500);
    if (!ok) {
      if (mounted) showError(context, StateError("Couldn't start recording"));
      return;
    }
    setState(() {
      _recording = true;
      _recPath = path;
      _recStart = DateTime.now();
    });
    _limitSub = NativeBridge.onRecordLimit.listen((_) => _stopAndSend());
    _tick = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!mounted) return;
      if (_elapsedMs >= kMaxVoiceMs) {
        _stopAndSend(); // 10 seconds: send automatically
      } else {
        setState(() {});
      }
    });
  }

  int get _elapsedMs => _recStart == null
      ? 0
      : DateTime.now().difference(_recStart!).inMilliseconds;

  void _endRecordingUi() {
    _tick?.cancel();
    _limitSub?.cancel();
    _tick = null;
    _limitSub = null;
    if (mounted) setState(() => _recording = false);
  }

  Future<void> _stopAndSend() async {
    if (!_recording || _stopping) return;
    _stopping = true;
    final path = _recPath;
    final dur = await NativeBridge.recStop();
    _endRecordingUi();
    _stopping = false;
    if (path == null) return;
    if (dur < 700) {
      try {
        await File(path).delete();
      } catch (_) {}
      if (mounted)
        showError(
            context, StateError('Hold on a bit longer: that was too short'));
      return;
    }
    await _guard(() => widget.onSendVoice!(path, dur));
  }

  Future<void> _cancelRecording() async {
    if (!_recording) return;
    await NativeBridge.recCancel();
    _endRecordingUi();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 6, 8, 10),
        child: _recording ? _recordingBar(cs) : _inputBar(),
      ),
    );
  }

  Widget _inputBar() {
    final canMedia = widget.enabled && !_busy;
    return Row(
      children: [
        if (widget.onSendImage != null)
          IconButton(
            tooltip: 'Send a photo',
            onPressed: canMedia ? _pickImage : null,
            icon: const Icon(Icons.add_photo_alternate_outlined),
          )
        else
          const SizedBox(width: 8),
        Expanded(
          child: TextField(
            controller: _ctrl,
            enabled: widget.enabled,
            minLines: 1,
            maxLines: 5,
            maxLength: MeshService.maxTextLength,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              hintText: widget.hint ?? 'Message',
              counterText: '',
            ),
            onSubmitted: (_) => _sendText(),
          ),
        ),
        const SizedBox(width: 6),
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _ctrl,
          builder: (context, value, _) {
            final empty = value.text.trim().isEmpty;
            if (empty && widget.onSendVoice != null) {
              return IconButton.filled(
                tooltip: 'Record a voice message (10 s max)',
                onPressed: canMedia ? _startRecording : null,
                icon: const Icon(Icons.mic_none_rounded),
              );
            }
            return IconButton.filled(
              onPressed: widget.enabled && !_busy && !empty ? _sendText : null,
              icon: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.send_rounded),
            );
          },
        ),
      ],
    );
  }

  Widget _recordingBar(ColorScheme cs) {
    final ms = _elapsedMs.clamp(0, kMaxVoiceMs).toInt();
    return Row(
      children: [
        IconButton(
          tooltip: 'Cancel',
          onPressed: _cancelRecording,
          icon: Icon(Icons.delete_outline, color: cs.error),
        ),
        Expanded(
          child: Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(24),
            ),
            child: Row(
              children: [
                const Icon(Icons.fiber_manual_record, color: kSosRed, size: 14),
                const SizedBox(width: 8),
                Text('${durationLabel(ms)} / 0:10',
                    style: const TextStyle(
                        fontFeatures: [FontFeature.tabularFigures()])),
                const SizedBox(width: 12),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                        value: ms / kMaxVoiceMs, minHeight: 6),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 6),
        IconButton.filled(
          tooltip: 'Send',
          onPressed: _stopAndSend,
          icon: const Icon(Icons.send_rounded),
        ),
      ],
    );
  }
}

// ── message bubbles ─────────────────────────────────────────────────────

class MessageBubble extends StatelessWidget {
  const MessageBubble({super.key, required this.m, this.showSender = true});

  final ChatMessage m;
  final bool showSender;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;

    if (m.kind == MessageKind.sos) return _SosCard(m: m);

    final bg = m.mine ? cs.primaryContainer : cs.surfaceContainerHighest;
    final fg = m.mine ? cs.onPrimaryContainer : cs.onSurface;
    final meta = <String>[
      timeLabel(m.ts),
      if (!m.mine)
        m.viaBitchat ? 'bitchat' : '${m.hops} hop${m.hops == 1 ? '' : 's'}',
    ].join(' · ');

    final Widget content;
    if (m.media == MediaKind.image) {
      content = _ImageContent(m: m, fg: fg);
    } else if (m.media == MediaKind.voice) {
      content = _VoiceContent(m: m, fg: fg);
    } else {
      final link = mapLinkIn(m.text);
      content = link == null
          ? Text(m.text, style: t.textTheme.bodyLarge?.copyWith(color: fg))
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(m.text, style: t.textTheme.bodyLarge?.copyWith(color: fg)),
                const SizedBox(height: 4),
                OutlinedButton.icon(
                  onPressed: () =>
                      openLocation(context, link.$1, link.$2, m.fromName),
                  icon: const Icon(Icons.place_outlined, size: 18),
                  label: const Text('Open location'),
                ),
              ],
            );
    }

    return Align(
      alignment: m.mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.78),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
          padding: m.media == MediaKind.image
              ? const EdgeInsets.fromLTRB(4, 4, 4, 6)
              : const EdgeInsets.fromLTRB(12, 8, 12, 6),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(18),
              topRight: const Radius.circular(18),
              bottomLeft: Radius.circular(m.mine ? 18 : 4),
              bottomRight: Radius.circular(m.mine ? 4 : 18),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showSender && !m.mine)
                Padding(
                  padding: EdgeInsets.fromLTRB(
                      m.media == MediaKind.image ? 8 : 0, 2, 0, 2),
                  child: Text(m.fromName,
                      style: t.textTheme.labelMedium?.copyWith(
                          color: colorForId(m.fromId, t.brightness),
                          fontWeight: FontWeight.w600)),
                ),
              content,
              const SizedBox(height: 2),
              Padding(
                padding:
                    EdgeInsets.only(left: m.media == MediaKind.image ? 8 : 0),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(meta,
                        style: t.textTheme.labelSmall
                            ?.copyWith(color: fg.withValues(alpha: 0.6))),
                    if (m.mine && m.kind == MessageKind.dm) ...[
                      const SizedBox(width: 4),
                      Icon(m.delivered ? Icons.done_all : Icons.done,
                          size: 14, color: fg.withValues(alpha: 0.7)),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// True when a half-received photo / voice message won't complete any more.
bool _stalled(ChatMessage m) =>
    m.path == null &&
    !m.mine &&
    DateTime.now().millisecondsSinceEpoch - m.ts > kAssemblyTimeoutMs;

class _ImageContent extends StatelessWidget {
  const _ImageContent({required this.m, required this.fg});

  final ChatMessage m;
  final Color fg;

  @override
  Widget build(BuildContext context) {
    const w = 230.0;
    final path = m.path;
    if (path != null) {
      return GestureDetector(
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) =>
                ImageViewer(path: path, title: m.mine ? 'You' : m.fromName))),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Image.file(
            File(path),
            width: w,
            fit: BoxFit.cover,
            cacheWidth: 690,
            errorBuilder: (_, __, ___) =>
                _placeholder(w, Icons.broken_image_outlined, 'Photo missing'),
          ),
        ),
      );
    }
    if (_stalled(m)) {
      return _placeholder(
          w, Icons.image_not_supported_outlined, 'Photo not fully received');
    }
    return SizedBox(
      width: w,
      height: 150,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 36,
              height: 36,
              child:
                  CircularProgressIndicator(value: m.progress, strokeWidth: 3),
            ),
            const SizedBox(height: 10),
            Text('Receiving photo ${(m.progress * 100).round()}%',
                style: TextStyle(color: fg.withValues(alpha: 0.8))),
          ],
        ),
      ),
    );
  }

  Widget _placeholder(double w, IconData icon, String label) => SizedBox(
        width: w,
        height: 110,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: fg.withValues(alpha: 0.6)),
              const SizedBox(height: 6),
              Text(label, style: TextStyle(color: fg.withValues(alpha: 0.7))),
            ],
          ),
        ),
      );
}

class _VoiceContent extends StatelessWidget {
  const _VoiceContent({required this.m, required this.fg});

  final ChatMessage m;
  final Color fg;

  @override
  Widget build(BuildContext context) {
    final path = m.path;
    if (path == null) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_stalled(m) ? Icons.mic_off_outlined : Icons.downloading_rounded,
              color: fg.withValues(alpha: 0.7)),
          const SizedBox(width: 8),
          Text(
            _stalled(m)
                ? 'Voice message not fully received'
                : 'Receiving voice message ${(m.progress * 100).round()}%',
            style: TextStyle(color: fg.withValues(alpha: 0.8)),
          ),
        ],
      );
    }
    return ValueListenableBuilder<String?>(
      valueListenable: NativeBridge.playing,
      builder: (context, playing, _) {
        final isPlaying = playing == path;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              visualDensity: VisualDensity.compact,
              onPressed: () async {
                if (isPlaying) {
                  await NativeBridge.stopPlay();
                } else if (!await NativeBridge.play(path) && context.mounted) {
                  showError(
                      context, StateError("Couldn't play this voice message"));
                }
              },
              icon: Icon(
                  isPlaying ? Icons.stop_rounded : Icons.play_arrow_rounded,
                  color: fg,
                  size: 30),
            ),
            Icon(Icons.graphic_eq_rounded,
                color: fg.withValues(alpha: isPlaying ? 1 : 0.6)),
            const SizedBox(width: 8),
            Text(m.durMs > 0 ? durationLabel(m.durMs) : 'Voice',
                style: TextStyle(color: fg)),
            const SizedBox(width: 4),
          ],
        );
      },
    );
  }
}

/// Full-screen photo with pinch-to-zoom.
class ImageViewer extends StatelessWidget {
  const ImageViewer({super.key, required this.path, required this.title});

  final String path;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(title),
      ),
      body: Center(
        child: InteractiveViewer(
          maxScale: 5,
          child: Image.file(File(path)),
        ),
      ),
    );
  }
}

/// Opens a position in the phone's maps app, or says why it couldn't.
Future<void> openLocation(
    BuildContext context, double lat, double lon, String who) async {
  final ok = await NativeBridge.openMap(lat, lon, label: 'SOS: $who');
  if (!ok && context.mounted) {
    showError(
        context,
        StateError('No maps app found. Location: '
            '${lat.toStringAsFixed(5)}, ${lon.toStringAsFixed(5)}'));
  }
}

/// A "maps.google.com/?q=lat,lon" link in a message (e.g. an SOS location
/// mirrored from or to bitchat), as (lat, lon).
(double, double)? mapLinkIn(String text) {
  final m = RegExp(
          r'maps\.google\.com/\?q=(-?\d{1,2}(?:\.\d+)?),(-?\d{1,3}(?:\.\d+)?)')
      .firstMatch(text);
  if (m == null) return null;
  final lat = double.tryParse(m.group(1)!), lon = double.tryParse(m.group(2)!);
  if (lat == null || lon == null || lat.abs() > 90 || lon.abs() > 180)
    return null;
  return (lat, lon);
}

/// "just now", "4 min ago", "2 h ago".
String agoLabel(int ts) {
  final s = (DateTime.now().millisecondsSinceEpoch - ts) ~/ 1000;
  if (s < 60) return 'just now';
  if (s < 3600) return '${s ~/ 60} min ago';
  if (s < 86400) return '${s ~/ 3600} h ago';
  return timeLabel(ts);
}

/// "±12 m · updated 2 min ago"
String locationDetail(ChatMessage m) => [
      if (m.acc != null && m.acc! > 0) '±${m.acc!.round()} m',
      if (m.locTs != null) 'updated ${agoLabel(m.locTs!)}',
    ].join(' · ');

class _SosCard extends StatelessWidget {
  const _SosCard({required this.m});

  final ChatMessage m;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final isVoice = m.media == MediaKind.voice;
    final title = isVoice
        ? (m.mine ? 'Your SOS voice message' : 'SOS voice from ${m.fromName}')
        : (m.mine ? 'You sent an SOS' : 'SOS from ${m.fromName}');
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: kSosRed.withValues(alpha: 0.12),
        border: Border.all(color: kSosRed, width: 1.5),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(isVoice ? Icons.record_voice_over : Icons.sos,
              color: kSosRed, size: 30),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: t.textTheme.titleSmall?.copyWith(
                        color: kSosRed, fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                if (isVoice)
                  _VoiceContent(m: m, fg: cs.onSurface)
                else
                  Text(m.text, style: t.textTheme.bodyLarge),
                if (!isVoice && m.hasLocation) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: kSosRed,
                          foregroundColor: Colors.white,
                          visualDensity: VisualDensity.compact,
                        ),
                        onPressed: () => openLocation(context, m.lat!, m.lon!,
                            m.mine ? 'You' : m.fromName),
                        icon: const Icon(Icons.place, size: 18),
                        label: const Text('Open location'),
                      ),
                      Text(locationDetail(m), style: t.textTheme.labelSmall),
                    ],
                  ),
                ] else if (!isVoice && !m.mine) ...[
                  const SizedBox(height: 4),
                  Text('No location shared yet',
                      style: t.textTheme.labelSmall
                          ?.copyWith(fontStyle: FontStyle.italic)),
                ],
                const SizedBox(height: 4),
                Text(
                  [
                    timeLabel(m.ts),
                    if (!m.mine) '${m.hops} hop${m.hops == 1 ? '' : 's'} away'
                  ].join(' · '),
                  style: t.textTheme.labelSmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
