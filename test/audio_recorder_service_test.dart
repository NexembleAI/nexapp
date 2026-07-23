// Unit tests for AudioRecorderService's wrapper logic (#11 tasks 1–2): the
// permission gate, the config actually handed to the plugin, the recorded-file
// -> ReportAudio mapping, and temp-file cleanup. The `record` plugin and
// path_provider are faked at their platform-interface layer — no device, no mic.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:record/record.dart';
import 'package:traccar_client/audio_recorder_service.dart';

/// Fake `record` platform — records what the service asked of it; everything
/// unused throws via noSuchMethod.
class _FakeRecordPlatform extends RecordPlatform with MockPlatformInterfaceMixin {
  bool permission = true;
  RecordConfig? startedConfig;
  String? startedPath;
  String? stopPath;
  int cancelledCount = 0;

  @override
  Future<void> create(String recorderId) async {}

  @override
  Future<bool> hasPermission(String recorderId, {bool request = true}) async =>
      permission;

  @override
  Future<void> start(String recorderId, RecordConfig config,
      {required String path}) async {
    startedConfig = config;
    startedPath = path;
  }

  @override
  Future<String?> stop(String recorderId) async => stopPath;

  @override
  Future<void> cancel(String recorderId) async => cancelledCount++;

  @override
  Future<void> dispose(String recorderId) async {}

  // The plugin wires these on start(); return inert values so the shared
  // semaphore isn't wedged by a noSuchMethod throw.
  @override
  Stream<RecordState> onStateChanged(String recorderId) =>
      const Stream<RecordState>.empty();

  @override
  Future<Amplitude> getAmplitude(String recorderId) async =>
      Amplitude(current: -60, max: -60);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.dir);
  final String dir;
  @override
  Future<String?> getApplicationDocumentsPath() async => dir;
}

void main() {
  late _FakeRecordPlatform rec;
  late Directory tempDir;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    rec = _FakeRecordPlatform();
    RecordPlatform.instance = rec;
    tempDir = await Directory.systemTemp.createTemp('recorder_test_');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('start() returns false when permission is denied — no recording begins',
      () async {
    rec.permission = false;
    final service = AudioRecorderService();
    expect(await service.start(), isFalse);
    expect(rec.startedConfig, isNull);
  });

  test('start() hands the Opus/16k/mono config + a visit_note_*.ogg path',
      () async {
    rec.permission = true;
    final service = AudioRecorderService();
    expect(await service.start(), isTrue);

    expect(rec.startedConfig!.encoder, AudioEncoder.opus); // host is non-iOS
    expect(rec.startedConfig!.bitRate, 16000);
    expect(rec.startedConfig!.numChannels, 1);
    expect(rec.startedPath, startsWith(tempDir.path));
    expect(p.basename(rec.startedPath!), startsWith('visit_note_'));
    expect(rec.startedPath, endsWith('.ogg'));
  });

  test('stop() maps the recorded file to ReportAudio (mime, size, duration)',
      () async {
    rec.permission = true;
    final service = AudioRecorderService();
    await service.start(); // sets the mime from the config

    final out = File(p.join(tempDir.path, 'note.ogg'));
    await out.writeAsBytes(Uint8List(1234));
    rec.stopPath = out.path;

    final audio = await service.stop();
    expect(audio, isNotNull);
    expect(audio!.path, out.path);
    expect(audio.mimeType, 'audio/ogg; codecs=opus');
    expect(audio.sizeBytes, 1234);
    expect(audio.duration, greaterThanOrEqualTo(Duration.zero));
  });

  test('stop() returns null when the plugin yields no path', () async {
    rec.permission = true;
    final service = AudioRecorderService();
    await service.start();
    rec.stopPath = null;
    expect(await service.stop(), isNull);
  });

  test('cancel() cancels the plugin and deletes the temp file', () async {
    rec.permission = true;
    final service = AudioRecorderService();
    await service.start();
    final path = rec.startedPath!;
    await File(path).writeAsBytes(const [1, 2, 3]); // the in-progress file
    expect(File(path).existsSync(), isTrue);

    await service.cancel();
    expect(rec.cancelledCount, 1);
    expect(File(path).existsSync(), isFalse);
  });

  test('codecLabel is Opus on a non-iOS host', () {
    expect(AudioRecorderService().codecLabel, 'Opus');
  });
}
