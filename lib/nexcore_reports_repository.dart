import 'package:flutter/foundation.dart';

import 'home_controller.dart';
import 'models/tracking_models.dart';
import 'reports_repository.dart';
import 'upload_queue.dart';

/// Real ReportsRepository. Home methods (todayStats/todayVisits) come from the
/// Home coordinator; the Reports-tab methods delegate to [_tabs] (the mock)
/// until that tab is built. `changes` merges the coordinator, the local upload
/// queue, and the mock so Home widgets and the (mock) Reports tab each stay
/// current — cached in a `late final` so add/removeListener target the same
/// instance.
class NexcoreReportsRepository implements ReportsRepository {
  final ReportsRepository _tabs;
  NexcoreReportsRepository(this._tabs);

  @override
  late final Listenable changes = Listenable.merge([
    HomeController.instance,
    UploadQueue.instance.changes, // a just-filed report bumps the count live
    _tabs.changes,
  ]);

  @override
  Future<TodayStats> todayStats() async {
    await HomeController.instance.ensureLoaded();
    if (HomeController.instance.hasError) throw const HomeDataException();
    final server = HomeController.instance.todayStats;
    // Fold in reports filed today still in the local upload queue (not yet on
    // the server). An uploaded item is removed from the queue, so queue and
    // server are effectively disjoint — no dedup needed. NOTE(P2.4): while the
    // uploader is simulated it "uploads" without a real POST, so a report drops
    // from the count once it leaves the queue; the real SubmitVisitReport keeps
    // it (the server then has it).
    final now = DateTime.now();
    final queuedToday = UploadQueue.instance.items.where((q) {
      final c = q.createdAt;
      return c.year == now.year && c.month == now.month && c.day == now.day;
    }).length;
    return TodayStats(
      visits: server.visits,
      reports: server.reports + queuedToday,
    );
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
  Future<ReportStatusUpdate> reportStatus(String id) => _tabs.reportStatus(id);

  @override
  Future<String?> reportAudio(String id) => _tabs.reportAudio(id);

  @override
  Future<void> updateReport(
    String id, {
    required String notes,
    required List<String> leadIds,
  }) =>
      _tabs.updateReport(id, notes: notes, leadIds: leadIds);
}
