// The uploader's drain behaviour for #12: outcome→state transitions (success /
// terminal / retryable / unauthenticated), the serial one-at-a-time guard, the
// progress-throttle, and eventual success across a real retry+wake. Drives the
// singleton with a fake `upload` hook + the connectivity seam over an isolated
// FFI queue (see QueueHarness).
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:traccar_client/connectivity_service.dart';
import 'package:traccar_client/models/tracking_models.dart';
import 'package:traccar_client/upload_queue.dart';
import 'package:traccar_client/upload_uploader.dart';

import 'support/queue_harness.dart';

void main() {
  final h = QueueHarness();
  final q = UploadQueue.instance;
  final uploader = UploadUploader.instance;

  setUp(() async {
    await h.setUp();
    await h.initQueue();
    ConnectivityService.instance.setOnlineForTest(true);
    uploader.resetForTest(); // clean flags + listeners between cases
    uploader.upload = null;
    uploader.onUploaded = null;
  });

  tearDown(() async {
    uploader.resetForTest();
    await h.tearDown();
  });

  Future<void> enqueue(String id) => q.enqueue(
        ReportDraft(
          customerId: 'c',
          leadIds: const [],
          notes: 'n',
          idempotencyKey: id,
        ),
        customerName: 'Acme',
      );

  QueuedReport itemOf(String id) =>
      q.items.firstWhere((i) => i.idempotencyKey == id);

  Future<void> pumpUntil(
    bool Function() cond, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!cond()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('timed out; items='
            '${q.items.map((i) => '${i.idempotencyKey}:${i.status.name}:a${i.attemptCount}').toList()}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  test('success → item removed, onUploaded fired once with the item', () async {
    QueuedReport? uploaded;
    var calls = 0;
    uploader.onUploaded = (i) {
      uploaded = i;
      calls++;
    };
    uploader.upload = (item, {onProgress}) async => UploadOutcome.success;

    uploader.start();
    await enqueue('k1');
    await pumpUntil(() => q.items.isEmpty);

    expect(uploaded?.idempotencyKey, 'k1');
    expect(calls, 1);
  });

  test('terminal → failed, onUploaded NOT fired', () async {
    var uploadedCalled = false;
    uploader.onUploaded = (_) => uploadedCalled = true;
    uploader.upload = (item, {onProgress}) async => UploadOutcome.terminal;

    uploader.start();
    await enqueue('k1');
    await pumpUntil(() => itemOf('k1').status == QueueStatus.failed);

    expect(uploadedCalled, isFalse);
  });

  test('retryable (under cap) → queued, attempt bumped, backed off', () async {
    uploader.upload = (item, {onProgress}) async => UploadOutcome.retryable;

    uploader.start();
    await enqueue('k1');
    await pumpUntil(() => itemOf('k1').attemptCount == 1);
    uploader.resetForTest(); // freeze — cancel the pending wake before it retries

    final item = itemOf('k1');
    expect(item.status, QueueStatus.queued);
    expect(item.attemptCount, 1);
    expect(item.nextAttemptAt!.isAfter(DateTime.now()), isTrue); // backing off
  });

  test('retryable AT the cap → failed (no infinite loop)', () async {
    uploader.upload = (item, {onProgress}) async => UploadOutcome.retryable;

    await enqueue('k1');
    for (var i = 0; i < UploadQueue.maxAttempts - 1; i++) {
      await q.bumpAttempt('k1'); // pre-load to one below the cap
    }
    uploader.start();
    await pumpUntil(() => itemOf('k1').status == QueueStatus.failed);

    expect(itemOf('k1').attemptCount, UploadQueue.maxAttempts);
  });

  test('a thrown hook is treated as retryable (drain not wedged)', () async {
    uploader.upload = (item, {onProgress}) async => throw Exception('boom');

    uploader.start();
    await enqueue('k1');
    await pumpUntil(() => itemOf('k1').attemptCount == 1);
    uploader.resetForTest();

    expect(itemOf('k1').status, QueueStatus.queued);
    expect(itemOf('k1').nextAttemptAt, isNotNull); // backed off, not failed
  });

  test('unauthenticated → drain pauses (no attempt spent); resume() re-drains',
      () async {
    var calls = 0;
    uploader.upload = (item, {onProgress}) async {
      calls++;
      return calls == 1 ? UploadOutcome.unauthenticated : UploadOutcome.success;
    };

    uploader.start();
    await enqueue('k1');
    await pumpUntil(() => calls == 1);

    // Paused: the item is back to queued, its attempt budget untouched, and no
    // further drain happens while paused.
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(itemOf('k1').status, QueueStatus.queued);
    expect(itemOf('k1').attemptCount, 0);
    expect(calls, 1);

    uploader.resume();
    await pumpUntil(() => q.items.isEmpty);
    expect(calls, 2);
  });

  test('serial: only one upload in flight at a time', () async {
    final gate = Completer<UploadOutcome>();
    var calls = 0;
    uploader.upload = (item, {onProgress}) {
      calls++;
      return calls == 1 ? gate.future : Future.value(UploadOutcome.success);
    };

    await enqueue('k1');
    await Future<void>.delayed(const Duration(milliseconds: 5)); // distinct createdAt
    await enqueue('k2');
    uploader.start();

    // First upload is in flight (blocked on the gate); the second must wait.
    await pumpUntil(() => calls == 1 && itemOf('k1').status == QueueStatus.uploading);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(calls, 1, reason: 'second upload must not start while the first is in flight');

    gate.complete(UploadOutcome.success);
    await pumpUntil(() => q.items.isEmpty);
    expect(calls, 2); // both drained, one after the other
  });

  test('progress ticks are throttled to whole-percent buckets', () async {
    // 8 fine-grained fractions collapse to 5 distinct whole-percent updates.
    uploader.upload = (item, {onProgress}) async {
      for (final f in [0.0, 0.004, 0.009, 0.01, 0.5, 0.5, 0.999, 1.0]) {
        onProgress?.call(f);
      }
      return UploadOutcome.success;
    };

    var progressTicks = 0;
    void onProgress() => progressTicks++;
    q.progressChanges.addListener(onProgress);
    addTearDown(() => q.progressChanges.removeListener(onProgress));

    uploader.start();
    await enqueue('k1');
    await pumpUntil(() => q.items.isEmpty);

    expect(progressTicks, 5); // pcts 0,1,50,99,100 — duplicates within a bucket dropped
  });

  test('eventual success: retry then succeed on the wake', () async {
    var calls = 0;
    uploader.upload = (item, {onProgress}) async {
      calls++;
      return calls == 1 ? UploadOutcome.retryable : UploadOutcome.success;
    };

    uploader.start();
    await enqueue('k1');
    // First attempt backs off (~0.5–1s), the wake fires, the second succeeds.
    await pumpUntil(() => q.items.isEmpty, timeout: const Duration(seconds: 15));
    expect(calls, 2);
  });
}
