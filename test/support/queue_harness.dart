import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:traccar_client/upload_queue.dart';

/// Shared setup for the durable-upload-queue tests. Routes sqflite through the
/// in-process FFI factory (so the DB opens on the host VM, no device) and gives
/// each test an isolated temp dir for its DB + audio, so cases don't leak into
/// one another. Test-only — nothing here is compiled into the app.
class QueueHarness {
  late Directory dir;

  /// Call in setUp: init FFI once (idempotent) and mint a fresh temp dir.
  Future<void> setUp() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    dir = await Directory.systemTemp.createTemp('queue_test_');
  }

  /// (Re-)initialise the singleton queue against this harness's temp dir. Call
  /// it again after [UploadQueue.closeForTest] to simulate an app restart —
  /// same dir → the persisted rows re-hydrate.
  Future<void> initQueue() => UploadQueue.instance.init(
        databasesDir: dir.path,
        documentsDir: dir.path,
      );

  /// Call in tearDown: close the DB and remove the temp dir.
  Future<void> tearDown() async {
    await UploadQueue.instance.closeForTest();
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}
