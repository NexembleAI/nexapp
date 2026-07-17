import 'dart:async';
import 'dart:math';

import 'connectivity_service.dart';
import 'models/tracking_models.dart';
import 'upload_queue.dart';

/// How an upload attempt ended, as classified by the injected
/// [UploadUploader.upload] hook. Maps onto the API's error model:
/// 5xx/network/timeout are retryable; 4xx (bad customer id, revoked lead,
/// audio too large) is terminal; 401 is neither — it's the session, not the
/// item.
enum UploadOutcome { success, retryable, terminal, unauthenticated }

/// Drains the durable queue while online, one item at a time. Real client
/// service; the POST and the server's success-reaction are injected
/// (simulated now, real when POST /visit/report exists).
class UploadUploader {
  UploadUploader._();
  static final UploadUploader instance = UploadUploader._();

  /// Retryable failures before an item becomes terminally failed. With
  /// [_backoff] the delays run 1,2,4,…,256,300s — roughly a 13-minute window,
  /// enough to ride out a deploy or a blip before bothering the user.
  static const int maxAttempts = 11;
  static const Duration _maxBackoff = Duration(minutes: 5);

  /// The upload itself, classified. Injected; real HTTP later.
  Future<UploadOutcome> Function(QueuedReport)? upload;

  /// The server's reaction on success (persist in history + auto-resolve
  /// alerts). The real backend does this server-side and pushes it back.
  void Function(QueuedReport)? onUploaded;

  bool _busy = false;
  bool _paused = false; // set on unauthenticated; cleared by resume()
  String? _currentId;
  Timer? _retryTimer;

  void start() {
    ConnectivityService.instance.changes.addListener(_onChange);
    UploadQueue.instance.changes.addListener(_onChange);
    _maybeDrain();
  }

  /// Resume after a rejected session is restored (see main.dart).
  void resume() {
    _paused = false;
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
    _retryTimer?.cancel();
    final id = _currentId;
    if (id == null) return;
    _currentId = null; // signals the progress loop to stop
    await UploadQueue.instance.markQueued(id);
  }

  /// 1s, 2s, 4s … capped at [_maxBackoff] so a long outage retries every 5
  /// minutes instead of drifting to hours.
  static Duration _backoff(int attempt) => Duration(
        seconds: min(pow(2, attempt - 1).toInt(), _maxBackoff.inSeconds),
      );

  void _scheduleRetry(Duration delay) {
    _retryTimer?.cancel();
    _retryTimer = Timer(delay, _maybeDrain);
  }

  Future<void> _maybeDrain() async {
    if (_busy || _paused || !ConnectivityService.instance.isOnline) return;
    final next = UploadQueue.instance.nextPending;
    if (next == null) return;
    _busy = true;
    _currentId = next.idempotencyKey;
    final settled = await _upload(next);
    _busy = false;
    _currentId = null;
    // Only continue when this attempt settled the item. A retryable failure
    // schedules its own backoff rather than re-picking the same row instantly.
    if (settled) _maybeDrain();
  }

  /// Returns true when the item is settled and the drain should move on.
  Future<bool> _upload(QueuedReport item) async {
    final id = item.idempotencyKey;
    await UploadQueue.instance.markUploading(id);

    // Simulated progress; the real HTTP upload will report its own.
    const steps = 20;
    for (var i = 1; i <= steps; i++) {
      await Future.delayed(const Duration(milliseconds: 200));
      if (_currentId != id) return false; // aborted (went offline)
      UploadQueue.instance.setProgress(id, i / steps);
    }

    final outcome =
        await (upload?.call(item) ?? Future.value(UploadOutcome.success));
    if (_currentId != id) return false; // aborted mid-flight

    switch (outcome) {
      case UploadOutcome.success:
        final removed = await UploadQueue.instance.markUploaded(id);
        if (removed != null) onUploaded?.call(removed);
        return true;

      case UploadOutcome.terminal:
        // Retrying can't fix a rejected payload — surface it to the user.
        await UploadQueue.instance.markFailed(id);
        return true;

      case UploadOutcome.unauthenticated:
        // Not this item's fault: don't spend its attempt budget. Stop draining
        // until the session is restored, or we'd spin against a dead token.
        _paused = true;
        await UploadQueue.instance.markQueued(id);
        return false;

      case UploadOutcome.retryable:
        // Safe to retry liberally: SubmitVisitReport is idempotent on
        // idempotency_key, so a retry reuses the server row, never duplicates.
        final attempt = await UploadQueue.instance.bumpAttempt(id);
        if (attempt >= maxAttempts) {
          await UploadQueue.instance.markFailed(id);
          return true;
        }
        await UploadQueue.instance.markQueued(id);
        _scheduleRetry(_backoff(attempt));
        return false;
    }
  }
}
