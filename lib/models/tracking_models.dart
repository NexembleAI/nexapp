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

/// Status of a lead-coverage alert, mirroring tracking.lead_alert (§4.6).
enum AlertStatus { open, ack, snoozed, resolved, escalated }

/// Why the alert fired — lead_alert.reason_code.
enum AlertReason { noVisitWindow, nextActivityOverdue, leadStale }

/// One lead-coverage alert (design screens 09/10), produced by the per-lead
/// alert workflow (§3.4).
class LeadAlert {
  final String id;
  final String leadTitle;
  final String accountName;
  final AlertReason reason;

  // Reason-line values from lead_alert.details; which ones are set depends
  // on [reason].
  final int? daysSinceVisit; // noVisitWindow
  final int? thresholdDays; // noVisitWindow
  final int? closeInDays; // nextActivityOverdue

  final DateTime createdAt;
  final AlertStatus status;
  final DateTime? snoozeUntil;

  const LeadAlert({
    required this.id,
    required this.leadTitle,
    required this.accountName,
    required this.reason,
    this.daysSinceVisit,
    this.thresholdDays,
    this.closeInDays,
    required this.createdAt,
    required this.status,
    this.snoozeUntil,
  });

  /// True when the alert still demands a decision (top section + badge).
  bool get needsAction =>
      status == AlertStatus.open || status == AlertStatus.escalated;

  LeadAlert copyWith({AlertStatus? status, DateTime? snoozeUntil}) => LeadAlert(
        id: id,
        leadTitle: leadTitle,
        accountName: accountName,
        reason: reason,
        daysSinceVisit: daysSinceVisit,
        thresholdDays: thresholdDays,
        closeInDays: closeInDays,
        createdAt: createdAt,
        status: status ?? this.status,
        snoozeUntil: snoozeUntil ?? this.snoozeUntil,
      );
}

/// Office-hours window (mirrors tracking.device.office_hours).
class OfficeHours {
  final TimeOfDay start;
  final TimeOfDay end;

  const OfficeHours({required this.start, required this.end});
}
