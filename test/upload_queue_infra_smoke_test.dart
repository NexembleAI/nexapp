// Smoke test that VALIDATES the #12 test infrastructure end-to-end — the FFI
// sqflite factory, the isolated temp-dir routing (UploadQueue.init overrides),
// enqueue → persist → re-hydrate across a simulated restart, and the
// ConnectivityService test seam. Not the queue's behavioural suite (that comes
// next); this just proves the scaffolding works and stays test-only.
import 'package:flutter_test/flutter_test.dart';
import 'package:traccar_client/connectivity_service.dart';
import 'package:traccar_client/models/tracking_models.dart';
import 'package:traccar_client/upload_queue.dart';

import 'support/queue_harness.dart';

void main() {
  final h = QueueHarness();
  setUp(h.setUp);
  tearDown(h.tearDown);

  test('queue opens under the FFI factory and starts empty', () async {
    await h.initQueue();
    expect(UploadQueue.instance.items, isEmpty);
  });

  test('enqueue persists and re-hydrates across a restart', () async {
    await h.initQueue();
    await UploadQueue.instance.enqueue(
      const ReportDraft(
        customerId: 'c1',
        leadIds: [],
        notes: 'hello',
        idempotencyKey: 'k1',
      ),
      customerName: 'Acme',
    );
    expect(UploadQueue.instance.items, hasLength(1));

    // Simulate an app-kill/restart: drop the in-memory cache + connection, then
    // re-init against the same dir → the row comes back from disk.
    await UploadQueue.instance.closeForTest();
    await h.initQueue();
    expect(UploadQueue.instance.items, hasLength(1));
    expect(UploadQueue.instance.items.single.customerName, 'Acme');
    expect(UploadQueue.instance.items.single.status, QueueStatus.queued);
  });

  test('connectivity seam toggles isOnline', () {
    ConnectivityService.instance.setOnlineForTest(false);
    expect(ConnectivityService.instance.isOnline, isFalse);
    ConnectivityService.instance.setOnlineForTest(true);
    expect(ConnectivityService.instance.isOnline, isTrue);
  });
}
