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

  @override
  Future<List<ReportEntry>> reports() async {
    await Future.delayed(_latency);
    final now = DateTime.now();
    DateTime daysAgo(int d, int h, int m) {
      final day = now.subtract(Duration(days: d));
      return DateTime(day.year, day.month, day.day, h, m);
    }

    return [
      ReportEntry(
        customerName: 'Meridian Logistics',
        createdAt: daysAgo(0, 12, 4),
        status: ReportStatus.queued, // local queue: no session dwell yet
        hasAudio: true,
        hasNotes: true,
      ),
      ReportEntry(
        customerName: 'Brightwell Foods',
        createdAt: daysAgo(0, 9, 45),
        dwell: const Duration(minutes: 18),
        status: ReportStatus.ready,
        hasAudio: true,
        hasNotes: false,
      ),
      ReportEntry(
        customerName: 'Apex Manufacturing',
        createdAt: daysAgo(1, 14, 10),
        dwell: const Duration(minutes: 31),
        status: ReportStatus.transcribing,
        hasAudio: true,
        hasNotes: true,
      ),
      ReportEntry(
        customerName: 'Vanguard Pharma',
        createdAt: daysAgo(2, 16, 30),
        status: ReportStatus.submitted,
        hasAudio: false,
        hasNotes: true,
        geofencePresent: false,
      ),
      ReportEntry(
        customerName: 'Northwind Traders',
        createdAt: daysAgo(11, 11, 5),
        dwell: const Duration(minutes: 22),
        status: ReportStatus.ready,
        hasAudio: false,
        hasNotes: true,
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
