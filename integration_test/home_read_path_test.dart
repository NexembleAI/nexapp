/// E2E scenario — the Home tab READ path against a live NexCore stack.
///
/// Companion to visit_report_submit_test.dart (which exercises the WRITE path).
/// This one seeds a real rep session and asserts the Home tab renders end-to-end
/// off the real backend: the three tracking list calls (sessions / reports /
/// alerts) succeed and parse, the coordinator's derived views are well-formed,
/// the office-hours window renders, and the "Today's visits" section shows
/// either rows or its empty state — never the error state.
///
/// It deliberately does NOT assert specific data values (visit names, an
/// "Ongoing" row, a particular window): those depend on what the e2e-rep account
/// happens to hold and on geofence-sourced sessions the app can't create. Those
/// exact renderings are pinned deterministically in test/today_visits_list_test
/// and test/office_hours_test. Here we prove the WIRING is live.
///
/// Same prerequisites and auth approach as visit_report_submit_test.dart: a
/// running stack at NEX_CORE_URL with tracking RBAC provisioned, the e2e-rep
/// user, and a token minted via the Keycloak password grant + seedSession.
///
/// Run:
///   flutter test integration_test/home_read_path_test.dart \
///     --flavor dev --dart-define=NEX_ENV=dev -d `<device>`         # Android
///   flutter test integration_test/home_read_path_test.dart \
///     --dart-define=NEX_ENV=dev -d `<ios-sim>`                     # iOS
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:traccar_client/auth_config.dart';
import 'package:traccar_client/auth_service.dart';
import 'package:traccar_client/home_controller.dart';
import 'package:traccar_client/main.dart' as app;
import 'package:traccar_client/nexemble_reveal.dart';
import 'package:traccar_client/preferences.dart';

/// Test identity — matches the bare-harness provisioning and the dev realm's
/// default-client (see visit_report_submit_test.dart for the rationale).
const _user = String.fromEnvironment('E2E_USER', defaultValue: 'e2e-rep');
const _pass = String.fromEnvironment('E2E_PASS', defaultValue: 'Demo12345!');
const _clientSecret = String.fromEnvironment(
  'E2E_CLIENT_SECRET',
  defaultValue: '7JhDTBDoqbcZ7eYMCU79hGuoxB1i89GL',
);

/// Mints a real session via the Keycloak password grant (ROPC). Test-only, so
/// TLS verification is relaxed here; the app still validates against the bundled
/// dev CA on every real call it makes.
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

/// Pumps frames until [condition] is true or [timeout] elapses (pumpAndSettle
/// can't be used — the reveal/activity animations never settle).
Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 20),
  required String reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
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
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets(
    'home read path: the tab renders off the live backend',
    timeout: const Timeout(Duration(minutes: 3)),
    (tester) async {
      // Boot the real app (Firebase, queue, repos, uploader wiring).
      await app.main();
      await tester.pump(const Duration(seconds: 1));

      // Skip the first-run wizard and device registration (owned by other
      // scenarios), then seed a real session to flip the auth gate.
      await Preferences.instance.setBool(Preferences.onboardingComplete, true);
      await Preferences.instance.setBool(Preferences.deviceRegistered, true);
      final session = await _mintSession();
      await AuthService.instance.seedSession(
        access: session.access,
        refresh: session.refresh,
        id: session.id,
        expiry: session.expiry,
      );

      // Let the reveal splash finish (it eats taps while visible).
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

      // The three list calls + CRM resolve run through the coordinator. Wait for
      // it to have data, then assert it did NOT land in the error state — this
      // is the end-to-end proof that the read path is live (token → GETs →
      // parse → derive), independent of what data the account holds.
      final home = HomeController.instance;
      await _pumpUntil(
        tester,
        () => home.hasData,
        timeout: const Duration(seconds: 60),
        reason: 'home coordinator to load the tracking lists from the backend',
      );
      expect(home.hasError, isFalse,
          reason: 'read path errored — check the stack, token scope, and RBAC');

      // Derived views are well-formed off the real payloads.
      expect(home.weeklyActivity.length, 7);
      expect(home.weeklyActivity.every((v) => v >= 0 && v <= 1), isTrue);
      expect(home.todayStats.visits, greaterThanOrEqualTo(0));
      expect(home.todayStats.reports, greaterThanOrEqualTo(0));
      expect(home.openAlertsCount, greaterThanOrEqualTo(0));
      // todayVisits count never exceeds the day's visit tally.
      expect(home.todayVisits.length, home.todayStats.visits);

      // The office-hours window renders (from ListDevices, or the 9:00–17:30
      // default when the account has no schedule) — its badge is always shown.
      expect(find.text('Office hours'), findsWidgets);

      // The "Today's visits" section renders — rows or the empty state, but not
      // an error. Its title is always present once Home has data (the widget
      // renders it upper-cased).
      await _pumpUntil(
        tester,
        () => find.text("TODAY'S VISITS").evaluate().isNotEmpty,
        reason: "the Today's visits section",
      );
    },
  );
}
