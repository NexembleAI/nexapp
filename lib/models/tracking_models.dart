import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';

/// A CRM customer (account), sourced from Odoo at runtime via the platform.
class Customer {
  final String id;
  final String name;
  final String address;

  const Customer({
    required this.id,
    required this.name,
    required this.address,
  });
}

/// A sales lead assigned to the current user, scoped to a customer.
class Lead {
  final String id;
  final String title;
  final String customerId;

  const Lead({
    required this.id,
    required this.title,
    required this.customerId,
  });
}

/// Recorded audio attached to a draft (path is app-private, deleted after
/// submission).
class ReportAudio {
  final String path;
  final String mimeType; // audio/ogg;codecs=opus (Android) or audio/mp4 (iOS)
  final Duration duration;
  final int sizeBytes;

  const ReportAudio({
    required this.path,
    required this.mimeType,
    required this.duration,
    required this.sizeBytes,
  });
}

/// Position captured at report time (report_position, §4.4).
class ReportPosition {
  final double latitude;
  final double longitude;
  final double accuracyMeters;

  const ReportPosition({
    required this.latitude,
    required this.longitude,
    required this.accuracyMeters,
  });
}

/// A visit report ready for submission (§3.3). Carries no user identity —
/// the server resolves the author from the bearer token.
class ReportDraft {
  final String customerId;
  final List<String> leadIds;
  final String notes;
  final ReportAudio? audio;
  final ReportPosition? position;

  /// Client-generated so a retried upload never duplicates server-side.
  final String idempotencyKey;

  const ReportDraft({
    required this.customerId,
    required this.leadIds,
    required this.notes,
    this.audio,
    this.position,
    required this.idempotencyKey,
  });

  /// Random 128-bit hex key from a CSPRNG — never derived from guessable
  /// data.
  static String newIdempotencyKey() {
    final rand = Random.secure();
    return List.generate(
      16,
      (_) => rand.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }
}

enum QueueStatus { queued, uploading, failed }

/// A visit report in the local durable upload queue (§2.3.3). PK is the
/// draft's idempotencyKey. `progress` is in-memory only (not persisted).
class QueuedReport {
  final String idempotencyKey;
  final String customerId;
  final String customerName; // denormalized for offline display
  final List<String> leadIds;
  final String notes;
  final double? latitude;
  final double? longitude;
  final double? accuracyMeters;
  final String? audioPath; // filename only (see UploadQueue.absoluteAudioPath)
  final String? audioMime;
  final int? audioDurationMs;
  final int? audioSizeBytes;
  final QueueStatus status;
  final int attemptCount;
  final DateTime createdAt;
  final double progress;

  const QueuedReport({
    required this.idempotencyKey,
    required this.customerId,
    required this.customerName,
    required this.leadIds,
    required this.notes,
    this.latitude,
    this.longitude,
    this.accuracyMeters,
    this.audioPath,
    this.audioMime,
    this.audioDurationMs,
    this.audioSizeBytes,
    required this.status,
    this.attemptCount = 0,
    required this.createdAt,
    this.progress = 0,
  });

  bool get hasAudio => audioPath != null;
  bool get hasNotes => notes.isNotEmpty;

  QueuedReport copyWith({
    QueueStatus? status,
    int? attemptCount,
    double? progress,
    String? audioPath,
  }) =>
      QueuedReport(
        idempotencyKey: idempotencyKey,
        customerId: customerId,
        customerName: customerName,
        leadIds: leadIds,
        notes: notes,
        latitude: latitude,
        longitude: longitude,
        accuracyMeters: accuracyMeters,
        audioPath: audioPath ?? this.audioPath,
        audioMime: audioMime,
        audioDurationMs: audioDurationMs,
        audioSizeBytes: audioSizeBytes,
        status: status ?? this.status,
        attemptCount: attemptCount ?? this.attemptCount,
        createdAt: createdAt,
        progress: progress ?? this.progress,
      );

  Map<String, Object?> toMap() => {
        'idempotency_key': idempotencyKey,
        'customer_id': customerId,
        'customer_name': customerName,
        'lead_ids': jsonEncode(leadIds),
        'notes': notes,
        'latitude': latitude,
        'longitude': longitude,
        'accuracy': accuracyMeters,
        'audio_path': audioPath,
        'audio_mime': audioMime,
        'audio_duration_ms': audioDurationMs,
        'audio_size_bytes': audioSizeBytes,
        'status': status.name,
        'attempt_count': attemptCount,
        'created_at': createdAt.millisecondsSinceEpoch,
      };

  factory QueuedReport.fromMap(Map<String, Object?> m) => QueuedReport(
        idempotencyKey: m['idempotency_key'] as String,
        customerId: m['customer_id'] as String,
        customerName: m['customer_name'] as String,
        leadIds: (jsonDecode(m['lead_ids'] as String) as List).cast<String>(),
        notes: m['notes'] as String,
        latitude: m['latitude'] as double?,
        longitude: m['longitude'] as double?,
        accuracyMeters: m['accuracy'] as double?,
        audioPath: m['audio_path'] as String?,
        audioMime: m['audio_mime'] as String?,
        audioDurationMs: m['audio_duration_ms'] as int?,
        audioSizeBytes: m['audio_size_bytes'] as int?,
        status: QueueStatus.values.byName(m['status'] as String),
        attemptCount: m['attempt_count'] as int,
        createdAt: DateTime.fromMillisecondsSinceEpoch(m['created_at'] as int),
      );
}

/// Lifecycle of a visit report, client- and server-side states combined.
/// queued/uploading exist only in the local offline queue (design screen 06);
/// the rest mirror tracking.visit_report.status (§4.4).
enum ReportStatus {
  queued,
  uploading,
  uploadFailed,
  submitted,
  transcribing,
  ready,
  transcriptFailed,
  archived,
}

enum ReportEditField { textBody, leadTags, audio }

/// One audit entry from tracking.visit_report_edit (§4.4.2) — per field.
class ReportEdit {
  final int version;
  final ReportEditField field;
  final DateTime editedAt;
  final String? editedBy;

  const ReportEdit({
    required this.version,
    required this.field,
    required this.editedAt,
    this.editedBy,
  });
}

/// Full visit report (design screen 08). Audio is play-only/immutable and,
/// in production, streamed from GET /visit/report/{id}/audio.
class ReportDetail {
  final String id;
  final String customerId;
  final String customerName;
  final DateTime createdAt;
  final Duration? dwell;
  final ReportStatus status;
  final bool geofencePresent;
  final String? transcript; // null until status == ready
  final String notes; // text_body, editable
  final bool audioPresent;
  final int? audioDurationS;
  final String? audioMime;
  final List<String> leadIds;
  final int version;
  final List<ReportEdit> edits;

  const ReportDetail({
    required this.id,
    required this.customerId,
    required this.customerName,
    required this.createdAt,
    this.dwell,
    required this.status,
    required this.geofencePresent,
    this.transcript,
    required this.notes,
    required this.audioPresent,
    this.audioDurationS,
    this.audioMime,
    required this.leadIds,
    required this.version,
    this.edits = const [],
  });

  ReportDetail copyWith({
    String? notes,
    List<String>? leadIds,
    int? version,
    List<ReportEdit>? edits,
  }) =>
      ReportDetail(
        id: id,
        customerId: customerId,
        customerName: customerName,
        createdAt: createdAt,
        dwell: dwell,
        status: status,
        geofencePresent: geofencePresent,
        transcript: transcript,
        notes: notes ?? this.notes,
        audioPresent: audioPresent,
        audioDurationS: audioDurationS,
        audioMime: audioMime,
        leadIds: leadIds ?? this.leadIds,
        version: version ?? this.version,
        edits: edits ?? this.edits,
      );
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
  final String? id; // server report id; null for queue-mapped rows
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
    this.id,
    required this.customerName,
    required this.createdAt,
    this.dwell,
    required this.status,
    required this.hasAudio,
    required this.hasNotes,
    this.geofencePresent = true,
  });

  /// A queued/uploading/failed item rendered as a report row in the Reports
  /// tab. [id] is the idempotency key, not a server report id — the Reports tab
  /// never navigates to detail for these statuses, it acts on the queue.
  factory ReportEntry.fromQueued(QueuedReport q) => ReportEntry(
        id: q.idempotencyKey,
        customerName: q.customerName,
        createdAt: q.createdAt,
        status: switch (q.status) {
          QueueStatus.uploading => ReportStatus.uploading,
          QueueStatus.failed => ReportStatus.uploadFailed,
          QueueStatus.queued => ReportStatus.queued,
        },
        hasAudio: q.hasAudio,
        hasNotes: q.hasNotes,
        geofencePresent: false, // manual, no geofence session (§3.3)
      );
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

/// Lead priority from Odoo (drives the threshold modifier, §4.6.1).
enum AlertPriority { high, medium, low }

/// One transition in an alert's lifecycle (§3.4 state machine). The client
/// renders these; the source of truth is server-side (workflow history) —
/// Phase 3 API note: alert detail needs an event-history endpoint.
enum AlertEventType { opened, acked, snoozed, reopened, escalated }

class AlertEvent {
  final AlertEventType type;
  final DateTime at;

  /// Snooze target — only set for [AlertEventType.snoozed].
  final DateTime? until;

  const AlertEvent(this.type, this.at, {this.until});
}

/// One lead-coverage alert (design screens 09/10), produced by the per-lead
/// alert workflow (§3.4).
class LeadAlert {
  final String id;
  final String leadId; // lead_alert.lead_id (§4.6)
  final String leadTitle;
  final String accountName;
  final String customerId; // lead_alert.customer_id (§4.6)
  final AlertReason reason;

  // Reason-line values from lead_alert.details; which ones are set depends
  // on [reason].
  final int? daysSinceVisit; // noVisitWindow
  final int? thresholdDays; // noVisitWindow
  final int? closeInDays; // nextActivityOverdue

  final DateTime createdAt;
  final AlertStatus status;
  final DateTime? snoozeUntil;

  // Detail-screen context (design screen 10); stage/priority/lastCoveredAt
  // come from Odoo at runtime and may be absent.
  final String? stage;
  final AlertPriority? priority;
  final DateTime? lastCoveredAt;

  /// When the escalation timer fires if not acknowledged (createdAt +
  /// coverage_rule.escalate_after_days).
  final DateTime? escalatesAt;

  /// Lifecycle events, oldest first; history[0] is always `opened`.
  final List<AlertEvent> history;

  const LeadAlert({
    required this.id,
    required this.leadId,
    required this.leadTitle,
    required this.accountName,
    required this.customerId,
    required this.reason,
    this.daysSinceVisit,
    this.thresholdDays,
    this.closeInDays,
    required this.createdAt,
    required this.status,
    this.snoozeUntil,
    this.stage,
    this.priority,
    this.lastCoveredAt,
    this.escalatesAt,
    this.history = const [],
  });

  /// The backend never flips a snoozed alert back to `open` — the lead-alert
  /// workflow's only timer is escalation, and nothing reads snooze_until, so
  /// ListLeadAlerts keeps reporting `snoozed` indefinitely (there is no
  /// reopen/unsnooze RPC either). Derive the reopen here instead — display
  /// only, nothing is written back: once [snoozeUntil] has passed, the alert
  /// is effectively open again.
  AlertStatus get effectiveStatus =>
      status == AlertStatus.snoozed &&
              snoozeUntil != null &&
              !snoozeUntil!.isAfter(DateTime.now())
          ? AlertStatus.open
          : status;

  /// True when the alert still demands a decision (top section + badge).
  bool get needsAction =>
      effectiveStatus == AlertStatus.open ||
      effectiveStatus == AlertStatus.escalated;

  /// [history] plus a derived `reopened` entry when the snooze has expired. The
  /// backend records no such event (it never reopens, so ListLeadAlertEvents
  /// will never carry one) — but [effectiveStatus] did, so the timeline
  /// explains why the alert is back instead of it just reappearing. Stamped at
  /// [snoozeUntil]: the moment it became actionable.
  List<AlertEvent> get timeline =>
      status == AlertStatus.snoozed &&
              effectiveStatus == AlertStatus.open &&
              snoozeUntil != null
          ? [...history, AlertEvent(AlertEventType.reopened, snoozeUntil!)]
          : history;

  LeadAlert copyWith({
    AlertStatus? status,
    DateTime? snoozeUntil,
    List<AlertEvent>? history,
  }) =>
      LeadAlert(
        id: id,
        leadId: leadId,
        leadTitle: leadTitle,
        accountName: accountName,
        customerId: customerId,
        reason: reason,
        daysSinceVisit: daysSinceVisit,
        thresholdDays: thresholdDays,
        closeInDays: closeInDays,
        createdAt: createdAt,
        status: status ?? this.status,
        snoozeUntil: snoozeUntil ?? this.snoozeUntil,
        stage: stage,
        priority: priority,
        lastCoveredAt: lastCoveredAt,
        escalatesAt: escalatesAt,
        history: history ?? this.history,
      );
}

/// Office-hours window (mirrors tracking.device.office_hours).
class OfficeHours {
  final TimeOfDay start;
  final TimeOfDay end;

  const OfficeHours({required this.start, required this.end});
}
