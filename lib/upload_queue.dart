import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'models/tracking_models.dart';

/// Durable, client-side offline upload queue for visit reports (§2.3.3):
/// sqflite-backed metadata + audio files on disk, an in-memory cache, and a
/// changes notifier. The uploader (separate service) drains it.
class UploadQueue {
  UploadQueue._();
  static final UploadQueue instance = UploadQueue._();

  /// Retryable failures (graceful or app-kill-mid-POST) before an item becomes
  /// terminally failed. Lives here, not on the uploader, so the crash-recovery
  /// path in [init] enforces the same cap the graceful retry path does.
  static const int maxAttempts = 11;

  Database? _db;
  String? _audioDir;
  final List<QueuedReport> _items = [];
  final _QueueChanges _changes = _QueueChanges();
  final _QueueChanges _progressChanges = _QueueChanges();

  /// Fires on membership/status transitions (enqueue, mark*, retry) — NOT on
  /// upload-progress ticks. Home + the Reports tab listen here so a ~5/second
  /// progress stream doesn't fan out to widgets that don't show a progress bar.
  Listenable get changes => _changes;

  /// Fires on upload-progress ticks only ([setProgress]). Just the confirmation
  /// screen's live-queue bars listen here.
  Listenable get progressChanges => _progressChanges;

  List<QueuedReport> get items => List.unmodifiable(_items);

  /// Oldest queued item that is *due* (FIFO), or null. Items backing off after
  /// a retryable failure carry a future [QueuedReport.nextAttemptAt] and are
  /// skipped until their time comes — so an unrelated drain trigger (a new
  /// enqueue, a connectivity flap, an app relaunch) can't burn their attempts.
  QueuedReport? get nextPending {
    final now = DateTime.now();
    QueuedReport? oldest;
    for (final i in _items) {
      if (i.status == QueueStatus.queued &&
          !(i.nextAttemptAt?.isAfter(now) ?? false) &&
          (oldest == null || i.createdAt.isBefore(oldest.createdAt))) {
        oldest = i;
      }
    }
    return oldest;
  }

  /// Time until the soonest not-yet-due queued item becomes eligible, or null
  /// if nothing is backing off. The uploader uses this to set a single wake
  /// timer instead of a per-failure one.
  Duration? get durationUntilNextDue {
    final now = DateTime.now();
    DateTime? soonest;
    for (final i in _items) {
      final at = i.nextAttemptAt;
      if (i.status == QueueStatus.queued &&
          at != null &&
          at.isAfter(now) &&
          (soonest == null || at.isBefore(soonest))) {
        soonest = at;
      }
    }
    return soonest?.difference(now);
  }

  Future<void> markUploading(String id) async {
    _updateCache(
      id,
      (i) => i.copyWith(status: QueueStatus.uploading, progress: 0),
    );
    await _db!.update(
      'upload_queue',
      {'status': QueueStatus.uploading.name},
      where: 'idempotency_key = ?',
      whereArgs: [id],
    );
    _changes.bump();
  }

  /// In-memory only (progress isn't persisted). Bumps [progressChanges], not
  /// [changes] — a progress tick isn't a membership/status change, so Home and
  /// the Reports list must not re-derive on every ~200ms tick.
  void setProgress(String id, double p) {
    _updateCache(id, (i) => i.copyWith(progress: p));
    _progressChanges.bump();
  }

  Future<void> markQueued(String id) async {
    _updateCache(
      id,
      (i) => i.copyWith(status: QueueStatus.queued, progress: 0),
    );
    await _db!.update(
      'upload_queue',
      {'status': QueueStatus.queued.name},
      where: 'idempotency_key = ?',
      whereArgs: [id],
    );
    _changes.bump();
  }

  /// Retryable failure: back to `queued`, but not eligible until [dueAt]. The
  /// due-time is persisted, so the backoff survives a restart and [nextPending]
  /// skips the item until then — no unrelated drain trigger can re-pick it early.
  Future<void> markRetry(String id, DateTime dueAt) async {
    _updateCache(
      id,
      (i) => i.copyWith(
        status: QueueStatus.queued,
        progress: 0,
        nextAttemptAt: dueAt,
      ),
    );
    await _db!.update(
      'upload_queue',
      {
        'status': QueueStatus.queued.name,
        'next_attempt_at': dueAt.millisecondsSinceEpoch,
      },
      where: 'idempotency_key = ?',
      whereArgs: [id],
    );
    _changes.bump();
  }

  /// Terminal failure. The drain skips it automatically, since [nextPending]
  /// only ever picks `queued` items.
  Future<void> markFailed(String id) async {
    _updateCache(
      id,
      (i) => i.copyWith(status: QueueStatus.failed, progress: 0),
    );
    await _db!.update(
      'upload_queue',
      {'status': QueueStatus.failed.name},
      where: 'idempotency_key = ?',
      whereArgs: [id],
    );
    _changes.bump();
  }

  /// Counts retryable failures and returns the new total. Persisted, so the
  /// retry cap survives a restart.
  Future<int> bumpAttempt(String id) async {
    var count = 0;
    _updateCache(id, (i) {
      count = i.attemptCount + 1;
      return i.copyWith(attemptCount: count);
    });
    await _db!.update(
      'upload_queue',
      {'attempt_count': count},
      where: 'idempotency_key = ?',
      whereArgs: [id],
    );
    return count;
  }

  /// Manual retry from the UI: back to `queued` with a fresh attempt budget and
  /// due immediately (clears any leftover backoff time).
  Future<void> retryFailed(String id) async {
    _updateCache(
      id,
      (i) => i.copyWith(
        status: QueueStatus.queued,
        progress: 0,
        attemptCount: 0,
        clearNextAttempt: true,
      ),
    );
    await _db!.update(
      'upload_queue',
      {
        'status': QueueStatus.queued.name,
        'attempt_count': 0,
        'next_attempt_at': null,
      },
      where: 'idempotency_key = ?',
      whereArgs: [id],
    );
    _changes.bump(); // wakes the uploader's drain
  }

  /// Removes the item (row + audio file) on success; returns it for the
  /// uploader to hand to the server-reaction hook.
  Future<QueuedReport?> markUploaded(String id) async {
    final idx = _items.indexWhere((i) => i.idempotencyKey == id);
    if (idx < 0) return null;
    final item = _items.removeAt(idx);
    await _db!.delete(
      'upload_queue',
      where: 'idempotency_key = ?',
      whereArgs: [id],
    );
    final abs = absoluteAudioPath(item);
    if (abs != null) {
      try {
        await File(abs).delete();
      } catch (_) {}
    }
    _changes.bump();
    return item;
  }

  void _updateCache(String id, QueuedReport Function(QueuedReport) t) {
    final i = _items.indexWhere((r) => r.idempotencyKey == id);
    if (i >= 0) _items[i] = t(_items[i]);
  }

  /// Closes the DB and drops the in-memory cache so a test can re-[init] a fresh
  /// (or the same, to simulate a restart) queue without leaking a connection.
  @visibleForTesting
  Future<void> closeForTest() async {
    await _db?.close();
    _db = null;
    _audioDir = null;
    _items.clear();
  }

  /// [databasesDir]/[documentsDir] default to the platform paths in production;
  /// tests pass an isolated temp dir to avoid touching real app storage and to
  /// keep each case independent (no path_provider mock needed).
  Future<void> init({
    @visibleForTesting String? databasesDir,
    @visibleForTesting String? documentsDir,
  }) async {
    _db = await openDatabase(
      p.join(databasesDir ?? await getDatabasesPath(), 'upload_queue.db'),
      version: 2,
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
          next_attempt_at INTEGER,
          created_at INTEGER NOT NULL
        )
      '''),
      // v2 adds per-item backoff. Existing rows get NULL (= eligible now).
      onUpgrade: (db, oldV, _) async {
        if (oldV < 2) {
          // Idempotent: only add if absent. A dev downgrade (v2->v1->v2) can
          // leave the column present with the version rolled back, which would
          // otherwise make this ALTER throw "duplicate column" and crash the
          // app on open. Production never downgrades, but the guard is cheap.
          final cols = await db.rawQuery('PRAGMA table_info(upload_queue)');
          final hasColumn = cols.any((c) => c['name'] == 'next_attempt_at');
          if (!hasColumn) {
            await db.execute(
              'ALTER TABLE upload_queue ADD COLUMN next_attempt_at INTEGER',
            );
          }
        }
      },
    );

    final docsPath = documentsDir ?? (await getApplicationDocumentsDirectory()).path;
    _audioDir = p.join(docsPath, 'queue_audio');
    await Directory(_audioDir!).create(recursive: true);

    final rows = await _db!.query('upload_queue', orderBy: 'created_at DESC');
    _items
      ..clear()
      ..addAll(rows.map(QueuedReport.fromMap));

    // An upload interrupted by app-kill resumes as queued (idempotency key
    // makes a re-attempt safe). Count the interrupted attempt: an item that
    // reliably kills the app mid-POST (e.g. an OOM payload) would otherwise
    // retry every launch forever, since the graceful retryable cap never sees
    // it — the process dies before the hook returns. Once it hits the cap, fail
    // it instead of requeuing.
    for (var i = 0; i < _items.length; i++) {
      if (_items[i].status == QueueStatus.uploading) {
        final attempt = _items[i].attemptCount + 1;
        final status =
            attempt >= maxAttempts ? QueueStatus.failed : QueueStatus.queued;
        _items[i] = _items[i].copyWith(status: status, attemptCount: attempt);
        await _db!.update(
          'upload_queue',
          {'status': status.name, 'attempt_count': attempt},
          where: 'idempotency_key = ?',
          whereArgs: [_items[i].idempotencyKey],
        );
      }
    }

    await _reconcileOrphans();
    if (kDebugMode) debugPrint('[queue] loaded ${_items.length} item(s)');
  }

  Future<void> enqueue(
    ReportDraft draft, {
    required String customerName,
  }) async {
    final audioPath = draft.audio != null
        ? await _persistAudio(draft.idempotencyKey, draft.audio!)
        : null;
    final item = QueuedReport(
      idempotencyKey: draft.idempotencyKey,
      customerId: draft.customerId,
      customerName: customerName,
      leadIds: draft.leadIds,
      notes: draft.notes,
      latitude: draft.position?.latitude,
      longitude: draft.position?.longitude,
      accuracyMeters: draft.position?.accuracyMeters,
      audioPath: audioPath,
      audioMime: draft.audio?.mimeType,
      audioDurationMs: draft.audio?.duration.inMilliseconds,
      audioSizeBytes: draft.audio?.sizeBytes,
      status: QueueStatus.queued,
      createdAt: DateTime.now(),
    );
    await _db!.insert(
      'upload_queue',
      item.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    // Mirror the DB's replace-on-conflict in memory: a reused idempotency_key
    // collapses to one row in SQLite, so replace an existing entry in place
    // rather than appending a ghost the DB doesn't have. Callers mint a fresh
    // key per submit, but a double-tap on Submit could re-enqueue the same
    // draft before the screen pops — replacing in place keeps enqueue()
    // idempotent, so a today-Reports count derived from the queue isn't doubled.
    final existing = _items.indexWhere(
      (i) => i.idempotencyKey == item.idempotencyKey,
    );
    if (existing >= 0) {
      _items[existing] = item;
      _changes.bump();
      return;
    }
    _items.insert(0, item);
    _changes.bump();
  }

  /// Absolute path for a stored audio filename, rebuilt against the current
  /// audio dir (iOS container paths change between launches — we persist only
  /// the filename, never an absolute path).
  String? absoluteAudioPath(QueuedReport item) =>
      item.audioPath == null ? null : p.join(_audioDir!, item.audioPath!);

  /// Moves the recorded temp file into the queue-owned persistent dir; returns
  /// the FILENAME (relative), which is what gets persisted.
  Future<String> _persistAudio(String id, ReportAudio audio) async {
    final fileName = '$id${p.extension(audio.path)}';
    final dest = p.join(_audioDir!, fileName);
    final src = File(audio.path);
    try {
      await src.rename(dest); // same-filesystem move
    } catch (_) {
      await src.copy(dest); // cross-fs fallback
      try {
        await src.delete();
      } catch (_) {}
    }
    return fileName;
  }

  /// Deletes audio files with no row, and drops rows whose audio is missing.
  Future<void> _reconcileOrphans() async {
    // 1. Sweep the queue-owned audio dir: files no live row references.
    final known = _items.map((i) => i.audioPath).whereType<String>().toSet();
    final dir = Directory(_audioDir!);
    await for (final f in dir.list()) {
      if (f is File && !known.contains(p.basename(f.path))) {
        try {
          await f.delete();
        } catch (_) {}
      }
    }

    // 2. Sweep abandoned recorder temp files in the documents root. A recording
    // that reached the queue was renamed into _audioDir, so any root-level
    // `visit_note_*` file is one the app died on between stop and enqueue (the
    // review-state window). Scoped to that prefix + File type so it can never
    // touch queue_audio/ (a Directory) or anything else in the root. Runs in
    // init() before any recording this session, so it can't race a live one.
    try {
      final docs = Directory(p.dirname(_audioDir!)); // <Documents>
      await for (final f in docs.list()) {
        if (f is File && p.basename(f.path).startsWith('visit_note_')) {
          try {
            await f.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}

    // 3. Drop queue rows whose audio file has vanished.
    final missing = <String>[];
    for (final i in _items) {
      final abs = absoluteAudioPath(i);
      if (abs != null && !await File(abs).exists()) {
        missing.add(i.idempotencyKey);
      }
    }
    for (final key in missing) {
      _items.removeWhere((i) => i.idempotencyKey == key);
      await _db!.delete(
        'upload_queue',
        where: 'idempotency_key = ?',
        whereArgs: [key],
      );
    }
  }
}

class _QueueChanges extends ChangeNotifier {
  void bump() => notifyListeners();
}
