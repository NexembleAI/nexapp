import 'package:flutter/material.dart';

/// Lifecycle of a visit report, client- and server-side states combined.
/// queued/uploading exist only in the local offline queue (design screen 06);
/// the rest mirror tracking.visit_report.status (§4.4).
enum ReportStatus {
  queued,
  uploading,
  submitted,
  transcribing,
  ready,
  transcriptFailed,
  archived,
}

/// One visit row (Home "Today's visits" and the Reports history).
class VisitEntry {
  final String customerName;
  final DateTime enteredAt;
  final Duration dwell;
  final ReportStatus status;

  const VisitEntry({
    required this.customerName,
    required this.enteredAt,
    required this.dwell,
    required this.status,
  });
}

/// One row in the Reports history (design screen 07). Distinct from
/// VisitEntry: reports span days and carry content/upload facts the
/// home visit list doesn't show.
class ReportEntry {
  final String customerName;
  final DateTime createdAt;

  /// Session dwell; null when there is none to show (report not yet synced,
  /// or no geofence session to measure).
  final Duration? dwell;
  final ReportStatus status;
  final bool hasAudio;
  final bool hasNotes;

  /// False mirrors tracking.visit_report.geofence_present = false — renders
  /// the "No geofence — location recorded" note instead of time · dwell.
  final bool geofencePresent;

  const ReportEntry({
    required this.customerName,
    required this.createdAt,
    this.dwell,
    required this.status,
    required this.hasAudio,
    required this.hasNotes,
    this.geofencePresent = true,
  });
}

/// Counts for the Home stats row (alerts count comes from AlertsRepository).
class TodayStats {
  final int visits;
  final int reports;

  const TodayStats({required this.visits, required this.reports});
}

/// Office-hours window (mirrors tracking.device.office_hours).
class OfficeHours {
  final TimeOfDay start;
  final TimeOfDay end;

  const OfficeHours({required this.start, required this.end});
}
