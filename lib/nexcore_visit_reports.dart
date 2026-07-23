import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'auth_config.dart';
import 'auth_service.dart';
import 'crm_name_resolver.dart';
import 'models/tracking_models.dart';
import 'reports_repository.dart';
import 'tracking_api_client.dart';
import 'tracking_dto.dart';

/// The real Reports TAB (#13 / P2.5) — the [ReportsRepository] surface Home's
/// [NexcoreReportsRepository] delegates the tab methods to (replacing the mock).
/// Turns the mock history seam real: `reports()` returns SERVER truth only
/// (newest-first) — the Reports screen still overlays the local upload queue
/// itself — and the detail path wires GetVisitReport + edits + audio + CRM name
/// resolution.
///
/// The reports carry only opaque Odoo refs (`customerId`/`leadIds`); display
/// names come from the shared, batched, TTL-cached [CrmNameResolver] (§4.1).
/// Audio is streamed on demand and decoded to a temp file (§3.3). Every
/// collaborator is injectable so tests drive it without a socket; production
/// falls back to the singletons.
class NexcoreVisitReportsTab implements ReportsRepository {
  NexcoreVisitReportsTab({
    Future<Object?> Function(String path,
            {Map<String, dynamic>? query, Duration? timeout})?
        get,
    Future<Object?> Function(String path, {Map<String, dynamic>? body})? put,
    Future<CrmNames> Function(
            {Iterable<String> customerIds, Iterable<String> leadIds})?
        resolveNames,
    Future<String?> Function()? currentUserId,
    Future<Directory> Function()? audioTempDir,
    // now/queueItems: part of the injectable repository seam, but this tab
    // throws for todayStats/todayVisits (Home is served by
    // NexcoreReportsRepository via HomeController, never this tab), so there is
    // no clock- or queue-dependent aggregation left on this path to feed them.
    DateTime Function()? now,
    List<QueuedReport> Function()? queueItems,
  })  : _get = get ?? TrackingApiClient.instance.get,
        _put = put ?? TrackingApiClient.instance.put,
        _resolveNames = resolveNames ?? CrmNameResolver.instance.resolve,
        _currentUserId = currentUserId ?? _defaultCurrentUserId,
        _audioTempDir = audioTempDir ?? getTemporaryDirectory;

  final Future<Object?> Function(String path,
      {Map<String, dynamic>? query, Duration? timeout}) _get;
  final Future<Object?> Function(String path, {Map<String, dynamic>? body}) _put;
  final Future<CrmNames> Function(
      {Iterable<String> customerIds, Iterable<String> leadIds}) _resolveNames;
  final Future<String?> Function() _currentUserId;
  final Future<Directory> Function() _audioTempDir;

  /// Best-effort IAM subject: any failure (no session, platform channel
  /// unavailable in tests) degrades to null — callers treat that as "identity
  /// unknown".
  static Future<String?> _defaultCurrentUserId() async {
    try {
      final claims = await AuthService.instance.idTokenClaims();
      return claims?['sub'] as String?;
    } catch (_) {
      return null;
    }
  }

  final _changes = _RepoChanges();
  @override
  Listenable get changes => _changes;

  // Last good reports list, returned on a transient failure so a flaky network
  // doesn't blank the history (§4.5).
  List<ReportEntry>? _lastReports;

  // Synthetic rows for uploads whose server row hasn't been observed by a
  // successful list fetch yet — keyed by idempotencyKey, overlaid on
  // failed/stale fetches so a just-uploaded report can't vanish (see
  // [reportUploaded]).
  final Map<String, ReportEntry> _justUploaded = {};

  // Decoded-audio temp files, one per report id (§3.3).
  final Map<String, String> _audioFiles = {};

  /// Called by [main] when a queued report finishes uploading. The queue row is
  /// already gone (markUploaded runs first), so until a LIST refetch actually
  /// succeeds the row would vanish from the Reports tab — hold a synthetic
  /// entry built from the queue item and overlay it on failed/stale fetches.
  /// Any SUCCESSFUL fetch necessarily includes the real server row (the 200
  /// committed before this ran), so synthetics are dropped there.
  void reportUploaded(QueuedReport item) {
    _justUploaded[item.idempotencyKey] = ReportEntry(
      id: null, // no server id known — not tappable until the real row lands
      customerName: item.customerName,
      createdAt: item.createdAt,
      status: ReportStatus.submitted,
      hasAudio: item.hasAudio,
      hasNotes: item.hasNotes,
      geofencePresent: false, // manual, no geofence session (§3.3)
    );
    _changes.bump();
  }

  // ===========================================================================
  // Reports list
  // ===========================================================================

  @override
  Future<List<ReportEntry>> reports() async {
    try {
      // Scope to the caller. The server only forces own-scope for NON-broad
      // callers (visit_report_api.go) — a sales-manager/super-admin with no
      // filter would get the WHOLE tenant rendered as "my" history. Passing
      // userId is a no-op for reps (the server overrides it back to self) and
      // correct scoping for the broad roles.
      final sub = await _currentUserId();
      final j = _asMap(await _get('visit/report', query: {
        if (sub != null && sub.isNotEmpty) 'userId': sub,
      }));
      // Not silently truncating: flag when the history spills past page one so
      // the missing "load more" is visible rather than looking like the whole
      // list. The server currently caps at 100 rows and never emits a
      // nextPageToken; this log is here for when it starts to.
      if (Wire.string(j, 'next_page_token').isNotEmpty) {
        developer.log('NexcoreVisitReportsTab: ListVisitReports has a '
            'nextPageToken — showing page 1 only (load-more is #13 follow-up)');
      }
      final dtos = [
        for (final m in _mapList(j['reports'])) VisitReportDto.fromJson(m),
      ];
      final names = await _resolveNames(
        customerIds: [for (final d in dtos) d.customerId],
      );
      final entries = [
        for (final d in dtos)
          ReportEntry(
            id: d.id,
            customerName:
                names.customer(d.customerId) ?? _fallbackName(d.customerId),
            createdAt: d.createdAt ?? _epoch,
            // No session dwell in the list payload; the card falls back to
            // content.
            dwell: null,
            status: d.status,
            hasAudio: d.hasAudio,
            hasNotes: d.hasNotes,
            geofencePresent: d.geofencePresent,
          ),
      ];
      // A successful fetch necessarily includes the real server row — the
      // upload's 200 committed before reportUploaded ran — so the synthetics
      // are now redundant and would double-render alongside their real rows.
      _justUploaded.clear();
      _lastReports = entries;
      return entries;
    } on ApiException {
      // Offline / transient / auth surfaced elsewhere — overlay any pending
      // just-uploaded synthetics on the last-known list so a report uploaded
      // while the network is flaky still shows (don't mutate _lastReports).
      return [..._justUploaded.values, ...(_lastReports ?? const [])];
    }
  }

  // ===========================================================================
  // Report detail
  // ===========================================================================

  @override
  Future<ReportDetail> reportDetail(String id) async {
    final j = _asMap(await _get('visit/report/$id'));
    final dto = VisitReportDto.fromJson(j);
    final customerId = dto.customerId;
    final leadIds = dto.leadIds;

    // Fan out the dependent reads; each degrades to empty on its own failure so
    // one disabled resolver can't sink the whole screen.
    final results = await Future.wait([
      _listEdits(id),
      _listCustomerLeads(customerId),
      _resolveNames(customerIds: [customerId], leadIds: leadIds),
      _currentUserId(),
    ]);
    final edits = results[0] as List<ReportEdit>;
    final customerLeads = results[1] as List<Lead>;
    final names = results[2] as CrmNames;
    final me = results[3] as String?;

    final authorId = Wire.string(j, 'user_id');
    final transcript = Wire.string(j, 'transcript');

    // Options = the customer's open leads, plus any currently-tagged lead that
    // ListCustomerLeads didn't return (won/closed) so it still renders as a
    // selected pill instead of silently vanishing.
    final options = <String, Lead>{for (final l in customerLeads) l.id: l};
    for (final leadId in leadIds) {
      options.putIfAbsent(
        leadId,
        () => Lead(
          id: leadId,
          title: names.lead(leadId) ?? _fallbackName(leadId),
          customerId: customerId,
        ),
      );
    }

    return ReportDetail(
      id: dto.id,
      customerId: customerId,
      customerName: names.customer(customerId) ?? _fallbackName(customerId),
      createdAt: dto.createdAt ?? _epoch,
      dwell: null, // session dwell is #18 (home dashboard) territory.
      status: dto.status,
      geofencePresent: dto.geofencePresent,
      transcript: transcript.isEmpty ? null : transcript,
      notes: dto.textBody,
      audioPresent: dto.hasAudio,
      audioDurationS: dto.audioDurationS == 0 ? null : dto.audioDurationS,
      audioMime: dto.audioMimeType.isEmpty ? null : dto.audioMimeType,
      leadIds: leadIds,
      version: Wire.integer(j, 'version'),
      edits: edits,
      leadOptions: options.values.toList(),
      // Author-only edit (Phase-2 F6). Unknown identity ⇒ leave editable; the
      // server masks a genuine cross-author PUT as NotFound regardless
      // (visit_report_api.go: "A non-author edit returns NotFound").
      editable: me == null || authorId.isEmpty ? true : authorId == me,
    );
  }

  @override
  Future<ReportStatusUpdate> reportStatus(String id) async {
    final j = _asMap(await _get('visit/report/$id'));
    final transcript = Wire.string(j, 'transcript');
    return ReportStatusUpdate(
      status: VisitReportDto.fromJson(j).status,
      transcript: transcript.isEmpty ? null : transcript,
    );
  }

  Future<List<ReportEdit>> _listEdits(String id) async {
    try {
      final j = _asMap(await _get('visit/report/$id/edits'));
      return [for (final e in _mapList(j['edits'])) _toEdit(e)];
    } on ApiException {
      return const [];
    }
  }

  ReportEdit _toEdit(Map<String, dynamic> e) => ReportEdit(
        version: Wire.integer(e, 'version'),
        field: _editField(Wire.string(e, 'field')),
        editedAt: Wire.timestamp(e, 'edited_at') ?? _epoch,
        editedBy: _emptyToNull(Wire.string(e, 'edited_by')),
      );

  /// The detail LeadSelector's re-tag options: the report's customer's open
  /// leads. Disabled resolver / offline ⇒ no options (the tagged leads still
  /// render via the union in [reportDetail]).
  Future<List<Lead>> _listCustomerLeads(String customerId) async {
    if (customerId.isEmpty) return const [];
    try {
      final j = _asMap(await _get('crm/customer/$customerId/leads'));
      return [
        for (final l in _mapList(j['leads']))
          Lead(
            id: Wire.string(l, 'lead_id'),
            title: Wire.string(l, 'name').isEmpty
                ? Wire.string(l, 'lead_id')
                : Wire.string(l, 'name'),
            customerId: Wire.string(l, 'customer_id'),
          ),
      ];
    } on ApiException {
      return const [];
    }
  }

  // ===========================================================================
  // Update (edit-in-place)
  // ===========================================================================

  @override
  Future<void> updateReport(
    String id, {
    required String notes,
    required List<String> leadIds,
  }) async {
    // A non-2xx throws ApiException from the client — let it propagate; the
    // detail screen catches it.
    await _put('visit/report/$id', body: {
      'tenantId': int.parse(AuthConfig.tenantId),
      'id': id,
      'textBody': notes,
      'leadIds': leadIds,
    });
    // The detail screen re-fetches (bumped version + new edit rows); other
    // listeners (the Reports tab) refresh off this.
    _changes.bump();
  }

  // ===========================================================================
  // Audio — decode-to-file, then play (§3.3)
  // ===========================================================================

  @override
  Future<String?> reportAudio(String id) async {
    final cached = _audioFiles[id];
    if (cached != null && await File(cached).exists()) return cached;
    try {
      // Up to ~13 MB of base64 — the default request timeout fits metadata, not
      // an audio body, so bound this one call more generously.
      final j = _asMap(await _get('visit/report/$id/audio',
          timeout: const Duration(minutes: 2)));
      final b64 = Wire.string(j, 'audio_bytes');
      if (b64.isEmpty) return null;
      final mime = Wire.string(j, 'audio_mime_type');
      // Base64-decode off the UI isolate: the payload is large, so hand the
      // string to a worker via compute so the decode never janks a frame (the
      // JSON was already parsed by the client on the way in).
      final bytes = await compute(_decodeAudioB64, b64);
      if (bytes.isEmpty) return null;
      final dir = await _audioTempDir();
      final path = '${dir.path}/vr_$id.${_ext(mime)}';
      await File(path).writeAsBytes(bytes, flush: true);
      _audioFiles[id] = path;
      // Bounded: hold at most 4 decoded files so a long browsing session can't
      // pile large temp files without bound. Evict the oldest insertion,
      // best-effort deleting its file (a leftover is harmless).
      if (_audioFiles.length > 4) {
        final oldest = _audioFiles.keys.first;
        final evicted = _audioFiles.remove(oldest);
        if (evicted != null) {
          try {
            await File(evicted).delete();
          } catch (_) {}
        }
      }
      return path;
    } on ApiException {
      return null; // offline / unavailable ⇒ the player shows a disabled state
    } catch (e) {
      developer.log('NexcoreVisitReportsTab: audio decode failed for $id: $e');
      return null;
    }
  }

  // ===========================================================================
  // Home stats — NOT served here. NexcoreReportsRepository answers todayStats/
  // todayVisits from HomeController and never delegates them to this tab, so a
  // call reaching here is a wiring bug worth surfacing loudly.
  // ===========================================================================

  @override
  Future<TodayStats> todayStats() => throw UnimplementedError(
      'Home stats are served by NexcoreReportsRepository via HomeController, not the Reports tab');

  @override
  Future<List<VisitEntry>> todayVisits() => throw UnimplementedError(
      'Home stats are served by NexcoreReportsRepository via HomeController, not the Reports tab');

  // ===========================================================================
  // Small mapping helpers. grpc-gateway JSON omits proto3 zero values, so every
  // read (via [Wire] / the DTOs) defaults rather than throws.
  // ===========================================================================

  static final DateTime _epoch = DateTime.fromMillisecondsSinceEpoch(0);

  String _fallbackName(String id) => id.isEmpty ? '—' : id;

  static String? _emptyToNull(String s) => s.isEmpty ? null : s;

  static Map<String, dynamic> _asMap(Object? v) =>
      v is Map ? Map<String, dynamic>.from(v) : const <String, dynamic>{};

  static List<Map<String, dynamic>> _mapList(Object? v) => v is List
      ? [for (final e in v) if (e is Map) Map<String, dynamic>.from(e)]
      : const [];

  /// VisitReportEdit.field is a plain string enum: text_body | lead_tags | audio.
  static ReportEditField _editField(String v) => switch (v) {
        'lead_tags' => ReportEditField.leadTags,
        'audio' => ReportEditField.audio,
        _ => ReportEditField.textBody,
      };

  /// File extension `just_audio` can infer a decoder from, per the audio mime.
  static String _ext(String mime) {
    final m = mime.toLowerCase();
    if (m.contains('ogg')) return 'ogg';
    if (m.contains('mp4') || m.contains('m4a') || m.contains('aac')) return 'm4a';
    if (m.contains('wav')) return 'wav';
    if (m.contains('mpeg') || m.contains('mp3')) return 'mp3';
    return 'bin';
  }
}

/// Off-isolate base64 decode for [NexcoreVisitReportsTab.reportAudio]. Runs
/// under [compute] so the large decode happens on a worker, never the UI
/// isolate. `base64.normalize` first so a body missing '=' padding still
/// decodes.
Uint8List _decodeAudioB64(String b64) => base64.decode(base64.normalize(b64));

class _RepoChanges extends ChangeNotifier {
  void bump() => notifyListeners();
}
