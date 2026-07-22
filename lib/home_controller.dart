import 'package:flutter/foundation.dart';

import 'crm_name_resolver.dart';
import 'models/tracking_models.dart';
import 'tracking_api_client.dart';
import 'tracking_dto.dart';

/// Single owner of the Home tab's backend data. Fetches the three tracking
/// lists (sessions / reports / alerts) once per refresh, resolves customer
/// names for the visible visits, and exposes the derived views the Home widgets
/// read (weekly activity, today's stats, today's visits, the needs-action alert
/// count). A [ChangeNotifier] so widgets rebuild on refresh.
///
/// The raw session/report/alert lists it caches are the same data the Reports
/// and Alerts tabs will later read — this is the shared fetch point.
class HomeController extends ChangeNotifier {
  HomeController._();
  static final HomeController instance = HomeController._();

  // Recent lists are "today plus history"; 500 (the server max) covers a day
  // and the 7-day activity window comfortably. There is no server date filter,
  // so the windowing below is client-side.
  static const int _pageSize = 500;
  static const Duration _staleAfter = Duration(seconds: 45);
  // After an attempt, ensureLoaded() backs off this long before another (a
  // burst of change-notifies must not each kick a fresh failed refresh).
  static const Duration _minRetryGap = Duration(seconds: 3);

  List<VisitSessionDto> _sessions = const [];
  List<VisitReportDto> _reports = const [];
  List<LeadAlertDto> _alerts = const [];
  Map<String, String> _names = const {};

  DateTime? _loadedAt;
  DateTime? _lastAttemptAt;
  Future<void>? _inflight;
  bool _error = false;
  int _generation = 0; // bumped by reset(); an in-flight load with a stale
  // generation discards its result instead of repopulating.

  /// Drops the previous session's cached data on sign-out, so the next user (a
  /// different account on a shared device) never sees it. Bumping [_generation]
  /// makes any in-flight [_run] discard its result. No notifyListeners: the auth
  /// gate disposes the Home subtree, and the next sign-in mounts fresh widgets
  /// that fetch (hasData is false again).
  void reset() {
    _generation++;
    _sessions = const [];
    _reports = const [];
    _alerts = const [];
    _names = const {};
    _loadedAt = null;
    _lastAttemptAt = null;
    _inflight = null;
    _error = false;
  }

  bool get hasData => _loadedAt != null;

  /// True only when we failed AND have nothing cached to show.
  bool get hasError => _error && !hasData;

  // ── refresh entry points ───────────────────────────────────────────────

  /// Load once if we've never loaded; otherwise a no-op (cheap for a widget's
  /// initState, and for the change-notify re-reads).
  Future<void> ensureLoaded() {
    if (hasData) return Future.value();
    final inflight = _inflight;
    if (inflight != null) return inflight; // coalesce onto the running load
    // No data + not loading: only start a refresh if we haven't just tried.
    // Without this, a failed load's notifyListeners fans out to every widget,
    // each calling ensureLoaded -> refresh the moment _inflight clears — a tight
    // offline retry storm. An explicit refresh()/refreshIfStale (pull, focus,
    // resume, upload) bypasses this gap.
    final last = _lastAttemptAt;
    if (last != null && DateTime.now().difference(last) < _minRetryGap) {
      return Future.value();
    }
    return refresh();
  }

  /// Refresh only if the cache is older than [_staleAfter] — for tab-focus and
  /// app-resume, so switching back to Home doesn't always hit the network.
  Future<void> refreshIfStale() {
    final at = _loadedAt;
    if (at == null || DateTime.now().difference(at) > _staleAfter) {
      return refresh();
    }
    return Future.value();
  }

  /// Full refresh: 3 lists in parallel, then one CRM resolve for the visible
  /// visits. Concurrent calls coalesce onto the same in-flight future (so a
  /// widget's ensureLoaded actually awaits the load). Never throws — failure
  /// sets [hasError] and keeps any prior data.
  Future<void> refresh() =>
      _inflight ??= _run().whenComplete(() => _inflight = null);

  Future<void> _run() async {
    final gen = _generation;
    _lastAttemptAt = DateTime.now();
    try {
      final res = await Future.wait([
        _list('visit/session', 'sessions'),
        _list('visit/report', 'reports'),
        _list('alert', 'alerts'),
      ]);
      final sessions = res[0].map(VisitSessionDto.fromJson).toList();
      final reports = res[1].map(VisitReportDto.fromJson).toList();
      final alerts = res[2].map(LeadAlertDto.fromJson).toList();

      // Resolve names only for today's visit customers (all we display).
      final now = DateTime.now();
      final custIds = {
        for (final s in sessions)
          if (s.enteredAt != null && _sameDay(s.enteredAt!, now))
            if (s.customerId.isNotEmpty) s.customerId,
      };
      final names = await CrmNameResolver.instance.customerNames(custIds);

      if (gen != _generation) return; // reset() (sign-out) mid-load — discard
      _sessions = sessions;
      _reports = reports;
      _alerts = alerts;
      _names = names;
      _loadedAt = DateTime.now();
      _error = false;
    } catch (e, st) {
      if (gen != _generation) return; // discard a stale failure too
      // Fail-together: one failed list blanks the refresh rather than showing an
      // inconsistent snapshot (e.g. sessions with their reports missing). Prior
      // data is kept; hasError only surfaces when there's nothing cached. Log in
      // debug so a programming error (bad parse, null deref) isn't silently
      // hidden as "hasError".
      _error = true;
      if (kDebugMode) debugPrint('[home] refresh failed: $e\n$st');
    } finally {
      notifyListeners();
    }
  }

  /// GETs a list endpoint and pulls out its repeated field (`sessions` etc.).
  /// A missing field (proto-zero for an empty list) yields `[]`.
  Future<List<Map<String, dynamic>>> _list(String path, String field) async {
    final raw = await TrackingApiClient.instance
        .get(path, query: {'pageSize': _pageSize});
    final j = (raw is Map) ? raw.cast<String, dynamic>() : const {};
    final arr = j[field];
    return arr is List
        ? arr.whereType<Map>().map((m) => m.cast<String, dynamic>()).toList()
        : const [];
  }

  // ── derived views (sync; read the cached snapshot) ─────────────────────

  /// Visits-per-day over the last 7 days, normalized 0..1 against the rolling
  /// 7-day max; oldest→newest, last bucket = today. All-zero week → flat zeros.
  List<double> get weeklyActivity {
    final now = DateTime.now();
    // UTC midnights from the LOCAL calendar date, so the day delta is exact:
    // a plain local difference().inDays truncates a 23-hour DST day to 0 and
    // mis-buckets by one. Dates are already local (Wire.timestamp .toLocal()).
    final today = DateTime.utc(now.year, now.month, now.day);
    final counts = List<int>.filled(7, 0);
    for (final s in _sessions) {
      final e = s.enteredAt;
      if (e == null) continue;
      final days = today.difference(DateTime.utc(e.year, e.month, e.day)).inDays;
      if (days >= 0 && days < 7) counts[6 - days]++; // index 6 = today
    }
    final max = counts.fold<int>(0, (m, c) => c > m ? c : m);
    return max == 0
        ? List<double>.filled(7, 0)
        : counts.map((c) => c / max).toList();
  }

  /// Today's visit + report counts (client-windowed on entered_at / created_at).
  /// Reports are server-side only here; the ReportsRepository folds in
  /// not-yet-uploaded queued items when it wires this in.
  TodayStats get todayStats {
    final now = DateTime.now();
    final visits = _sessions
        .where((s) => s.enteredAt != null && _sameDay(s.enteredAt!, now))
        .length;
    final reports = _reports
        .where((r) => r.createdAt != null && _sameDay(r.createdAt!, now))
        .length;
    return TodayStats(visits: visits, reports: reports);
  }

  /// Today's visits, newest first, each joined to its report (by
  /// visit_session_id) for a status — null when no report was filed yet.
  /// customerName is '' when unresolved; the row renders "Unnamed customer".
  List<VisitEntry> get todayVisits {
    final bySession = <String, VisitReportDto>{};
    for (final r in _reports) {
      if (r.visitSessionId.isNotEmpty) {
        bySession.putIfAbsent(r.visitSessionId, () => r); // reports newest-first
      }
    }
    final now = DateTime.now();
    final today = _sessions
        .where((s) => s.enteredAt != null && _sameDay(s.enteredAt!, now))
        .toList()
      ..sort((a, b) => b.enteredAt!.compareTo(a.enteredAt!));
    return [
      for (final s in today)
        VisitEntry(
          customerName: _names[s.customerId] ?? '',
          enteredAt: s.enteredAt!,
          dwell: s.dwell,
          ongoing: s.isOpen, // exited_at unset → still at the customer
          status: bySession[s.id]?.status,
        ),
    ];
  }

  /// Needs-action alert count: open + escalated + expired-snooze (the backend
  /// never reopens a snooze, so we re-classify it client-side).
  int get openAlertsCount {
    final now = DateTime.now();
    return _alerts
        .where((a) => alertNeedsAction(a.status, a.snoozeUntil, now))
        .length;
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}

/// Thrown by the Home repos when the coordinator has no data AND the last load
/// failed, so a widget shows its error state. A load with cached data never
/// throws (stale data is returned instead).
class HomeDataException implements Exception {
  const HomeDataException();
}
