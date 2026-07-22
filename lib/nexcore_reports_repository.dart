import 'package:flutter/foundation.dart';

import 'home_controller.dart';
import 'models/tracking_models.dart';
import 'reports_repository.dart';

/// Real ReportsRepository. Home methods (todayStats/todayVisits) come from the
/// Home coordinator; the Reports-tab methods delegate to [_tabs] (the mock)
/// until that tab is built. `changes` merges both sources so Home widgets and
/// the (mock) Reports tab each stay current — cached in a `late final` so
/// add/removeListener target the same instance.
class NexcoreReportsRepository implements ReportsRepository {
  final ReportsRepository _tabs;
  NexcoreReportsRepository(this._tabs);

  @override
  late final Listenable changes =
      Listenable.merge([HomeController.instance, _tabs.changes]);

  @override
  Future<TodayStats> todayStats() async {
    await HomeController.instance.ensureLoaded();
    if (HomeController.instance.hasError) throw const HomeDataException();
    return HomeController.instance.todayStats;
  }

  @override
  Future<List<VisitEntry>> todayVisits() async {
    await HomeController.instance.ensureLoaded();
    if (HomeController.instance.hasError) throw const HomeDataException();
    return HomeController.instance.todayVisits;
  }

  // Reports tab — still mock until it's built.
  @override
  Future<List<ReportEntry>> reports() => _tabs.reports();

  @override
  Future<ReportDetail> reportDetail(String id) => _tabs.reportDetail(id);

  @override
  Future<void> updateReport(
    String id, {
    required String notes,
    required List<String> leadIds,
  }) =>
      _tabs.updateReport(id, notes: notes, leadIds: leadIds);
}
