import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:traccar_client/models/tracking_models.dart';
import 'package:traccar_client/upload_uploader.dart';
import 'package:traccar_client/visit_report_client.dart';

/// Records every send and replays a scripted list of outcomes (a record to
/// return, or a throw). Lets the classification and 401 logic be exercised
/// without a socket.
class _FakeTransport implements VisitReportTransport {
  _FakeTransport(this._handlers);

  final List<(int, String) Function()> _handlers;

  int calls = 0;
  final List<String> tokens = [];
  final List<Map<String, dynamic>> metadata = [];
  final List<String?> audioPaths = [];
  final List<String?> audioMimes = [];

  @override
  Future<(int, String)> send({
    required Uri uri,
    required String token,
    required Map<String, dynamic> metadata,
    String? audioFilePath,
    String? audioMime,
  }) async {
    tokens.add(token);
    this.metadata.add(metadata);
    audioPaths.add(audioFilePath);
    audioMimes.add(audioMime);
    final handler = _handlers[calls];
    calls++;
    return handler();
  }
}

QueuedReport _report({
  String idempotencyKey = 'key-1',
  String customerId = 'cust-9',
  String notes = 'met the buyer',
  List<String> leadIds = const ['55', '56'],
  double? latitude = 12.97,
  double? longitude = 77.59,
  String? audioPath,
  String? audioMime,
  int? audioDurationMs,
}) =>
    QueuedReport(
      idempotencyKey: idempotencyKey,
      customerId: customerId,
      customerName: 'Acme',
      leadIds: leadIds,
      notes: notes,
      latitude: latitude,
      longitude: longitude,
      accuracyMeters: 8,
      audioPath: audioPath,
      audioMime: audioMime,
      audioDurationMs: audioDurationMs,
      audioSizeBytes: audioPath == null ? null : 2048,
      status: QueueStatus.queued,
      createdAt: DateTime(2026, 7, 22),
    );

/// Builds a client whose transport, auth, and audio-path resolution are all
/// injected, so nothing touches dart:io or the singletons.
VisitReportClient _client(
  _FakeTransport transport, {
  String? Function()? accessToken,
  String? Function()? refreshToken,
  void Function()? onRejected,
}) =>
    VisitReportClient(
      transport: transport,
      accessToken: () async => (accessToken ?? () => 'tok1')(),
      refreshToken: () async => (refreshToken ?? () => 'tok2')(),
      markSessionRejected: onRejected ?? () {},
      audioPathResolver: (item) =>
          item.audioPath == null ? null : '/queue_audio/${item.audioPath}',
      endpoint: Uri.parse('https://example.test/report'),
    );

void main() {
  group('classify', () {
    test('200 is success', () {
      expect(VisitReportClient.classify(200, '{"id":"r1"}'),
          UploadOutcome.success);
    });

    test('gRPC code wins over HTTP status', () {
      // A 400 carrying Internal(13) is retryable, not terminal.
      expect(VisitReportClient.classify(400, '{"code":13}'),
          UploadOutcome.retryable);
    });

    test('gRPC codes map correctly', () {
      expect(VisitReportClient.classify(400, '{"code":3}'),
          UploadOutcome.terminal); // InvalidArgument
      expect(VisitReportClient.classify(404, '{"code":5}'),
          UploadOutcome.terminal); // NotFound
      expect(VisitReportClient.classify(403, '{"code":7}'),
          UploadOutcome.terminal); // PermissionDenied
      expect(VisitReportClient.classify(413, '{"code":8}'),
          UploadOutcome.terminal); // ResourceExhausted
      expect(VisitReportClient.classify(401, '{"code":16}'),
          UploadOutcome.unauthenticated);
      expect(VisitReportClient.classify(500, '{"code":13}'),
          UploadOutcome.retryable); // Internal — F4 same-key race
      expect(VisitReportClient.classify(503, '{"code":14}'),
          UploadOutcome.retryable); // Unavailable
    });

    test('over-cap audio: shipped edge returns 413 -> terminal', () {
      // The real edge (nexcore@e59f1193) returns HTTP 413 for an over-cap
      // recording (tracking_upload.go + ACEF body cap), with a bare {"error":...}
      // body. This is THE over-cap path; 413 must be terminal or the queue burns
      // all 11 attempts re-streaming a ~10 MiB payload.
      expect(VisitReportClient.classify(413, '{"error":"audio exceeds the cap"}'),
          UploadOutcome.terminal);
    });

    test('code-first still wins if a {"code":8} body ever appears (defensive)', () {
      // The multipart edge emits {"error":...} only, but the gateway-delegated
      // path could carry a gRPC code; code-first keeps that unambiguous.
      expect(VisitReportClient.classify(429, '{"code":8,"message":"audio too big"}'),
          UploadOutcome.terminal);
    });

    test('code-less 429 (infra rate-limit) is retryable', () {
      expect(VisitReportClient.classify(429, '{"error":"rate limited"}'),
          UploadOutcome.retryable);
    });

    test('bare {"error":...} body (no code) falls back to HTTP status', () {
      // The portability-style edge emits {"error":...} with no code; the parser
      // must not crash and must use the status.
      expect(VisitReportClient.classify(400, '{"error":"bad request"}'),
          UploadOutcome.terminal);
      expect(VisitReportClient.classify(503, '{"error":"down"}'),
          UploadOutcome.retryable);
    });

    test('HTTP-status fallback when no gRPC code', () {
      expect(VisitReportClient.classify(401, 'nope'),
          UploadOutcome.unauthenticated);
      expect(VisitReportClient.classify(400, ''), UploadOutcome.terminal);
      expect(VisitReportClient.classify(403, ''), UploadOutcome.terminal);
      expect(VisitReportClient.classify(404, ''), UploadOutcome.terminal);
      expect(VisitReportClient.classify(413, ''), UploadOutcome.terminal);
      expect(VisitReportClient.classify(408, ''), UploadOutcome.retryable);
      expect(VisitReportClient.classify(429, ''), UploadOutcome.retryable);
      expect(VisitReportClient.classify(500, ''), UploadOutcome.retryable);
      expect(VisitReportClient.classify(502, ''), UploadOutcome.retryable);
    });

    test('unknown 4xx defaults to terminal', () {
      expect(VisitReportClient.classify(418, ''), UploadOutcome.terminal);
    });
  });

  group('buildMetadata', () {
    test('camelCase fields, numeric tenant, position, leads', () {
      final m = VisitReportClient.buildMetadata(_report());
      expect(m['tenantId'], 2);
      expect(m['tenantId'], isA<int>());
      expect(m['idempotencyKey'], 'key-1');
      expect(m['customerId'], 'cust-9');
      expect(m['textBody'], 'met the buyer');
      expect(m['leadIds'], ['55', '56']);
      expect(m['reportPosition'], {'latitude': 12.97, 'longitude': 77.59});
    });

    test('rounds audio duration ms -> int seconds and sets mime', () {
      final m = VisitReportClient.buildMetadata(_report(
        audioPath: 'key-1.ogg',
        audioMime: 'audio/ogg; codecs=opus',
        audioDurationMs: 26600, // -> 27
      ));
      expect(m['audioDurationS'], 27);
      expect(m['audioMimeType'], 'audio/ogg; codecs=opus');
    });

    test('absent audio omits the three audio fields', () {
      final m = VisitReportClient.buildMetadata(_report());
      expect(m.containsKey('audioMimeType'), isFalse);
      expect(m.containsKey('audioDurationS'), isFalse);
      expect(m.containsKey('audioBytes'), isFalse);
    });

    test('empty text / leads / absent position are omitted', () {
      final m = VisitReportClient.buildMetadata(_report(
        notes: '',
        leadIds: const [],
        latitude: null,
        longitude: null,
      ));
      expect(m.containsKey('textBody'), isFalse);
      expect(m.containsKey('leadIds'), isFalse);
      expect(m.containsKey('reportPosition'), isFalse);
    });
  });

  group('submit', () {
    test('200 -> success', () async {
      final t = _FakeTransport([() => (200, '{"id":"r1"}')]);
      expect(await _client(t).submit(_report()), UploadOutcome.success);
      expect(t.calls, 1);
      expect(t.tokens.single, 'tok1');
    });

    test('terminal 400 -> terminal, no retry', () async {
      final t = _FakeTransport([() => (400, '{"code":3}')]);
      expect(await _client(t).submit(_report()), UploadOutcome.terminal);
      expect(t.calls, 1);
    });

    test('thrown SocketException -> retryable', () async {
      final t = _FakeTransport([() => throw const SocketException('down')]);
      expect(await _client(t).submit(_report()), UploadOutcome.retryable);
    });

    test('thrown TimeoutException -> retryable', () async {
      final t = _FakeTransport([() => throw TimeoutException('slow')]);
      expect(await _client(t).submit(_report()), UploadOutcome.retryable);
    });

    test('audio present -> resolved path + mime handed to the transport',
        () async {
      final t = _FakeTransport([() => (200, '{}')]);
      await _client(t).submit(_report(
        audioPath: 'key-1.ogg',
        audioMime: 'audio/ogg; codecs=opus',
        audioDurationMs: 26000,
      ));
      expect(t.audioPaths.single, '/queue_audio/key-1.ogg');
      expect(t.audioMimes.single, 'audio/ogg; codecs=opus');
    });

    test('text-only -> no audio path handed to the transport', () async {
      final t = _FakeTransport([() => (200, '{}')]);
      await _client(t).submit(_report());
      expect(t.audioPaths.single, isNull);
    });

    test('401 then 200 -> success after one forced refresh', () async {
      var refreshes = 0;
      var rejects = 0;
      final t = _FakeTransport([
        () => (401, '{"code":16}'),
        () => (200, '{"id":"r1"}'),
      ]);
      final c = _client(
        t,
        refreshToken: () {
          refreshes++;
          return 'tok2';
        },
        onRejected: () => rejects++,
      );
      expect(await c.submit(_report()), UploadOutcome.success);
      expect(t.calls, 2);
      expect(t.tokens, ['tok1', 'tok2']); // retry used the refreshed token
      expect(refreshes, 1);
      expect(rejects, 0);
    });

    test('401 twice -> unauthenticated and session marked rejected', () async {
      var rejects = 0;
      final t = _FakeTransport([
        () => (401, '{"code":16}'),
        () => (401, '{"code":16}'),
      ]);
      final c = _client(t, onRejected: () => rejects++);
      expect(await c.submit(_report()), UploadOutcome.unauthenticated);
      expect(t.calls, 2);
      expect(rejects, 1);
    });

    test('no access token -> unauthenticated, transport untouched', () async {
      var rejects = 0;
      final t = _FakeTransport([() => (200, '{}')]);
      final c = _client(t, accessToken: () => null, onRejected: () => rejects++);
      expect(await c.submit(_report()), UploadOutcome.unauthenticated);
      expect(t.calls, 0);
      expect(rejects, 1);
    });

    test('401 then refresh fails -> unauthenticated, no double-reject',
        () async {
      var rejects = 0;
      final t = _FakeTransport([() => (401, '{"code":16}')]);
      final c = _client(
        t,
        refreshToken: () => null, // logout() already flipped authState
        onRejected: () => rejects++,
      );
      expect(await c.submit(_report()), UploadOutcome.unauthenticated);
      expect(t.calls, 1);
      expect(rejects, 0);
    });
  });

  // Exercises the REAL dart:io transport against an in-process HttpServer — the
  // multipart framing and the Content-Length arithmetic, the highest-risk code
  // in the file. A single-byte length error here would silently corrupt every
  // upload, and every submit test above uses a fake, so nothing else covers it.
  group('HttpMultipartVisitReportTransport (real framing)', () {
    late HttpServer server;
    late Uri endpoint;
    late List<int> receivedBody;
    late int contentLengthHeader;
    late String contentTypeHeader;
    late String authHeader;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      endpoint = Uri.parse('http://127.0.0.1:${server.port}/report');
      server.listen((req) async {
        final chunks = await req.toList();
        receivedBody = chunks.expand((c) => c).toList();
        contentLengthHeader = req.headers.contentLength;
        contentTypeHeader = req.headers.value('content-type') ?? '';
        authHeader = req.headers.value('authorization') ?? '';
        req.response.statusCode = 200;
        req.response.write('{"id":"r1"}');
        await req.response.close();
      });
    });

    tearDown(() => server.close(force: true));

    test('no audio: Content-Length matches body, well-formed, no audio part',
        () async {
      final (status, _) = await const HttpMultipartVisitReportTransport().send(
        uri: endpoint,
        token: 'tok-xyz',
        metadata: const {'tenantId': 2, 'idempotencyKey': 'k1'},
        audioFilePath: null,
        audioMime: null,
      );
      expect(status, 200);
      // The promised length must equal the bytes actually received.
      expect(contentLengthHeader, receivedBody.length);
      expect(authHeader, 'Bearer tok-xyz');
      expect(contentTypeHeader, startsWith('multipart/form-data; boundary='));

      final text = utf8.decode(receivedBody);
      expect(text, contains('name="report"'));
      expect(text, contains('"idempotencyKey":"k1"'));
      expect(text, isNot(contains('name="audio"')));
      // Terminates with the closing boundary delimiter.
      expect(text.trimRight(), endsWith('--'));
    });

    test('with audio: Content-Length matches, raw bytes intact, mime in header',
        () async {
      final dir = await Directory.systemTemp.createTemp('vr_audio');
      addTearDown(() => dir.delete(recursive: true));
      // A distinctive byte pattern incl. bytes that must survive verbatim.
      final audio = List<int>.generate(5000, (i) => (i * 7 + 13) % 256);
      final file = File('${dir.path}/note.ogg');
      await file.writeAsBytes(audio);

      final (status, _) = await const HttpMultipartVisitReportTransport().send(
        uri: endpoint,
        token: 'tok',
        metadata: const {'tenantId': 2, 'idempotencyKey': 'k2'},
        audioFilePath: file.path,
        audioMime: 'audio/ogg; codecs=opus',
      );
      expect(status, 200);
      // The arithmetic must account for head + audio-part header + file + tail.
      expect(contentLengthHeader, receivedBody.length);

      final text = latin1.decode(receivedBody); // byte-preserving view for search
      expect(text, contains('name="audio"; filename="audio"'));
      expect(text, contains('Content-Type: audio/ogg; codecs=opus'));
      // The exact audio bytes appear intact in the body (streamed, not mangled).
      expect(_indexOfBytes(receivedBody, audio), greaterThanOrEqualTo(0));
    });
  });
}

/// First index where [needle] appears as a contiguous sublist of [haystack],
/// or -1. Used to assert the streamed audio bytes survive verbatim.
int _indexOfBytes(List<int> haystack, List<int> needle) {
  if (needle.isEmpty) return 0;
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var match = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        match = false;
        break;
      }
    }
    if (match) return i;
  }
  return -1;
}
