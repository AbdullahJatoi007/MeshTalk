import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// Photos and voice messages travel as numbered chunks (`blob` packets)
/// and are put back together on arrival.

class MediaKind {
  static const image = 'img';
  static const voice = 'voice';
  static const all = {image, voice};

  static String ext(String kind) => kind == image ? 'jpg' : 'm4a';
}

/// Raw bytes per chunk. Base64 + JSON (+ encryption for private media)
/// keeps each packet under the 16 KB limit.
const int kChunkBytes = 7000;

/// At most 48 chunks (~330 KB) per photo or voice message.
const int kMaxChunks = 48;
const int kMaxMediaBytes = kChunkBytes * kMaxChunks;

/// Voice messages are capped at 10 seconds.
const int kMaxVoiceMs = 10000;

/// Incomplete media older than this is dropped.
const int kAssemblyTimeoutMs = 10 * 60 * 1000;

List<Uint8List> splitChunks(Uint8List data) {
  final out = <Uint8List>[];
  for (var i = 0; i < data.length; i += kChunkBytes) {
    out.add(Uint8List.sublistView(data, i, min(i + kChunkBytes, data.length)));
  }
  return out;
}

/// One photo / voice message being received.
class IncomingMedia {
  IncomingMedia({
    required this.mediaId,
    required this.kind,
    required this.total,
    required this.src,
    required this.firstSeen,
  });

  final String mediaId;
  final String kind;
  final int total;
  final String src;
  final int firstSeen;
  final Map<int, Uint8List> parts = {};

  double get progress => parts.length / total;
  bool get complete => parts.length == total;

  Uint8List assemble() {
    final b = BytesBuilder(copy: false);
    for (var i = 0; i < total; i++) {
      b.add(parts[i]!);
    }
    return b.takeBytes();
  }
}

/// Collects chunks until every piece of a photo / voice message is in.
class MediaAssembler {
  final Map<String, IncomingMedia> _pending = {};

  /// Adds one chunk. Returns the media it belongs to (check `complete`),
  /// or null if the chunk is invalid or doesn't match earlier chunks.
  IncomingMedia? add({
    required String mediaId,
    required String kind,
    required int index,
    required int total,
    required Uint8List bytes,
    required String src,
    required int now,
  }) {
    if (!MediaKind.all.contains(kind)) return null;
    if (total < 1 || total > kMaxChunks) return null;
    if (index < 0 || index >= total) return null;
    if (bytes.isEmpty || bytes.length > kChunkBytes) return null;
    final m = _pending.putIfAbsent(
      mediaId,
      () => IncomingMedia(
          mediaId: mediaId, kind: kind, total: total, src: src, firstSeen: now),
    );
    // A chunk claiming the same id with different shape or sender: ignore it.
    if (m.total != total || m.kind != kind || m.src != src) return null;
    m.parts[index] = bytes;
    return m;
  }

  void remove(String mediaId) => _pending.remove(mediaId);

  /// Drops media that never completed.
  void prune(int now) =>
      _pending.removeWhere((_, m) => now - m.firstSeen > kAssemblyTimeoutMs);

  int get pendingCount => _pending.length;
}

/// Where photos and voice messages are stored on the phone.
class MediaStore {
  static String _dir = '';

  static Future<void> init(String baseDir) async {
    final d = Directory('$baseDir/media');
    await d.create(recursive: true);
    _dir = d.path;
  }

  static String get dir => _dir;

  static String pathFor(String id, String kind) =>
      '$_dir/$id.${MediaKind.ext(kind)}';

  /// A fresh path for a recording in progress.
  static String newRecordingPath() =>
      '$_dir/rec_${DateTime.now().millisecondsSinceEpoch}.m4a';

  static Future<String> write(String id, String kind, Uint8List bytes) async {
    final path = pathFor(id, kind);
    await File(path).writeAsBytes(bytes, flush: true);
    return path;
  }

  static Future<void> clear() async {
    if (_dir.isEmpty) return;
    final d = Directory(_dir);
    if (!await d.exists()) return;
    await for (final f in d.list()) {
      try {
        await f.delete(recursive: true);
      } catch (_) {}
    }
  }
}
