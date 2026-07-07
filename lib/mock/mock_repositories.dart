import 'package:flutter/material.dart';

import '../alerts_repository.dart';
import '../models/tracking_models.dart';
import '../reports_repository.dart';
import '../tracking_repository.dart';

/// Canned data matching the design mockups (doc/design/04-home-*.png).
/// This whole folder is deleted once the real backends land; main.dart holds
/// the only imports of it.
///
/// Every method waits [_latency] so loading states are actually exercised.
const _latency = Duration(milliseconds: 400);

class MockReportsRepository implements ReportsRepository {
  @override
  Future<TodayStats> todayStats() async {
    await Future.delayed(_latency);
    return const TodayStats(visits: 4, reports: 3);
  }

  @override
  Future<List<VisitEntry>> todayVisits() async {
    await Future.delayed(_latency);
    final today = DateTime.now();
    DateTime at(int h, int m) =>
        DateTime(today.year, today.month, today.day, h, m);
    return [
      VisitEntry(
        customerName: 'Meridian Logistics',
        enteredAt: at(11, 20),
        dwell: const Duration(minutes: 24),
        status: ReportStatus.ready,
      ),
      VisitEntry(
        customerName: 'Brightwell Foods',
        enteredAt: at(9, 45),
        dwell: const Duration(minutes: 18),
        status: ReportStatus.transcribing,
      ),
    ];
  }
}

class MockAlertsRepository implements AlertsRepository {
  @override
  Future<int> openAlertsCount() async {
    await Future.delayed(_latency);
    return 2;
  }
}

class MockTrackingRepository implements TrackingRepository {
  @override
  Future<OfficeHours> officeHours() async {
    await Future.delayed(_latency);
    return const OfficeHours(
      start: TimeOfDay(hour: 9, minute: 0),
      end: TimeOfDay(hour: 17, minute: 30),
    );
  }

  @override
  Future<List<double>> todayActivity() async {
    await Future.delayed(_latency);
    return const [0.3, 0.5, 0.4, 0.7, 0.6, 0.9, 0.5, 0.8, 0.6, 0.4, 0.3, 0.2];
  }
}
