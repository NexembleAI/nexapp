import 'connectivity_service.dart';
import 'models/tracking_models.dart';
import 'upload_queue.dart';

/// Drains the durable queue while online, one item at a time. Real client
/// service; the POST and the server's success-reaction are injected
/// (simulated now, real when POST /visit/report exists).
class UploadUploader {
  UploadUploader._();
  static final UploadUploader instance = UploadUploader._();

  /// The upload itself — returns success. Injected; real HTTP later.
  Future<bool> Function(QueuedReport)? simulateUpload;

  /// The server's reaction on success (persist in history + auto-resolve
  /// alerts). The real backend does this server-side and pushes it back.
  void Function(QueuedReport)? onUploaded;

  bool _busy = false;
  String? _currentId;

  void start() {
    ConnectivityService.instance.changes.addListener(_onChange);
    UploadQueue.instance.changes.addListener(_onChange);
    _maybeDrain();
  }

  void _onChange() {
    if (!ConnectivityService.instance.isOnline) {
      _abort();
    } else {
      _maybeDrain();
    }
  }

  Future<void> _abort() async {
    final id = _currentId;
    if (id == null) return;
    _currentId = null; // signals the progress loop to stop
    await UploadQueue.instance.markQueued(id);
  }

  Future<void> _maybeDrain() async {
    if (_busy || !ConnectivityService.instance.isOnline) return;
    final next = UploadQueue.instance.nextPending;
    if (next == null) return;
    _busy = true;
    _currentId = next.idempotencyKey;
    await _upload(next);
    _busy = false;
    if (_currentId != null) {
      _currentId = null;
      _maybeDrain(); // continue with the next item
    }
  }

  Future<void> _upload(QueuedReport item) async {
    final id = item.idempotencyKey;
    await UploadQueue.instance.markUploading(id);
    const steps = 20;
    for (var i = 1; i <= steps; i++) {
      await Future.delayed(const Duration(milliseconds: 200));
      if (_currentId != id) return; // aborted (went offline)
      UploadQueue.instance.setProgress(id, i / steps);
    }
    final ok = await (simulateUpload?.call(item) ?? Future.value(true));
    if (_currentId != id) return;
    if (!ok) {
      await UploadQueue.instance.markQueued(id);
      return;
    }
    final removed = await UploadQueue.instance.markUploaded(id);
    if (removed != null) onUploaded?.call(removed);
  }
}
