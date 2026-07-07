/// Lead-coverage alerts domain (backend arrives in Phase 3).
abstract class AlertsRepository {
  /// Assigned once at startup (main.dart): mock now, Nexcore-backed later.
  static late AlertsRepository instance;

  /// Feeds the tab badge and the Home stats tile — single owner of this fact.
  Future<int> openAlertsCount();
}
