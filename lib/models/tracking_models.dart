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

  ReportAudio copyWith({Duration? duration}) => ReportAudio(
        path: path,
        mimeType: mimeType,
        duration: duration ?? this.duration,
        sizeBytes: sizeBytes,
      );
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

  /// Earliest time this item is eligible to upload again. Set on a retryable
  /// failure to now + backoff; null means eligible immediately. Persisted so
  /// the backoff survives a restart and can't be bypassed by an unrelated
  /// drain trigger — [UploadQueue.nextPending] skips items whose time is future.
  final DateTime? nextAttemptAt;

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
    this.nextAttemptAt,
  });

  bool get hasAudio => audioPath != null;
  bool get hasNotes => notes.isNotEmpty;

  QueuedReport copyWith({
    QueueStatus? status,
    int? attemptCount,
    double? progress,
    String? audioPath,
    DateTime? nextAttemptAt,
    bool clearNextAttempt = false,
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
        // clearNextAttempt wins so a manual retry can reset a future backoff to
        // "eligible now" (copyWith's `?? this` can't otherwise assign null).
        nextAttemptAt:
            clearNextAttempt ? null : (nextAttemptAt ?? this.nextAttemptAt),
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
        'next_attempt_at': nextAttemptAt?.millisecondsSinceEpoch,
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
        nextAttemptAt: m['next_attempt_at'] != null
            ? DateTime.fromMillisecondsSinceEpoch(m['next_attempt_at'] as int)
            : null,
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

  /// The customer's open leads, for the editable [LeadSelector] on the detail
  /// screen (real: ListCustomerLeads for the report's customer, merged with any
  /// currently-tagged lead so a closed-but-tagged lead still renders).
  final List<Lead> leadOptions;

  /// False when the report isn't the signed-in user's — a manager viewing
  /// another rep's report gets no edit affordance (the server also 403s a
  /// cross-author PUT). Defaults true (own report / no identity to check).
  final bool editable;

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
    this.leadOptions = const [],
    this.editable = true,
  });

  ReportDetail copyWith({
    String? notes,
    List<String>? leadIds,
    int? version,
    List<ReportEdit>? edits,
    ReportStatus? status,
    // Nullable field: an explicit flag distinguishes "leave unchanged" from
    // "set to null" — a transcript poll can clear a stale transcript.
    Object? transcript = _unset,
  }) =>
      ReportDetail(
        id: id,
        customerId: customerId,
        customerName: customerName,
        createdAt: createdAt,
        dwell: dwell,
        status: status ?? this.status,
        geofencePresent: geofencePresent,
        transcript:
            identical(transcript, _unset) ? this.transcript : transcript as String?,
        notes: notes ?? this.notes,
        audioPresent: audioPresent,
        audioDurationS: audioDurationS,
        audioMime: audioMime,
        leadIds: leadIds ?? this.leadIds,
        version: version ?? this.version,
        edits: edits ?? this.edits,
        leadOptions: leadOptions,
        editable: editable,
      );
}

/// Sentinel for [ReportDetail.copyWith]'s nullable `transcript` param.
const Object _unset = Object();

/// The volatile bits a transcript poll refreshes (GetVisitReport only) — kept
/// small so the poll doesn't re-resolve names / re-list leads and edits.
class ReportStatusUpdate {
  final ReportStatus status;
  final String? transcript;

  const ReportStatusUpdate({required this.status, this.transcript});
}

/// One visit row (Home "Today's visits" and the Reports history).
class VisitEntry {
  final String customerName;
  final DateTime enteredAt;
  final Duration dwell;

  /// True while the visit is still open (the session hasn't exited yet). The row
  /// shows "Ongoing" instead of a meaningless 0-minute dwell.
  final bool ongoing;

  /// Status of this visit's report, or null when no report has been filed yet
  /// (a session with no matching visit_report). The row renders "No report yet".
  final ReportStatus? status;

  const VisitEntry({
    required this.customerName,
    required this.enteredAt,
    required this.dwell,
    this.ongoing = false,
    this.status,
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

/// [status] with the client-side snooze-expiry derivation applied: the backend
/// never reopens a snooze, so a snoozed alert whose [snoozeUntil] has passed
/// reads as open. Single source of truth — used by both [LeadAlert] (domain) and
/// the Home needs-action count (which works off the wire DTO).
AlertStatus effectiveAlertStatus(
        AlertStatus status, DateTime? snoozeUntil, DateTime now) =>
    status == AlertStatus.snoozed &&
            snoozeUntil != null &&
            !snoozeUntil.isAfter(now)
        ? AlertStatus.open
        : status;

/// True when the alert still demands a decision (Home badge/count + the Alerts
/// tab's top section).
bool alertNeedsAction(AlertStatus status, DateTime? snoozeUntil, DateTime now) {
  final s = effectiveAlertStatus(status, snoozeUntil, now);
  return s == AlertStatus.open || s == AlertStatus.escalated;
}

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
      effectiveAlertStatus(status, snoozeUntil, DateTime.now());

  /// True when the alert still demands a decision (top section + badge).
  bool get needsAction => alertNeedsAction(status, snoozeUntil, DateTime.now());

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

  /// True when today is a configured non-working day (empty or unlisted in the
  /// schedule); [start]/[end] are unused then and the badge shows "Closed today".
  final bool closed;

  const OfficeHours({required this.start, required this.end}) : closed = false;

  const OfficeHours._closed()
      : start = const TimeOfDay(hour: 0, minute: 0),
        end = const TimeOfDay(hour: 0, minute: 0),
        closed = true;

  /// Used when the device has no schedule at all — assume a standard day.
  static const OfficeHours defaultHours = OfficeHours(
    start: TimeOfDay(hour: 9, minute: 0),
    end: TimeOfDay(hour: 17, minute: 30),
  );

  /// Today is a configured non-working day.
  static const OfficeHours closedToday = OfficeHours._closed();

  /// Parses a tracking.device.office_hours JSON string
  /// (`{"tz":..., "weekly_schedule":{"mon":[["09:00","18:00"]], ...}}`) into
  /// TODAY's window. Timezone is ignored — the "HH:MM" values are shown as
  /// device-local wall-clock (the tz governs the backend's gating, not this
  /// display). Three outcomes:
  ///   • null            — no schedule at all (absent / unparseable / `{}`); the
  ///                       caller substitutes [defaultHours].
  ///   • [closedToday]   — a schedule exists but today is empty or unlisted
  ///                       (authoritative: missing day == closed, like the gate).
  ///   • a window        — today's earliest start … latest end (collapses a
  ///                       multi-window day, e.g. a lunch split).
  static OfficeHours? tryFromDeviceJson(String? json, {DateTime? now}) {
    if (json == null) return null;
    final s = json.trim();
    if (s.isEmpty || s == '{}' || s == 'null') return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(s);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    final sched = decoded['weekly_schedule'];
    if (sched is! Map || sched.isEmpty) return null; // no schedule → default

    // Schedule IS configured → authoritative. Today's key decides. [now] is
    // injectable for tests; production reads the wall clock.
    const keys = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
    final windows = sched[keys[(now ?? DateTime.now()).weekday - 1]]; // Mon=1
    if (windows is! List || windows.isEmpty) return closedToday; // empty/unlisted

    int? minStart, maxEnd; // minutes since midnight
    for (final w in windows) {
      if (w is! List || w.length != 2) continue;
      final start = _hhmm(w[0]);
      final end = _hhmm(w[1]);
      if (start == null || end == null) continue;
      if (minStart == null || start < minStart) minStart = start;
      if (maxEnd == null || end > maxEnd) maxEnd = end;
    }
    if (minStart == null || maxEnd == null) return closedToday; // no valid window
    return OfficeHours(
      start: TimeOfDay(hour: minStart ~/ 60, minute: minStart % 60),
      end: TimeOfDay(hour: maxEnd ~/ 60, minute: maxEnd % 60),
    );
  }

  static int? _hhmm(Object? v) {
    if (v is! String) return null;
    final parts = v.split(':');
    if (parts.length != 2) return null;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null || h < 0 || h > 23 || m < 0 || m > 59) return null;
    return h * 60 + m;
  }
}
