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

  Database? _db;
  String? _audioDir;
  final List<QueuedReport> _items = [];
  final _QueueChanges _changes = _QueueChanges();

  /// Fired on enqueue; wired in main.dart to bump the today-Reports stat.
  void Function(QueuedReport)? onEnqueued;

  Listenable get changes => _changes;
  List<QueuedReport> get items => List.unmodifiable(_items);

  /// Oldest queued item (FIFO), or null.
  QueuedReport? get nextPending {
    QueuedReport? oldest;
    for (final i in _items) {
      if (i.status == QueueStatus.queued &&
          (oldest == null || i.createdAt.isBefore(oldest.createdAt))) {
        oldest = i;
      }
    }
    return oldest;
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

  /// In-memory only (progress isn't persisted).
  void setProgress(String id, double p) {
    _updateCache(id, (i) => i.copyWith(progress: p));
    _changes.bump();
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

  /// Manual retry from the UI: back to `queued` with a fresh attempt budget.
  Future<void> retryFailed(String id) async {
    _updateCache(
      id,
      (i) => i.copyWith(
        status: QueueStatus.queued,
        progress: 0,
        attemptCount: 0,
      ),
    );
    await _db!.update(
      'upload_queue',
      {'status': QueueStatus.queued.name, 'attempt_count': 0},
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

  Future<void> init() async {
    _db = await openDatabase(
      p.join(await getDatabasesPath(), 'upload_queue.db'),
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
    );

    final docs = await getApplicationDocumentsDirectory();
    _audioDir = p.join(docs.path, 'queue_audio');
    await Directory(_audioDir!).create(recursive: true);

    final rows = await _db!.query('upload_queue', orderBy: 'created_at DESC');
    _items
      ..clear()
      ..addAll(rows.map(QueuedReport.fromMap));

    // An upload interrupted by app-kill resumes as queued (idempotency key
    // makes a re-attempt safe).
    for (var i = 0; i < _items.length; i++) {
      if (_items[i].status == QueueStatus.uploading) {
        _items[i] = _items[i].copyWith(status: QueueStatus.queued);
        await _db!.update(
          'upload_queue',
          {'status': QueueStatus.queued.name},
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
    _items.insert(0, item);
    _changes.bump();
    onEnqueued?.call(item);
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
