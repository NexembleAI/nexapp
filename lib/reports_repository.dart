import 'package:flutter/foundation.dart';

import 'models/tracking_models.dart';

/// Visit sessions + visit reports domain (backend arrives in Phase 2).
/// Methods grow as screens need them; the real implementation will merge the
/// server list with the local offline upload queue.
abstract class ReportsRepository {
  /// Assigned once at startup (main.dart): mock now, Nexcore-backed later.
  static late ReportsRepository instance;

  /// Notifies when the report list changes (e.g. when an upload completes) —
  /// the Reports tab and Home listen to stay current.
  Listenable get changes;

  Future<TodayStats> todayStats();

  Future<List<VisitEntry>> todayVisits();

  /// Full report history, newest first. The real implementation merges the
  /// server list with the local offline upload queue (queued/uploading rows).
  Future<List<ReportEntry>> reports();

  /// Full report for the detail screen (design screen 08).
  Future<ReportDetail> reportDetail(String id);

  /// Lightweight transcript/status poll (GetVisitReport only) — no name / lead /
  /// edit refetch. Driven by the detail screen while the report is still
  /// `submitted`/`transcribing` (§3.4).
  Future<ReportStatusUpdate> reportStatus(String id);

  /// Resolves a locally-playable file for the report's audio (fetch +
  /// base64-decode + temp-file on first call, cached per id), or null when
  /// there is no audio / it can't be fetched (§3.3). Audio is streamed on
  /// demand — never eagerly downloaded for the list.
  Future<String?> reportAudio(String id);

  /// Persists edited notes / lead tags — bumps version + appends audit
  /// entries (§4.4, §4.4.2).
  Future<void> updateReport(
    String id, {
    required String notes,
    required List<String> leadIds,
  });
}
