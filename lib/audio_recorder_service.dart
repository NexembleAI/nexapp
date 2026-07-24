import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'models/tracking_models.dart';

/// Wraps the `record` plugin for visit-note capture. Opus/Ogg on Android
/// (~16 kbps mono), AAC-LC/m4a on iOS (~32 kbps mono) — iOS can't mux Opus
/// into Ogg, and per-report audio_mime_type (§4.4) carries the container, so
/// the split is fine downstream.
class AudioRecorderService {
  final AudioRecorder _recorder = AudioRecorder();
  DateTime? _startedAt;
  String? _path;
  String? _mime;

  Stream<Amplitude> amplitudeStream() =>
      _recorder.onAmplitudeChanged(const Duration(milliseconds: 200));

  /// Prompts for mic permission on first call.
  Future<bool> hasPermission() => _recorder.hasPermission();

  /// Friendly codec name for the size caption.
  String get codecLabel => Platform.isIOS ? 'AAC' : 'Opus';

  /// Live size of the in-progress file (for the recording caption).
  Future<int> currentSizeBytes() async {
    final p = _path;
    if (p == null) return 0;
    final f = File(p);
    return await f.exists() ? f.length() : 0;
  }

  static (RecordConfig, String ext, String mime) _configFor() =>
      configFor(isIOS: Platform.isIOS);

  /// Recording config per platform: Opus/Ogg ~16 kbps mono on Android, AAC-LC/
  /// m4a ~32 kbps mono on iOS (iOS can't mux Opus into Ogg). [isIOS] is a
  /// parameter so both branches are deterministically unit-testable.
  @visibleForTesting
  static (RecordConfig, String ext, String mime) configFor(
      {required bool isIOS}) {
    if (isIOS) {
      return (
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 32000,
          sampleRate: 22050, // voice-grade; caps size if bitRate is ignored
          numChannels: 1,
        ),
        'm4a',
        'audio/mp4',
      );
    }
    return (
      const RecordConfig(
        encoder: AudioEncoder.opus,
        bitRate: 16000,
        sampleRate: 16000,
        numChannels: 1,
      ),
      'ogg',
      'audio/ogg; codecs=opus',
    );
  }

  /// Starts recording to an app-private file. Returns false if permission is
  /// missing (caller surfaces it).
  Future<bool> start() async {
    if (!await _recorder.hasPermission()) return false;
    final (config, ext, mime) = _configFor();
    final dir = await getApplicationDocumentsDirectory();
    final path =
        '${dir.path}/visit_note_${DateTime.now().millisecondsSinceEpoch}.$ext';
    await _recorder.start(config, path: path);
    _path = path;
    _mime = mime;
    _startedAt = DateTime.now();
    return true;
  }

  /// Stops and returns the recorded audio (null on failure).
  Future<ReportAudio?> stop() async {
    final path = await _recorder.stop();
    if (path == null) return null;
    final file = File(path);
    final size = await file.exists() ? await file.length() : 0;
    // Wall-clock duration (drifts high — it includes encoder start/stop
    // latency). The capture screen refines this to the true encoded length
    // using the review player it builds anyway (VisitCaptureScreen._initPlayer),
    // so stop() stays fast and can't hang on a stuck decode of a locked file.
    final duration = _startedAt == null
        ? Duration.zero
        : DateTime.now().difference(_startedAt!);
    final audio = ReportAudio(
      path: path,
      mimeType: _mime ?? 'application/octet-stream',
      duration: duration,
      sizeBytes: size,
    );
    if (kDebugMode) {
      debugPrint('[audio] ${audio.mimeType} · ${audio.sizeBytes} B · '
          '${audio.duration.inSeconds}s · $path');
    }
    return audio;
  }

  /// Discards the in-progress recording and deletes the temp file.
  Future<void> cancel() async {
    await _recorder.cancel();
    await deleteFile();
  }

  /// Deletes the app-private temp file (call after submit or discard).
  Future<void> deleteFile() async {
    final p = _path;
    if (p == null) return;
    try {
      final f = File(p);
      if (await f.exists()) await f.delete();
    } catch (_) {}
    _path = null;
  }

  void dispose() => _recorder.dispose();
}
