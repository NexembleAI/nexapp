import 'models/tracking_models.dart';

/// Visit sessions + visit reports domain (backend arrives in Phase 2).
/// Methods grow as screens need them; the real implementation will merge the
/// server list with the local offline upload queue.
abstract class ReportsRepository {
  /// Assigned once at startup (main.dart): mock now, Nexcore-backed later.
  static late ReportsRepository instance;

  Future<TodayStats> todayStats();

  Future<List<VisitEntry>> todayVisits();
}
