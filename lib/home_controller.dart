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

  List<VisitSessionDto> _sessions = const [];
  List<VisitReportDto> _reports = const [];
  List<LeadAlertDto> _alerts = const [];
  Map<String, String> _names = const {};

  DateTime? _loadedAt;
  bool _loading = false;
  bool _error = false;

  bool get hasData => _loadedAt != null;

  /// True only when we failed AND have nothing cached to show.
  bool get hasError => _error && !hasData;

  // ── refresh entry points ───────────────────────────────────────────────

  /// Load once if we've never loaded; otherwise a no-op (cheap for a widget's
  /// initState).
  Future<void> ensureLoaded() => hasData ? Future.value() : refresh();

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
  /// visits. Concurrent calls coalesce. Never throws — failure sets [hasError]
  /// and keeps any prior data.
  Future<void> refresh() async {
    if (_loading) return;
    _loading = true;
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

      _sessions = sessions;
      _reports = reports;
      _alerts = alerts;
      _names = names;
      _loadedAt = DateTime.now();
      _error = false;
    } catch (_) {
      // Fail-together: one failed list blanks the refresh rather than showing an
      // inconsistent snapshot (e.g. sessions with their reports missing). Prior
      // data is kept; hasError only surfaces when there's nothing cached.
      _error = true;
    } finally {
      _loading = false;
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
    final today = DateTime(now.year, now.month, now.day);
    final counts = List<int>.filled(7, 0);
    for (final s in _sessions) {
      final e = s.enteredAt;
      if (e == null) continue;
      final days = today.difference(DateTime(e.year, e.month, e.day)).inDays;
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
          status: bySession[s.id]?.status,
        ),
    ];
  }

  /// Needs-action alert count: open + escalated + expired-snooze (the backend
  /// never reopens a snooze, so we re-classify it client-side).
  int get openAlertsCount {
    final now = DateTime.now();
    return _alerts.where((a) {
      return switch (a.status) {
        AlertStatus.open || AlertStatus.escalated => true,
        AlertStatus.snoozed =>
          a.snoozeUntil != null && a.snoozeUntil!.isBefore(now),
        _ => false,
      };
    }).length;
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}
