/// E2E scenarios for #12's invariant-critical claims, against a live NexCore
/// stack (companion to the queue's host-VM unit suites):
///   #27 — idempotency: submitting the SAME key twice yields ONE server row.
///   #28 — an upload interrupted by a kill is recovered on the next launch and
///         completes through the real multipart edge.
///
/// Both run inside ONE testWidgets (one app boot). Integration tests share a
/// process, so a second app.main() re-inits singletons and lets a failed test's
/// async bleed into the next — one boot + sequential scenarios avoids that.
///
/// Same prerequisites/auth as visit_report_submit_test.dart.
///
/// Run:
///   flutter test integration_test/upload_queue_e2e_test.dart --flavor dev \
///     -d `<device>` --dart-define=NEX_CORE_URL=https://app.nexemble.local:9011 \
///     --dart-define=NEX_ENV=dev \
///     --dart-define=E2E_USER=nexadmin --dart-define=E2E_PASS=Realm@admin
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'package:traccar_client/auth_config.dart';
import 'package:traccar_client/auth_service.dart';
import 'package:traccar_client/connectivity_service.dart';
import 'package:traccar_client/main.dart' as app;
import 'package:traccar_client/models/tracking_models.dart';
import 'package:traccar_client/nexemble_reveal.dart';
import 'package:traccar_client/preferences.dart';
import 'package:traccar_client/tracking_api_client.dart';
import 'package:traccar_client/tracking_dto.dart';
import 'package:traccar_client/upload_queue.dart';
import 'package:traccar_client/upload_uploader.dart';

const _user = String.fromEnvironment('E2E_USER', defaultValue: 'e2e-rep');
const _pass = String.fromEnvironment('E2E_PASS', defaultValue: 'Demo12345!');
const _clientSecret = String.fromEnvironment('E2E_CLIENT_SECRET',
    defaultValue: '7JhDTBDoqbcZ7eYMCU79hGuoxB1i89GL');

Future<({String access, String refresh, String? id, DateTime expiry})>
    _mintSession() async {
  final client = HttpClient()
    ..badCertificateCallback = ((cert, host, port) => true);
  try {
    final req = await client.postUrl(Uri.parse(
        '${AuthConfig.nexCoreUrl}/idp/realms/default/protocol/openid-connect/token'));
    req.headers.contentType =
        ContentType('application', 'x-www-form-urlencoded');
    req.write(Uri(queryParameters: {
      'grant_type': 'password',
      'client_id': 'default-client',
      'client_secret': _clientSecret,
      'username': _user,
      'password': _pass,
      'scope': 'openid',
    }).query);
    final resp = await req.close();
    final body = await resp.transform(utf8.decoder).join();
    if (resp.statusCode != 200) fail('token mint failed: ${resp.statusCode} $body');
    final j = jsonDecode(body) as Map<String, dynamic>;
    return (
      access: j['access_token'] as String,
      refresh: (j['refresh_token'] as String?) ?? '',
      id: j['id_token'] as String?,
      expiry: DateTime.now()
          .add(Duration(seconds: (j['expires_in'] as num?)?.toInt() ?? 60)),
    );
  } finally {
    client.close(force: true);
  }
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() cond, {
  Duration timeout = const Duration(seconds: 60),
  required String reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting for: $reason');
    await tester.pump(const Duration(milliseconds: 200));
  }
}

/// Polls an async predicate, treating a thrown call (e.g. a transient 401 right
/// after seedSession) as "not yet" rather than a failure.
Future<void> _pumpUntilAsync(
  WidgetTester tester,
  Future<bool> Function() cond, {
  Duration timeout = const Duration(seconds: 60),
  required String reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (true) {
    bool ok;
    try {
      ok = await cond();
    } catch (_) {
      ok = false;
    }
    if (ok) return;
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting for: $reason');
    await tester.pump(const Duration(milliseconds: 300));
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  final q = UploadQueue.instance;
  final uploader = UploadUploader.instance;

  // Server-side count of the rep's reports carrying this exact note (a unique
  // per-run marker — more reliable than a synthetic customer id).
  Future<int> reportsWithNote(String note) async {
    final raw = await TrackingApiClient.instance
        .get('visit/report', query: {'pageSize': 500});
    final list = (raw is Map) ? raw['reports'] : null;
    if (list is! List) return 0;
    return list
        .whereType<Map>()
        .map((m) => VisitReportDto.fromJson(m.cast<String, dynamic>()))
        .where((r) => r.textBody == note)
        .length;
  }

  testWidgets(
    'offline queue e2e: idempotency (#27) + interrupted-upload recovery (#28)',
    timeout: const Timeout(Duration(minutes: 5)),
    (tester) async {
      // ── boot once ────────────────────────────────────────────────────────
      await app.main();
      await tester.pump(const Duration(seconds: 1));
      await Preferences.instance.setBool(Preferences.onboardingComplete, true);
      await Preferences.instance.setBool(Preferences.deviceRegistered, true);
      final s = await _mintSession();
      await AuthService.instance.seedSession(
          access: s.access, refresh: s.refresh, id: s.id, expiry: s.expiry);
      await _pumpUntil(tester, () => find.byType(NexembleReveal).evaluate().isEmpty,
          timeout: const Duration(seconds: 15), reason: 'reveal to finish');
      ConnectivityService.instance.setOnlineForTest(true);

      // ── #27 idempotency: same key twice → one server row ─────────────────
      {
        final note = 'idem-probe-${DateTime.now().millisecondsSinceEpoch}';
        final key = ReportDraft.newIdempotencyKey();
        ReportDraft draft() => ReportDraft(
              customerId: 'idem-customer',
              leadIds: const [],
              notes: note,
              idempotencyKey: key, // SAME key both times
            );

        // First submit — the real uploader drains it to a 200; poll (tolerantly)
        // until the row shows up server-side.
        await q.enqueue(draft(), customerName: 'Idem Test');
        await _pumpUntil(tester, () => q.items.isEmpty,
            timeout: const Duration(seconds: 60), reason: 'first upload to drain');
        await _pumpUntilAsync(tester, () async => await reportsWithNote(note) == 1,
            reason: 'the first report to appear server-side');

        // Second submit — same key. The server must dedup, not add a row.
        await q.enqueue(draft(), customerName: 'Idem Test');
        await _pumpUntil(tester, () => q.items.isEmpty,
            timeout: const Duration(seconds: 60),
            reason: 'second (dedup) upload to drain');

        await tester.pump(const Duration(seconds: 2)); // settle
        expect(await reportsWithNote(note), 1,
            reason: 'a reused idempotency key must not create a duplicate row');
        debugPrint('[e2e] #27 OK — one server row for the reused key');
      }

      // ── #28 interrupted upload recovers on restart and completes ──────────
      {
        // Make the app's uploader inert so we stage the interruption precisely
        // (drops its listeners; keeps the real VisitReportClient as its hook).
        uploader.resetForTest();

        final sample = (await rootBundle.load('assets/audio/sample_note.wav'))
            .buffer
            .asUint8List();
        final tmp = await getTemporaryDirectory();
        final f =
            File('${tmp.path}/rec_${DateTime.now().microsecondsSinceEpoch}.wav');
        await f.writeAsBytes(sample);
        final key = ReportDraft.newIdempotencyKey();

        await q.enqueue(
          ReportDraft(
            customerId: 'recover-customer',
            leadIds: const [],
            notes: 'recovery probe ${DateTime.now().toIso8601String()}',
            audio: ReportAudio(
              path: f.path,
              mimeType: 'audio/wav',
              duration: const Duration(seconds: 4),
              sizeBytes: sample.length,
            ),
            idempotencyKey: key,
          ),
          customerName: 'Recover Test',
        );

        // Simulate a kill mid-POST: force `uploading`, then re-init the queue
        // from disk — the app-relaunch recovery path.
        await q.markUploading(key);
        await q.closeForTest();
        await q.init(); // real device paths → recovery requeues the uploading row

        final recovered = q.items.firstWhere((i) => i.idempotencyKey == key);
        expect(recovered.status, QueueStatus.queued);
        expect(recovered.attemptCount, 1,
            reason: 'the interrupted attempt is counted');

        // Resume the real drain → the recovered item uploads through the real edge.
        ConnectivityService.instance.setOnlineForTest(true);
        uploader.start();
        await _pumpUntil(
          tester,
          () => q.items.where((i) => i.idempotencyKey == key).isEmpty,
          timeout: const Duration(seconds: 90),
          reason: 'the recovered upload to complete via the real edge',
        );
        debugPrint('[e2e] #28 OK — recovered upload completed for $key');
      }
    },
  );
}
