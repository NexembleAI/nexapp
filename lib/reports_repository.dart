import 'package:flutter/foundation.dart';

import 'models/tracking_models.dart';

/// Visit sessions + visit reports domain (backend arrives in Phase 2).
/// Methods grow as screens need them; the real implementation will merge the
/// server list with the local offline upload queue.
abstract class ReportsRepository {
  /// Assigned once at startup (main.dart): mock now, Nexcore-backed later.
  static late ReportsRepository instance;

  /// Notifies when the report list changes (e.g. when an upload completes) —
  /// the Reports tab and Home listen to stay current.
  Listenable get changes;

  Future<TodayStats> todayStats();

  Future<List<VisitEntry>> todayVisits();

  /// Full report history, newest first. The real implementation merges the
  /// server list with the local offline upload queue (queued/uploading rows).
  Future<List<ReportEntry>> reports();
}
