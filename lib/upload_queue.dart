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

  /// Moves the recorded temp file into the queue-owned persistent dir.
  Future<String> _persistAudio(String id, ReportAudio audio) async {
    final dest = p.join(_audioDir!, '$id${p.extension(audio.path)}');
    final src = File(audio.path);
    try {
      await src.rename(dest); // same-filesystem move
    } catch (_) {
      await src.copy(dest); // cross-fs fallback
      try {
        await src.delete();
      } catch (_) {}
    }
    return dest;
  }

  /// Deletes audio files with no row, and drops rows whose audio is missing.
  Future<void> _reconcileOrphans() async {
    final known = _items.map((i) => i.audioPath).whereType<String>().toSet();
    final dir = Directory(_audioDir!);
    await for (final f in dir.list()) {
      if (f is File && !known.contains(f.path)) {
        try {
          await f.delete();
        } catch (_) {}
      }
    }
    final missing = <String>[];
    for (final i in _items) {
      if (i.audioPath != null && !await File(i.audioPath!).exists()) {
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
