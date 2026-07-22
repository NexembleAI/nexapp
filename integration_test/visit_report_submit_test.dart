/// E2E scenario 3 — file a visit report and watch it upload through the REAL
/// `VisitReportClient` (multipart) against a live NexCore stack.
///
/// This is a LIVE-BACKEND test, the committable replacement for the
/// coordinate-driven adb/idb scripts in MultiHostE2ETestSetup.md §7. It needs:
///   - a running stack at NEX_CORE_URL (default https://app.nexemble.local)
///     with the tracking RBAC provisioned (bare/rbac_provision_and_test.py);
///   - the E2E user to exist (default e2e-rep / Demo12345!);
///   - host name resolution + the dev CA reachable from the device under test
///     (see MultiHostE2ETestSetup.md §4).
///
/// Auth: the OIDC browser hop (Custom Tabs / ASWebAuthenticationSession) lives
/// outside the Flutter widget tree, so it cannot be driven from here. Instead
/// the test mints a REAL token via the Keycloak password grant and seeds it
/// through [AuthService.seedSession] — everything downstream (queue, multipart
/// POST, server dedup) runs unfaked.
///
/// Run:
///   flutter test integration_test/visit_report_submit_test.dart \
///     --flavor dev --dart-define=NEX_ENV=dev -d `<device>`          # Android
///   flutter test integration_test/visit_report_submit_test.dart \
///     --dart-define=NEX_ENV=dev -d `<ios-sim>`                      # iOS
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:traccar_client/auth_config.dart';
import 'package:traccar_client/auth_service.dart';
import 'package:traccar_client/main.dart' as app;
import 'package:traccar_client/models/tracking_models.dart';
import 'package:traccar_client/nexemble_reveal.dart';
import 'package:traccar_client/preferences.dart';
import 'package:traccar_client/upload_queue.dart';

/// Test identity — override per environment with --dart-define. The defaults
/// match the bare-harness provisioning (rbac_provision_and_test.py) and the
/// dev realm's default-client, which are already committed in nexcore.
const _user = String.fromEnvironment('E2E_USER', defaultValue: 'e2e-rep');
const _pass = String.fromEnvironment('E2E_PASS', defaultValue: 'Demo12345!');
const _clientSecret = String.fromEnvironment(
  'E2E_CLIENT_SECRET',
  defaultValue: '7JhDTBDoqbcZ7eYMCU79hGuoxB1i89GL',
);

/// Mints a real session via the Keycloak password grant (ROPC). Test-only
/// code path, so TLS verification is relaxed here — the app itself still
/// validates against the bundled dev CA on every real call it makes.
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
    if (resp.statusCode != 200) {
      fail('token mint for $_user failed: HTTP ${resp.statusCode} $body — '
          'is the stack up and RBAC provisioned?');
    }
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

/// Pumps frames until [condition] is true or [timeout] elapses. Used instead
/// of pumpAndSettle because the app has continuous animations (reveal,
/// progress) that never settle.
Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 20),
  required String reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      // Include what IS on screen so a timeout is diagnosable from the log.
      final visible = find
          .byType(Text)
          .evaluate()
          .map((e) => (e.widget as Text).data)
          .whereType<String>()
          .where((s) => s.trim().isNotEmpty)
          .take(15)
          .join(' | ');
      fail('timed out waiting for: $reason\nvisible texts: [$visible]');
    }
    await tester.pump(const Duration(milliseconds: 200));
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Let the engine schedule its own frames (as in production). The default
  // pump-driven policy starves live animations — the 3.6 s reveal overlay
  // never completes and keeps blocking taps on everything beneath it.
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets(
    'scenario 3: a text visit report submits through the real multipart client',
    timeout: const Timeout(Duration(minutes: 4)),
    (tester) async {
      // Boot the real app (Firebase, queue, uploader wiring — all of main()).
      await app.main();
      await tester.pump(const Duration(seconds: 1));

      // Skip the flows this test does not cover: the first-run permission
      // wizard and device registration (scenario 1 owns those). Then seed a
      // real session, which flips the auth gate to the app shell.
      await Preferences.instance.setBool(Preferences.onboardingComplete, true);
      await Preferences.instance.setBool(Preferences.deviceRegistered, true);
      final session = await _mintSession();
      await AuthService.instance.seedSession(
        access: session.access,
        refresh: session.refresh,
        id: session.id,
        expiry: session.expiry,
      );

      // The reveal splash plays ~3.6 s over everything and (correctly) eats
      // taps while visible. find.text() sees THROUGH it — it walks the whole
      // tree — so without this wait the test taps a button no human could
      // reach yet and the tap lands on the splash.
      await _pumpUntil(
        tester,
        () => find.byType(NexembleReveal).evaluate().isEmpty,
        timeout: const Duration(seconds: 15),
        reason: 'reveal splash to finish and unmount',
      );

      // Home shell.
      await _pumpUntil(
        tester,
        () => find.text('File a visit report').evaluate().isNotEmpty,
        timeout: const Duration(seconds: 30),
        reason: 'home screen with the File-a-visit-report button',
      );
      await tester.tap(find.text('File a visit report'));
      await tester.pump(const Duration(milliseconds: 600));

      // Customer picker (mock repository data until #13).
      await _pumpUntil(
        tester,
        () => find.text('Select customer').evaluate().isNotEmpty,
        reason: 'capture screen',
      );
      await tester.tap(find.text('Select customer'));
      await tester.pump(const Duration(milliseconds: 600));
      await _pumpUntil(
        tester,
        () => find.text('Meridian Logistics').evaluate().isNotEmpty,
        reason: 'customer sheet',
      );
      await tester.tap(find.text('Meridian Logistics'));
      await tester.pump(const Duration(milliseconds: 600));

      // Leads resolve async; Submit is gated until they have (vetting gate).
      await _pumpUntil(
        tester,
        () => find.text('Telematics Add-on').evaluate().isNotEmpty,
        reason: 'prefilled lead chips',
      );
      await tester.tap(find.text('Telematics Add-on'));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.text('Depot Automation Pilot'));
      await tester.pump(const Duration(milliseconds: 200));

      // A unique note ties this run to its server row for any manual audit.
      final note =
          'integration_test scenario3 ${DateTime.now().toIso8601String()}';
      await tester.enterText(find.byType(TextField), note);
      FocusManager.instance.primaryFocus?.unfocus(); // drop the keyboard
      await tester.pump(const Duration(milliseconds: 400));

      expect(UploadQueue.instance.items, isEmpty,
          reason: 'queue should be empty before submit');

      await tester.ensureVisible(find.text('Submit report'));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.text('Submit report'));
      await tester.pump(const Duration(milliseconds: 600));

      // The uploader drains asynchronously through the REAL VisitReportClient.
      // Only a 200 removes the item; terminal marks it failed; retryable keeps
      // it queued — so "empty, never failed" is exactly "HTTP 200 end-to-end".
      await _pumpUntil(
        tester,
        () {
          final items = UploadQueue.instance.items;
          final failed =
              items.where((i) => i.status == QueueStatus.failed).toList();
          if (failed.isNotEmpty) {
            fail('upload became terminal (${failed.first.idempotencyKey}) — '
                'check the stack and RBAC');
          }
          return items.isEmpty;
        },
        timeout: const Duration(seconds: 90),
        reason: 'upload queue to drain via a 200 from the multipart edge',
      );
    },
  );
}
