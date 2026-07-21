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

  /// Retry cap ([UploadQueue.maxAttempts]) with [_backoff] gives delays of
  /// 1,2,4,…,256,300s — roughly a 13-minute window, enough to ride out a deploy
  /// or a blip before bothering the user.
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
    if (ConnectivityService.instance.isOnline) {
      _maybeDrain();
    } else {
      // Going offline: drop the wake timer (we can't upload now anyway). The
      // per-item backoff lives in the DB (next_attempt_at), so nothing is lost
      // — the next online edge re-reads it and drains or reschedules. An
      // in-flight upload is left alone: its outcome decides the item's fate.
      _retryTimer?.cancel();
    }
  }

  /// 1s, 2s, 4s … capped at [_maxBackoff] so a long outage retries every 5
  /// minutes instead of drifting to hours.
  static Duration _backoff(int attempt) => Duration(
        seconds: min(pow(2, attempt - 1).toInt(), _maxBackoff.inSeconds),
      );

  /// A single timer that wakes the drain when the soonest backing-off item
  /// becomes due. Replaces a per-failure timer, so the backoff is driven by the
  /// persisted next_attempt_at rather than a fragile in-memory schedule.
  void _scheduleWake() {
    _retryTimer?.cancel();
    final delay = UploadQueue.instance.durationUntilNextDue;
    if (delay == null) return; // nothing backing off
    _retryTimer = Timer(delay.isNegative ? Duration.zero : delay, _maybeDrain);
  }

  Future<void> _maybeDrain() async {
    if (_busy || _paused || !ConnectivityService.instance.isOnline) return;
    final next = UploadQueue.instance.nextPending;
    if (next == null) {
      // Nothing due right now; arm the wake for the soonest backing-off item.
      _scheduleWake();
      return;
    }
    _busy = true;
    bool settled = false;
    try {
      settled = await _upload(next);
    } finally {
      // Always clear _busy, even if _upload throws (a DB/file op could) — one
      // escaped exception must never leave the drain wedged for the process.
      _busy = false;
    }
    if (settled) {
      // Keep draining any other due items — only after _busy is cleared, or the
      // recursive call short-circuits on the guard above and the queue drains
      // one item per trigger instead of continuously.
      _maybeDrain();
    } else {
      // Backed off (retryable) or paused (unauthenticated): arm the wake so the
      // item resumes when its next_attempt_at comes, without re-picking it now.
      _scheduleWake();
    }
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
        if (attempt >= UploadQueue.maxAttempts) {
          await UploadQueue.instance.markFailed(id);
          return true;
        }
        // Stamp the next-eligible time on the item so the backoff can't be
        // bypassed by an unrelated drain trigger; the wake timer is only an
        // optimization on top of this persisted schedule.
        await UploadQueue.instance
            .markRetry(id, DateTime.now().add(_backoff(attempt)));
        return false;
    }
  }
}
