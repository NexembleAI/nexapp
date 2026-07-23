import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:traccar_client/crm_name_resolver.dart';
import 'package:traccar_client/models/tracking_models.dart';
import 'package:traccar_client/nexcore_visit_reports.dart';
import 'package:traccar_client/tracking_api_client.dart';

/// A recorded call to the injected get/put — path + the query/body it carried.
class _Call {
  final String path;
  final Map<String, dynamic>? query;
  final Map<String, dynamic>? body;
  const _Call(this.path, {this.query, this.body});
}

/// Injected get/put fakes for [NexcoreVisitReportsTab]. Unlike the raw HTTP
/// client, main's [TrackingApiClient] returns ALREADY-DECODED JSON (a Map/List)
/// and THROWS [ApiException] on failure — so the handler returns Maps/Lists and
/// throws to simulate 503/offline. Every call is recorded so query/body/scoping
/// can be asserted without a socket.
class _FakeApi {
  _FakeApi(this._handler);

  final Object? Function(String method, String path, Map<String, dynamic>? query,
      Map<String, dynamic>? body) _handler;

  final List<_Call> gets = [];
  final List<_Call> puts = [];

  Future<Object?> get(String path,
      {Map<String, dynamic>? query, Duration? timeout}) async {
    gets.add(_Call(path, query: query));
    return _handler('GET', path, query, null);
  }

  Future<Object?> put(String path, {Map<String, dynamic>? body}) async {
    puts.add(_Call(path, body: body));
    return _handler('PUT', path, null, body);
  }
}

/// A canned name resolver returning fixed maps regardless of the requested ids
/// (an omitted id → CrmNames.customer/lead returns null → the caller falls back
/// to the raw id). Mirrors [CrmNameResolver.resolve]'s never-throws contract.
Future<CrmNames> Function({Iterable<String> customerIds, Iterable<String> leadIds})
    _names({
  Map<String, String> customers = const {},
  Map<String, String> leads = const {},
}) =>
        ({Iterable<String> customerIds = const [], Iterable<String> leadIds = const []}) async =>
            CrmNames(customers: customers, leads: leads);

/// A visit-report JSON blob as grpc-gateway emits it (camelCase, enum as string
/// name, RFC3339 timestamps). Proto3 zero values are OMITTED by the gateway —
/// pass null to leave a field out and exercise the client's defaulting. NOTE:
/// hasAudio keys off audioMimeType (per [VisitReportDto]), so a no-audio row
/// omits audioMimeType, not just audioSizeBytes.
Map<String, dynamic> _reportJson({
  String id = 'r1',
  String customerId = '55',
  String userId = 'user-1',
  String? textBody = 'met the buyer',
  String? status = 'REPORT_STATUS_READY',
  int? audioSizeBytes = 2048,
  int? audioDurationS = 26,
  String? audioMimeType = 'audio/ogg; codecs=opus',
  String? transcript = 'walked the depot',
  bool? geofencePresent = true,
  int? version = 2,
  List<String>? leadIds = const ['l9'],
  String createdAt = '2026-07-23T12:04:00Z',
}) =>
    {
      'id': id,
      'customerId': customerId,
      if (userId.isNotEmpty) 'userId': userId,
      if (textBody != null) 'textBody': textBody,
      if (status != null) 'status': status,
      if (audioSizeBytes != null) 'audioSizeBytes': audioSizeBytes,
      if (audioDurationS != null) 'audioDurationS': audioDurationS,
      if (audioMimeType != null) 'audioMimeType': audioMimeType,
      if (transcript != null) 'transcript': transcript,
      if (geofencePresent != null) 'geofencePresent': geofencePresent,
      if (version != null) 'version': version,
      if (leadIds != null) 'leadIds': leadIds,
      'createdAt': createdAt,
    };

/// A local upload-queue item — exercises the synthetic overlay.
QueuedReport _queued({
  String idempotencyKey = 'key-1',
  String customerId = 'cust-9',
  String customerName = 'Acme',
  List<String> leadIds = const ['55', '56'],
  String notes = 'met the buyer',
  bool audio = false,
  DateTime? createdAt,
}) =>
    QueuedReport(
      idempotencyKey: idempotencyKey,
      customerId: customerId,
      customerName: customerName,
      leadIds: leadIds,
      notes: notes,
      audioPath: audio ? '$idempotencyKey.ogg' : null,
      audioMime: audio ? 'audio/ogg; codecs=opus' : null,
      audioSizeBytes: audio ? 2048 : null,
      status: QueueStatus.queued,
      createdAt: createdAt ?? DateTime(2026, 7, 22),
    );

void main() {
  // compute (base64 decode off-isolate) needs the binding in the audio test.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('reports() list mapping + name resolution', () {
    test('maps VisitReport -> ReportEntry, resolving names and defaulting '
        'proto-omitted fields', () async {
      final api = _FakeApi((m, p, q, b) {
        if (p == 'visit/report') {
          return {
            'reports': [
              _reportJson(id: 'r1', customerId: '55'),
              _reportJson(
                id: 'r2',
                customerId: '56',
                audioMimeType: null, // omitted => hasAudio false (mime-keyed)
                audioSizeBytes: null,
                textBody: null, // omitted => no notes
                status: null, // omitted => UNSPECIFIED => submitted
                geofencePresent: null, // omitted => false
              ),
            ],
          };
        }
        fail('unexpected GET $p');
      });
      final repo = NexcoreVisitReportsTab(
        get: api.get,
        resolveNames: _names(
            customers: {'55': 'Meridian Logistics', '56': 'Brightwell Foods'}),
        currentUserId: () async => 'user-1',
      );

      final rows = await repo.reports();
      expect(rows, hasLength(2));

      final r1 = rows[0];
      expect(r1.id, 'r1');
      expect(r1.customerName, 'Meridian Logistics');
      expect(r1.hasAudio, isTrue);
      expect(r1.hasNotes, isTrue);
      expect(r1.status, ReportStatus.ready);
      expect(r1.geofencePresent, isTrue);

      final r2 = rows[1];
      expect(r2.customerName, 'Brightwell Foods');
      expect(r2.hasAudio, isFalse); // omitted audioMimeType
      expect(r2.hasNotes, isFalse);
      expect(r2.status, ReportStatus.submitted); // omitted status default
      expect(r2.geofencePresent, isFalse); // omitted bool default
    });

    test('falls back to the raw customer id when the resolver omits the name',
        () async {
      final api = _FakeApi((m, p, q, b) => {
            'reports': [_reportJson(id: 'r1', customerId: '55')],
          });
      final repo = NexcoreVisitReportsTab(
        get: api.get,
        resolveNames: _names(), // resolves nothing
      );

      final rows = await repo.reports();
      expect(rows.single.customerName, '55'); // fell back to the id
    });

    test('scopes the list to the caller (?userId) when the id is known',
        () async {
      final api = _FakeApi((m, p, q, b) => {'reports': [_reportJson()]});
      final repo = NexcoreVisitReportsTab(
        get: api.get,
        resolveNames: _names(),
        currentUserId: () async => 'user-1',
      );

      await repo.reports();
      final call = api.gets.firstWhere((c) => c.path == 'visit/report');
      expect(call.query?['userId'], 'user-1');
    });

    test('omits the userId query when the caller is unknown', () async {
      final api = _FakeApi((m, p, q, b) => {'reports': [_reportJson()]});
      final repo = NexcoreVisitReportsTab(
        get: api.get,
        resolveNames: _names(),
        currentUserId: () async => null,
      );

      await repo.reports();
      final call = api.gets.firstWhere((c) => c.path == 'visit/report');
      expect(call.query == null || !call.query!.containsKey('userId'), isTrue);
    });

    test('offline (ApiException) returns the last-known list, not a crash',
        () async {
      var online = true;
      final api = _FakeApi((m, p, q, b) {
        if (!online) throw const ApiException(ApiErrorKind.retryable);
        return {'reports': [_reportJson(id: 'r1', customerId: '55')]};
      });
      final repo = NexcoreVisitReportsTab(
        get: api.get,
        resolveNames: _names(customers: {'55': 'Meridian'}),
      );

      final first = await repo.reports();
      expect(first, hasLength(1));

      online = false;
      final second = await repo.reports();
      expect(second, hasLength(1)); // served from cache
      expect(second.single.customerName, 'Meridian');
    });

    test(
        'synthetic overlay: a just-uploaded report shows on a failed fetch, '
        'then drops once a real fetch succeeds', () async {
      var online = true;
      final api = _FakeApi((m, p, q, b) {
        if (!online) throw const ApiException(ApiErrorKind.retryable);
        return {'reports': [_reportJson(id: 'r1', customerId: '55')]};
      });
      final repo = NexcoreVisitReportsTab(
        get: api.get,
        resolveNames: _names(customers: {'55': 'Meridian'}),
      );

      // Prime the last-known list so the overlay has something to sit on.
      await repo.reports();

      repo.reportUploaded(
          _queued(idempotencyKey: 'key-1', customerName: 'Northwind Traders'));
      online = false;

      final offline = await repo.reports();
      final synthetic =
          offline.firstWhere((e) => e.customerName == 'Northwind Traders');
      expect(synthetic.id, isNull); // not tappable until the real row lands
      expect(synthetic.status, ReportStatus.submitted);

      // A successful fetch necessarily includes the real row — the synthetic
      // drops and only server rows remain.
      online = true;
      final refreshed = await repo.reports();
      expect(refreshed.any((e) => e.customerName == 'Northwind Traders'),
          isFalse);
      expect(refreshed.map((e) => e.id), everyElement(isNotNull));
    });
  });

  group('reportDetail()', () {
    _FakeApi detailApi({
      String authorId = 'user-1',
      List<String> leadIds = const ['l9'],
    }) =>
        _FakeApi((m, p, q, b) {
          if (p == 'visit/report/r1') {
            return _reportJson(
                id: 'r1', customerId: '55', userId: authorId, leadIds: leadIds);
          }
          if (p == 'visit/report/r1/edits') {
            return {
              'edits': [
                {
                  'version': 2,
                  'field': 'text_body',
                  'editedAt': '2026-07-23T11:02:00Z',
                  'editedBy': 'user-1',
                },
                {
                  'version': 1,
                  'field': 'lead_tags',
                  'editedAt': '2026-07-23T10:15:00Z',
                },
              ],
            };
          }
          if (p == 'crm/customer/55/leads') {
            return {
              'leads': [
                {'leadId': 'l6', 'name': 'Telematics Add-on', 'customerId': '55'},
                {'leadId': 'l7', 'name': 'Depot Automation', 'customerId': '55'},
              ],
            };
          }
          fail('unexpected GET $p');
        });

    test('maps report + edits + lead options + resolved names', () async {
      final api = detailApi();
      final repo = NexcoreVisitReportsTab(
        get: api.get,
        resolveNames: _names(
          customers: {'55': 'Meridian Logistics'},
          leads: {'l9': 'Cold-chain Upgrade'},
        ),
        currentUserId: () async => 'user-1',
      );
      final d = await repo.reportDetail('r1');

      expect(d.id, 'r1');
      expect(d.customerName, 'Meridian Logistics');
      expect(d.notes, 'met the buyer');
      expect(d.transcript, 'walked the depot');
      expect(d.audioPresent, isTrue);
      expect(d.version, 2);
      expect(d.leadIds, ['l9']);

      // Edit-field + version mapping.
      expect(d.edits, hasLength(2));
      expect(d.edits[0].field, ReportEditField.textBody);
      expect(d.edits[0].version, 2);
      expect(d.edits[1].field, ReportEditField.leadTags);

      // Lead options = customer's open leads PLUS the tagged-but-closed l9,
      // resolved via the name fake so it still renders as a selected pill.
      final byId = {for (final l in d.leadOptions) l.id: l.title};
      expect(byId['l6'], 'Telematics Add-on');
      expect(byId['l7'], 'Depot Automation');
      expect(byId['l9'], 'Cold-chain Upgrade'); // tagged, not in customer leads
    });

    test('editable is true for the author', () async {
      final repo = NexcoreVisitReportsTab(
        get: detailApi(authorId: 'user-1').get,
        resolveNames: _names(),
        currentUserId: () async => 'user-1',
      );
      expect((await repo.reportDetail('r1')).editable, isTrue);
    });

    test('editable is false for a non-author (manager view)', () async {
      final repo = NexcoreVisitReportsTab(
        get: detailApi(authorId: 'someone-else').get,
        resolveNames: _names(),
        currentUserId: () async => 'user-1',
      );
      expect((await repo.reportDetail('r1')).editable, isFalse);
    });

    test('editable defaults true when the current user is unknown', () async {
      final repo = NexcoreVisitReportsTab(
        get: detailApi(authorId: 'someone-else').get,
        resolveNames: _names(),
        currentUserId: () async => null,
      );
      expect((await repo.reportDetail('r1')).editable, isTrue);
    });
  });

  group('reportStatus() poll', () {
    test('returns just status + transcript from GetVisitReport', () async {
      final api = _FakeApi((m, p, q, b) {
        expect(p, 'visit/report/r1');
        return _reportJson(
            id: 'r1', status: 'REPORT_STATUS_TRANSCRIBING', transcript: null);
      });
      final repo = NexcoreVisitReportsTab(get: api.get, resolveNames: _names());
      final upd = await repo.reportStatus('r1');
      expect(upd.status, ReportStatus.transcribing);
      expect(upd.transcript, isNull); // omitted transcript => null
    });
  });

  group('updateReport()', () {
    test('PUTs textBody + leadIds (+ tenantId/id) and bumps changes', () async {
      var bumped = false;
      final api = _FakeApi((m, p, q, b) => _reportJson(version: 3));
      final repo = NexcoreVisitReportsTab(
          get: api.get, put: api.put, resolveNames: _names());
      repo.changes.addListener(() => bumped = true);

      await repo.updateReport('r1', notes: 'edited', leadIds: ['l6', 'l7']);

      expect(api.puts, hasLength(1));
      final call = api.puts.single;
      expect(call.path, 'visit/report/r1');
      expect(call.body?['id'], 'r1');
      expect(call.body?['textBody'], 'edited');
      expect(call.body?['leadIds'], ['l6', 'l7']);
      expect(call.body?['tenantId'], isA<int>());
      expect(bumped, isTrue);
    });

    test('a failed PUT throws ApiException (surfaced to the caller)', () async {
      final api = _FakeApi((m, p, q, b) {
        if (m == 'PUT') throw const ApiException(ApiErrorKind.retryable);
        return _reportJson();
      });
      final repo = NexcoreVisitReportsTab(
          get: api.get, put: api.put, resolveNames: _names());
      expect(
        () => repo.updateReport('r1', notes: 'x', leadIds: const []),
        throwsA(isA<ApiException>()),
      );
    });
  });

  group('reportAudio()', () {
    late Directory tmp;
    setUp(() async => tmp = await Directory.systemTemp.createTemp('vr_audio_t'));
    tearDown(() async => tmp.delete(recursive: true));

    test('decodes base64 -> temp file and caches the path', () async {
      final bytes = List<int>.generate(1024, (i) => (i * 5 + 3) % 256);
      final b64 = base64.encode(bytes);
      var audioCalls = 0;
      final api = _FakeApi((m, p, q, b) {
        if (p == 'visit/report/r1/audio') {
          audioCalls++;
          return {
            'visitReportId': 'r1',
            'audioBytes': b64,
            'audioMimeType': 'audio/ogg; codecs=opus',
            'audioDurationS': 26,
          };
        }
        fail('unexpected GET $p');
      });
      final repo = NexcoreVisitReportsTab(
          get: api.get, resolveNames: _names(), audioTempDir: () async => tmp);

      final path = await repo.reportAudio('r1');
      expect(path, isNotNull);
      expect(path, endsWith('.ogg'));
      expect(await File(path!).readAsBytes(), bytes); // decoded intact

      // Second call is served from cache — no second fetch.
      final again = await repo.reportAudio('r1');
      expect(again, path);
      expect(audioCalls, 1);
    });

    test('null when audio bytes are empty', () async {
      final api = _FakeApi((m, p, q, b) => {'visitReportId': 'r1'});
      final repo = NexcoreVisitReportsTab(
          get: api.get, resolveNames: _names(), audioTempDir: () async => tmp);
      expect(await repo.reportAudio('r1'), isNull);
    });

    test('null when unavailable (503 / offline)', () async {
      final api =
          _FakeApi((m, p, q, b) => throw const ApiException(ApiErrorKind.unavailable));
      final repo = NexcoreVisitReportsTab(
          get: api.get, resolveNames: _names(), audioTempDir: () async => tmp);
      expect(await repo.reportAudio('r1'), isNull);
    });

    test('bounded cache: evicts + deletes the oldest decoded file past 4',
        () async {
      final bytes = List<int>.generate(64, (i) => i % 256);
      final b64 = base64.encode(bytes);
      final api = _FakeApi((m, p, q, b) => {
            'audioBytes': b64,
            'audioMimeType': 'audio/ogg; codecs=opus',
          });
      final repo = NexcoreVisitReportsTab(
          get: api.get, resolveNames: _names(), audioTempDir: () async => tmp);

      final paths = <String>[];
      for (final id in ['a', 'b', 'c', 'd', 'e']) {
        paths.add((await repo.reportAudio(id))!);
      }
      // 5 fetched, cap is 4 → the oldest (a) is evicted and its file deleted.
      expect(await File(paths.first).exists(), isFalse);
      expect(await File(paths.last).exists(), isTrue);
    });
  });
}
