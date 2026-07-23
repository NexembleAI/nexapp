import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'connectivity_service.dart';
import 'models/tracking_models.dart';
import 'upload_queue.dart';

/// How an upload attempt ended, as classified by the injected
/// [UploadUploader.upload] hook. Maps onto the API's error model:
/// 5xx/network/timeout are retryable; 4xx (bad customer id, revoked lead,
/// audio too large) is terminal; 401 is neither — it's the session, not the
/// item.
enum UploadOutcome { success, retryable, terminal, unauthenticated }

/// Drains the durable queue while online, one item at a time. The POST and the
/// server's success-reaction are injected: [upload] is wired to the real
/// [VisitReportClient] in main.dart, [onUploaded] to the local repos.
class UploadUploader {
  UploadUploader._();
  static final UploadUploader instance = UploadUploader._();

  /// Retry cap ([UploadQueue.maxAttempts]) with [backoff] gives base delays of
  /// 1,2,4,…,256,300s — a ~15-minute window (each jittered to [base/2, base]),
  /// enough to ride out a deploy or a blip before bothering the user.
  static const Duration _maxBackoff = Duration(minutes: 5);

  /// The upload itself, classified. Injected (the real HTTP client in main.dart).
  /// [onProgress] reports fractional upload progress (0..1) for the live bar.
  Future<UploadOutcome> Function(
    QueuedReport, {
    void Function(double fraction)? onProgress,
  })? upload;

  /// The server's reaction on success (persist in history + auto-resolve
  /// alerts). The real backend does this server-side and pushes it back.
  void Function(QueuedReport)? onUploaded;

  bool _busy = false;
  bool _paused = false; // set on unauthenticated; cleared by resume()
  Timer? _retryTimer;
  int _lastProgressPct = -1; // last whole-percent forwarded for the live item

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

  /// Detaches listeners and resets the drain flags so each uploader test starts
  /// from a known state (the uploader is a process-lifetime singleton). Inert in
  /// the app — no production code calls it.
  @visibleForTesting
  void resetForTest() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _busy = false;
    _paused = false;
    _lastProgressPct = -1;
    ConnectivityService.instance.changes.removeListener(_onChange);
    UploadQueue.instance.changes.removeListener(_onChange);
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

  static final Random _rng = Random();

  /// Exponential 1, 2, 4, … capped at [_maxBackoff], with **equal jitter**: the
  /// actual delay is `base/2 + random·base/2`, i.e. uniform in `[base/2, base]`.
  /// The randomization decorrelates a fleet of clients retrying after a shared
  /// outage (a deploy, a flaky uplink) so they don't reconnect in lockstep and
  /// stampede the edge. [rng] is injectable so the backoff is unit-testable.
  @visibleForTesting
  static Duration backoff(int attempt, {Random? rng}) {
    final base = min(pow(2, attempt - 1).toInt(), _maxBackoff.inSeconds);
    final half = base / 2;
    final delay = half + (rng ?? _rng).nextDouble() * half; // seconds
    return Duration(milliseconds: (delay * 1000).round());
  }

  /// Forward real upload progress to the queue, but only when the whole-percent
  /// bucket changes — byte-level ticks fire far more often than the bar (or the
  /// progressChanges notifier) needs. The drain is serial, so a single scalar
  /// tracks the one in-flight item; [_upload] resets it per attempt.
  void _reportProgress(String id, double fraction) {
    final pct = (fraction * 100).clamp(0, 100).floor();
    if (pct == _lastProgressPct) return;
    _lastProgressPct = pct;
    UploadQueue.instance.setProgress(id, pct / 100);
  }

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
    _lastProgressPct = -1; // fresh per attempt (the drain is serial)
    await UploadQueue.instance.markUploading(id);

    UploadOutcome outcome;
    try {
      outcome = await (upload?.call(
            item,
            onProgress: (f) => _reportProgress(id, f),
          ) ??
          Future.value(UploadOutcome.success));
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
            .markRetry(id, DateTime.now().add(backoff(attempt)));
        return false;
    }
  }
}
