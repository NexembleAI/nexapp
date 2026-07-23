import 'models/tracking_models.dart';

/// Helpers for reading grpc-gateway JSON, which follows proto3 conventions:
/// zero-valued fields are OMITTED (not sent as 0/false/""), int64/uint64 arrive
/// as strings, enums as their full value NAME, and Timestamps as RFC-3339.
/// Every read supplies the proto zero-value default so a missing key never
/// throws. Keys are looked up in snake_case first, then camelCase, because the
/// gateway's field naming isn't pinned (TrackingService hedges both too).
class Wire {
  Wire._();

  static Object? _pick(Map<String, dynamic> j, String snake) =>
      j.containsKey(snake) ? j[snake] : j[_camel(snake)];

  static String _camel(String snake) {
    if (!snake.contains('_')) return snake;
    final parts = snake.split('_');
    return parts.first +
        parts
            .skip(1)
            .map((p) => p.isEmpty ? '' : p[0].toUpperCase() + p.substring(1))
            .join();
  }

  static String string(Map<String, dynamic> j, String k) =>
      (_pick(j, k) as String?) ?? '';

  static int integer(Map<String, dynamic> j, String k) {
    final v = _pick(j, k);
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0; // int64/uint64 come as strings
    return 0;
  }

  static bool boolean(Map<String, dynamic> j, String k) =>
      (_pick(j, k) as bool?) ?? false;

  /// RFC-3339 → local DateTime; null when the field is absent (proto zero).
  static DateTime? timestamp(Map<String, dynamic> j, String k) {
    final v = _pick(j, k) as String?;
    if (v == null || v.isEmpty) return null;
    return DateTime.tryParse(v)?.toLocal();
  }

  static List<String> stringList(Map<String, dynamic> j, String k) {
    final v = _pick(j, k);
    return v is List ? v.map((e) => e.toString()).toList() : const [];
  }
}

/// A tracking.visit_session row (list item). Only the fields Home/Reports use;
/// entry/exit GeoPoint + geofence_id/device_id/source are deferred until a
/// screen needs them.
class VisitSessionDto {
  final String id;
  final String customerId;
  final DateTime? enteredAt; // visit start
  final DateTime? exitedAt; // null while the visit is open
  final int durationS; // server-generated; 0 while open

  const VisitSessionDto({
    required this.id,
    required this.customerId,
    this.enteredAt,
    this.exitedAt,
    required this.durationS,
  });

  bool get isOpen => exitedAt == null;
  Duration get dwell => Duration(seconds: durationS);

  factory VisitSessionDto.fromJson(Map<String, dynamic> j) => VisitSessionDto(
        id: Wire.string(j, 'id'),
        customerId: Wire.string(j, 'customer_id'),
        enteredAt: Wire.timestamp(j, 'entered_at'),
        exitedAt: Wire.timestamp(j, 'exited_at'),
        durationS: Wire.integer(j, 'duration_s'),
      );
}

/// A tracking.visit_report row. Carries what the Home visit-status join and the
/// Reports list need; transcript/summary/report_position/version are detail-only
/// and deferred. NOTE: lead_ids is empty from ListVisitReports (populated only
/// by GetVisitReport) — it's modelled here for the detail path.
class VisitReportDto {
  final String id;
  final String visitSessionId; // '' for ad-hoc; the join key to a session
  final String customerId;
  final ReportStatus status;
  final bool geofencePresent;
  final String textBody;
  final String audioMimeType;
  final int audioSizeBytes;
  final int audioDurationS;
  final List<String> leadIds;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const VisitReportDto({
    required this.id,
    required this.visitSessionId,
    required this.customerId,
    required this.status,
    required this.geofencePresent,
    required this.textBody,
    required this.audioMimeType,
    required this.audioSizeBytes,
    required this.audioDurationS,
    required this.leadIds,
    this.createdAt,
    this.updatedAt,
  });

  bool get hasAudio => audioMimeType.isNotEmpty;
  bool get hasNotes => textBody.trim().isNotEmpty;

  factory VisitReportDto.fromJson(Map<String, dynamic> j) => VisitReportDto(
        id: Wire.string(j, 'id'),
        visitSessionId: Wire.string(j, 'visit_session_id'),
        customerId: Wire.string(j, 'customer_id'),
        status: _reportStatus(Wire.string(j, 'status')),
        geofencePresent: Wire.boolean(j, 'geofence_present'),
        textBody: Wire.string(j, 'text_body'),
        audioMimeType: Wire.string(j, 'audio_mime_type'),
        audioSizeBytes: Wire.integer(j, 'audio_size_bytes'),
        audioDurationS: Wire.integer(j, 'audio_duration_s'),
        leadIds: Wire.stringList(j, 'lead_ids'),
        createdAt: Wire.timestamp(j, 'created_at'),
        updatedAt: Wire.timestamp(j, 'updated_at'),
      );

  // Server states only; queued/uploading/uploadFailed are local-queue states
  // the server never emits. A live report is always >= submitted, so an absent
  // (proto-zero UNSPECIFIED) status defaults there.
  static ReportStatus _reportStatus(String wire) => switch (wire) {
        'REPORT_STATUS_SUBMITTED' => ReportStatus.submitted,
        'REPORT_STATUS_TRANSCRIBING' => ReportStatus.transcribing,
        'REPORT_STATUS_READY' => ReportStatus.ready,
        'REPORT_STATUS_TRANSCRIPT_FAILED' => ReportStatus.transcriptFailed,
        'REPORT_STATUS_ARCHIVED' => ReportStatus.archived,
        _ => ReportStatus.submitted,
      };
}

/// A tracking.lead_alert row. Full set — the Alerts tab is the near consumer;
/// Home only reads status + snooze_until + customer_id. `details` is kept as the
/// raw JSON string (the reason-specific numbers), parsed by the alert screen.
class LeadAlertDto {
  final String id; // == leadId (one open alert per lead)
  final String leadId;
  final String customerId;
  final AlertStatus status;
  final AlertReason reasonCode;
  final DateTime? snoozeUntil;
  final int snoozeCount;
  final DateTime? escalatedAt;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final int thresholdDays;
  final String details;

  const LeadAlertDto({
    required this.id,
    required this.leadId,
    required this.customerId,
    required this.status,
    required this.reasonCode,
    this.snoozeUntil,
    required this.snoozeCount,
    this.escalatedAt,
    this.createdAt,
    this.updatedAt,
    required this.thresholdDays,
    required this.details,
  });

  factory LeadAlertDto.fromJson(Map<String, dynamic> j) => LeadAlertDto(
        id: Wire.string(j, 'id'),
        leadId: Wire.string(j, 'lead_id'),
        customerId: Wire.string(j, 'customer_id'),
        status: _alertStatus(Wire.string(j, 'status')),
        reasonCode: _alertReason(Wire.string(j, 'reason_code')),
        snoozeUntil: Wire.timestamp(j, 'snooze_until'),
        snoozeCount: Wire.integer(j, 'snooze_count'),
        escalatedAt: Wire.timestamp(j, 'escalated_at'),
        createdAt: Wire.timestamp(j, 'created_at'),
        updatedAt: Wire.timestamp(j, 'updated_at'),
        thresholdDays: Wire.integer(j, 'threshold_days'),
        details: Wire.string(j, 'details'),
      );

  // A live alert is always >= open, so an absent status defaults to open (fail
  // toward showing it).
  static AlertStatus _alertStatus(String wire) => switch (wire) {
        'ALERT_STATUS_OPEN' => AlertStatus.open,
        'ALERT_STATUS_ACK' => AlertStatus.ack,
        'ALERT_STATUS_SNOOZED' => AlertStatus.snoozed,
        'ALERT_STATUS_RESOLVED' => AlertStatus.resolved,
        'ALERT_STATUS_ESCALATED' => AlertStatus.escalated,
        _ => AlertStatus.open,
      };

  static AlertReason _alertReason(String wire) => switch (wire) {
        'ALERT_REASON_NO_VISIT_WINDOW' => AlertReason.noVisitWindow,
        'ALERT_REASON_NEXT_ACTIVITY_OVERDUE' => AlertReason.nextActivityOverdue,
        'ALERT_REASON_LEAD_STALE' => AlertReason.leadStale,
        _ => AlertReason.noVisitWindow,
      };
}
