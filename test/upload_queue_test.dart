// The durability heart of #12 (P2.4): the offline upload queue's persistence,
// state machine, scheduling windows, crash recovery, orphan reconciliation, and
// schema migration. Runs on the host VM via the FFI factory (see QueueHarness);
// each test gets an isolated temp dir.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:traccar_client/models/tracking_models.dart';
import 'package:traccar_client/upload_queue.dart';

import 'support/queue_harness.dart';

void main() {
  final h = QueueHarness();
  final q = UploadQueue.instance;

  setUp(h.setUp);
  tearDown(h.tearDown);

  ReportDraft draft({
    String id = 'k1',
    String customerId = 'cust-1',
    List<String> leadIds = const ['10', '11'],
    String notes = 'met the buyer',
    ReportAudio? audio,
    ReportPosition? position,
  }) =>
      ReportDraft(
        customerId: customerId,
        leadIds: leadIds,
        notes: notes,
        audio: audio,
        position: position,
        idempotencyKey: id,
      );

  // A real on-disk source file so enqueue's copy-into-queue-dir succeeds. Named
  // so it survives _reconcileOrphans (not a queue_audio file, not visit_note_*).
  Future<ReportAudio> makeAudio({int bytes = 2048}) async {
    final f = File(p.join(h.dir.path, 'source_audio.bin'));
    await f.writeAsBytes(List<int>.filled(bytes, 7));
    return ReportAudio(
      path: f.path,
      mimeType: 'audio/wav',
      duration: const Duration(seconds: 3),
      sizeBytes: bytes,
    );
  }

  group('enqueue & persistence', () {
    test('persists a queued row with its fields intact', () async {
      await h.initQueue();
      await q.enqueue(
        draft(
          position: const ReportPosition(
              latitude: 12.97, longitude: 77.59, accuracyMeters: 8),
        ),
        customerName: 'Acme',
      );

      final item = q.items.single;
      expect(item.idempotencyKey, 'k1');
      expect(item.customerName, 'Acme');
      expect(item.customerId, 'cust-1');
      expect(item.leadIds, ['10', '11']);
      expect(item.notes, 'met the buyer');
      expect(item.latitude, 12.97);
      expect(item.longitude, 77.59);
      expect(item.accuracyMeters, 8);
      expect(item.status, QueueStatus.queued);
      expect(item.attemptCount, 0);
      expect(item.progress, 0);
      expect(item.audioPath, isNull);
    });

    test('with audio: copies the file into the queue dir + sets metadata',
        () async {
      await h.initQueue();
      await q.enqueue(draft(audio: await makeAudio(bytes: 4096)),
          customerName: 'Acme');

      final item = q.items.single;
      expect(item.audioPath, isNotNull);
      expect(item.audioMime, 'audio/wav');
      expect(item.audioDurationMs, 3000);
      expect(item.audioSizeBytes, 4096);
      // The persisted path is a bare filename resolved against the queue dir…
      expect(p.dirname(item.audioPath!), '.');
      final abs = q.absoluteAudioPath(item)!;
      expect(p.dirname(abs), p.join(h.dir.path, 'queue_audio'));
      expect(File(abs).existsSync(), isTrue);
      expect(await File(abs).length(), 4096);
    });

    test('items are newest-first', () async {
      await h.initQueue();
      await q.enqueue(draft(id: 'first'), customerName: 'A');
      await q.enqueue(draft(id: 'second'), customerName: 'B');
      expect(q.items.map((i) => i.idempotencyKey), ['second', 'first']);
    });

    test('idempotent on the key — a double-enqueue collapses to one row',
        () async {
      await h.initQueue();
      await q.enqueue(draft(id: 'dup'), customerName: 'A');
      await q.enqueue(draft(id: 'dup'), customerName: 'A-again');
      expect(q.items, hasLength(1));
      expect(q.items.single.customerName, 'A-again');
      // Prove it's one row in SQLite too, not just in memory.
      await q.closeForTest();
      await h.initQueue();
      expect(q.items, hasLength(1));
    });
  });

  group('state transitions', () {
    test('markUploading → uploading, progress reset to 0', () async {
      await h.initQueue();
      await q.enqueue(draft(), customerName: 'A');
      q.setProgress('k1', 0.5);
      await q.markUploading('k1');
      expect(q.items.single.status, QueueStatus.uploading);
      expect(q.items.single.progress, 0);
    });

    test('markUploaded removes the row AND deletes the audio file', () async {
      await h.initQueue();
      await q.enqueue(draft(audio: await makeAudio()), customerName: 'A');
      final abs = q.absoluteAudioPath(q.items.single)!;
      expect(File(abs).existsSync(), isTrue);

      final removed = await q.markUploaded('k1');
      expect(removed, isNotNull);
      expect(removed!.idempotencyKey, 'k1');
      expect(q.items, isEmpty);
      expect(File(abs).existsSync(), isFalse);
    });

    test('markFailed → failed, stays in the queue', () async {
      await h.initQueue();
      await q.enqueue(draft(), customerName: 'A');
      await q.markFailed('k1');
      expect(q.items.single.status, QueueStatus.failed);
    });

    test('markQueued → queued, progress 0', () async {
      await h.initQueue();
      await q.enqueue(draft(), customerName: 'A');
      await q.markUploading('k1');
      await q.markQueued('k1');
      expect(q.items.single.status, QueueStatus.queued);
      expect(q.items.single.progress, 0);
    });

    test('markRetry requeues with a persisted next_attempt_at', () async {
      await h.initQueue();
      await q.enqueue(draft(), customerName: 'A');
      await q.markUploading('k1');
      final due = DateTime.now().add(const Duration(minutes: 5));
      await q.markRetry('k1', due);
      expect(q.items.single.status, QueueStatus.queued);
      expect(q.items.single.nextAttemptAt!.millisecondsSinceEpoch,
          due.millisecondsSinceEpoch);
      // survives a restart
      await q.closeForTest();
      await h.initQueue();
      expect(q.items.single.nextAttemptAt!.millisecondsSinceEpoch,
          due.millisecondsSinceEpoch);
    });

    test('bumpAttempt increments and returns the new count', () async {
      await h.initQueue();
      await q.enqueue(draft(), customerName: 'A');
      expect(await q.bumpAttempt('k1'), 1);
      expect(await q.bumpAttempt('k1'), 2);
      expect(q.items.single.attemptCount, 2);
    });

    test('retryFailed resets the attempt budget and clears the backoff',
        () async {
      await h.initQueue();
      await q.enqueue(draft(), customerName: 'A');
      await q.bumpAttempt('k1');
      await q.bumpAttempt('k1');
      await q.markRetry('k1', DateTime.now().add(const Duration(minutes: 5)));
      await q.markFailed('k1');

      await q.retryFailed('k1');
      final item = q.items.single;
      expect(item.status, QueueStatus.queued);
      expect(item.attemptCount, 0);
      expect(item.nextAttemptAt, isNull);
    });
  });

  group('scheduling windows', () {
    test('nextPending: oldest due item; skips future / uploading / failed',
        () async {
      await h.initQueue();
      await q.enqueue(draft(id: 'old'), customerName: 'A');
      await Future<void>.delayed(const Duration(milliseconds: 5)); // distinct createdAt
      await q.enqueue(draft(id: 'new'), customerName: 'B');

      expect(q.nextPending!.idempotencyKey, 'old'); // FIFO

      // Back the oldest off into the future → the newer one is next.
      await q.markRetry('old', DateTime.now().add(const Duration(hours: 1)));
      expect(q.nextPending!.idempotencyKey, 'new');

      // Take the newer one in-flight → nothing due (old is future, new uploading).
      await q.markUploading('new');
      expect(q.nextPending, isNull);
    });

    test('durationUntilNextDue: soonest backing-off item; null when none',
        () async {
      await h.initQueue();
      await q.enqueue(draft(), customerName: 'A');
      expect(q.durationUntilNextDue, isNull); // due now, not backing off

      await q.markRetry('k1', DateTime.now().add(const Duration(minutes: 10)));
      final d = q.durationUntilNextDue!;
      expect(d.inSeconds, greaterThan(540)); // ~10 min, minus test elapsed
      expect(d.inSeconds, lessThanOrEqualTo(600));

      await q.markUploaded('k1');
      expect(q.durationUntilNextDue, isNull);
    });
  });

  group('notifier split', () {
    test('setProgress bumps progressChanges, not changes', () async {
      await h.initQueue();
      await q.enqueue(draft(), customerName: 'A');

      var changes = 0, progress = 0;
      void onChanges() => changes++;
      void onProgress() => progress++;
      q.changes.addListener(onChanges);
      q.progressChanges.addListener(onProgress);
      addTearDown(() {
        q.changes.removeListener(onChanges);
        q.progressChanges.removeListener(onProgress);
      });

      q.setProgress('k1', 0.4);
      expect(progress, 1);
      expect(changes, 0);

      await q.markFailed('k1'); // a real transition DOES bump changes
      expect(changes, 1);
    });
  });

  group('durability & crash recovery', () {
    test('re-hydrates across a restart (fields + audio file)', () async {
      await h.initQueue();
      await q.enqueue(
        draft(
          audio: await makeAudio(),
          position: const ReportPosition(
              latitude: 1, longitude: 2, accuracyMeters: 3),
        ),
        customerName: 'Acme',
      );

      await q.closeForTest();
      await h.initQueue();

      final item = q.items.single;
      expect(item.customerName, 'Acme');
      expect(item.leadIds, ['10', '11']);
      expect(item.latitude, 1);
      expect(item.status, QueueStatus.queued);
      expect(File(q.absoluteAudioPath(item)!).existsSync(), isTrue);
    });

    test('an interrupted (uploading) item is requeued on restart, attempt counted',
        () async {
      await h.initQueue();
      await q.enqueue(draft(), customerName: 'A');
      await q.markUploading('k1'); // die mid-POST

      await q.closeForTest();
      await h.initQueue();

      final item = q.items.single;
      expect(item.status, QueueStatus.queued);
      expect(item.attemptCount, 1); // the interrupted attempt is counted
    });

    test('an interrupted item at the attempt cap fails instead of looping',
        () async {
      await h.initQueue();
      await q.enqueue(draft(), customerName: 'A');
      for (var i = 0; i < UploadQueue.maxAttempts - 1; i++) {
        await q.bumpAttempt('k1'); // → attemptCount 10 (cap is 11)
      }
      await q.markUploading('k1');

      await q.closeForTest();
      await h.initQueue();

      final item = q.items.single;
      expect(item.attemptCount, UploadQueue.maxAttempts); // 10 + interrupted = 11
      expect(item.status, QueueStatus.failed);
    });
  });

  group('orphan reconciliation', () {
    test('a stray audio file with no row is swept on init', () async {
      await h.initQueue();
      final orphan = File(p.join(h.dir.path, 'queue_audio', 'orphan.bin'));
      await orphan.writeAsBytes(const [1, 2, 3]);
      expect(orphan.existsSync(), isTrue);

      await q.closeForTest();
      await h.initQueue();
      expect(orphan.existsSync(), isFalse);
    });

    test('a row whose audio file vanished is dropped on init', () async {
      await h.initQueue();
      await q.enqueue(draft(audio: await makeAudio()), customerName: 'A');
      final abs = q.absoluteAudioPath(q.items.single)!;
      await File(abs).delete(); // the file disappears out from under the row

      await q.closeForTest();
      await h.initQueue();
      expect(q.items, isEmpty);
    });

    test('an abandoned visit_note_* temp in the docs root is swept', () async {
      await h.initQueue();
      final temp = File(p.join(h.dir.path, 'visit_note_abandoned.tmp'));
      await temp.writeAsBytes(const [9]);

      await q.closeForTest();
      await h.initQueue();
      expect(temp.existsSync(), isFalse);
    });
  });

  group('schema migration', () {
    test('v1 DB upgrades to v2 (adds next_attempt_at) and re-opens cleanly',
        () async {
      // Build a v1-schema DB (no next_attempt_at column) with one row.
      final dbPath = p.join(h.dir.path, 'upload_queue.db');
      final v1 = await databaseFactory.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, _) => db.execute('''
            CREATE TABLE upload_queue (
              idempotency_key TEXT PRIMARY KEY,
              customer_id TEXT NOT NULL,
              customer_name TEXT NOT NULL,
              lead_ids TEXT NOT NULL,
              notes TEXT NOT NULL,
              latitude REAL, longitude REAL, accuracy REAL,
              audio_path TEXT, audio_mime TEXT,
              audio_duration_ms INTEGER, audio_size_bytes INTEGER,
              status TEXT NOT NULL,
              attempt_count INTEGER NOT NULL DEFAULT 0,
              created_at INTEGER NOT NULL
            )
          '''),
        ),
      );
      await v1.insert('upload_queue', {
        'idempotency_key': 'old1',
        'customer_id': 'c',
        'customer_name': 'Legacy',
        'lead_ids': '[]',
        'notes': 'n',
        'status': 'queued',
        'attempt_count': 0,
        'created_at': DateTime.now().millisecondsSinceEpoch,
      });
      await v1.close();

      // Open through the queue at v2 → onUpgrade adds the column.
      await h.initQueue();
      expect(q.items, hasLength(1));
      expect(q.items.single.idempotencyKey, 'old1');
      expect(q.items.single.customerName, 'Legacy');
      expect(q.items.single.nextAttemptAt, isNull); // new column → eligible now

      // Re-open: the "duplicate column" guard means no crash the second time.
      await q.closeForTest();
      await h.initQueue();
      expect(q.items, hasLength(1));
    });
  });
}
