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
      // Going offline only stops us *starting* work: cancel a pending retry.
      // An in-flight upload is deliberately left alone — its outcome decides
      // the item's fate (the request will simply fail if the network is gone).
      _retryTimer?.cancel();
    } else {
      _maybeDrain();
    }
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
    bool settled = false;
    try {
      settled = await _upload(next);
    } finally {
      // Always clear _busy, even if _upload throws (a DB/file op could) — one
      // escaped exception must never leave the drain wedged for the process.
      _busy = false;
    }
    // Only continue when this attempt settled the item, and only after _busy is
    // cleared — otherwise the recursive call short-circuits on the guard above
    // and the queue drains one item per trigger instead of continuously. A
    // retryable failure schedules its own backoff rather than re-picking the
    // same row instantly.
    if (settled) _maybeDrain();
  }

  /// Returns true when the item is settled and the drain should move on.
  ///
  /// Once the request is in flight its outcome is authoritative — we never
  /// discard a settled result (e.g. because connectivity flipped), since
  /// throwing away a success would re-send the whole payload, audio included,
  /// and leave correctness resting on the server deduping idempotency_key.
  Future<bool> _upload(QueuedReport item) async {
    final id = item.idempotencyKey;
    await UploadQueue.instance.markUploading(id);

    // Simulated progress; the real HTTP upload will report its own. Breaking
    // early when offline is cosmetic (stop the bar) — the outcome below still
    // decides the item's fate.
    const steps = 20;
    for (var i = 1; i <= steps; i++) {
      await Future.delayed(const Duration(milliseconds: 200));
      if (!ConnectivityService.instance.isOnline) break;
      UploadQueue.instance.setProgress(id, i / steps);
    }

    UploadOutcome outcome;
    try {
      outcome =
          await (upload?.call(item) ?? Future.value(UploadOutcome.success));
    } catch (_) {
      // A real HTTP client throws (SocketException/TimeoutException) for exactly
      // the transient failures the policy treats as retryable — so a thrown hook
      // feeds the backoff path rather than escaping as an unhandled async error
      // and wedging the drain.
      outcome = UploadOutcome.retryable;
    }

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
