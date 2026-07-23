/// E2E scenario 4 — open the visit-report history through the REAL
/// [RealReportsRepository] (#13 / P2.5), open a report, edit its text, and prove
/// the edit persisted server-side.
///
/// Like scenario 3 (visit_report_submit_test.dart) this is a LIVE-BACKEND test,
/// the committable replacement for coordinate-driven adb/idb scripting. It needs:
///   - a running stack at NEX_CORE_URL (default https://app.nexemble.local) with
///     the tracking RBAC provisioned (bare/rbac_provision_and_test.py);
///   - the E2E user (default e2e-rep / Demo12345!) to already have AT LEAST ONE
///     visit report server-side — run scenario 3 first, or seed one, otherwise
///     the Reports list is empty and this test fails with a clear message;
///   - host resolution + the dev CA reachable from the device under test
///     (MultiHostE2ETestSetup.md §4).
///
/// Auth: the OIDC browser hop can't be driven from integration_test, so a real
/// token is minted via the Keycloak password grant and seeded through
/// [AuthService.seedSession] — every read/write below runs unfaked.
///
/// Run:
///   flutter test integration_test/visit_report_history_test.dart \
///     --flavor dev --dart-define=NEX_ENV=dev -d `<device>`          # Android
///   flutter test integration_test/visit_report_history_test.dart \
///     --dart-define=NEX_ENV=dev -d `<ios-sim>`                      # iOS
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:traccar_client/audio_player_bar.dart';
import 'package:traccar_client/auth_config.dart';
import 'package:traccar_client/auth_service.dart';
import 'package:traccar_client/main.dart' as app;
import 'package:traccar_client/nexemble_reveal.dart';
import 'package:traccar_client/preferences.dart';
import 'package:traccar_client/reports_repository.dart';
import 'package:traccar_client/status_chip.dart';

const _user = String.fromEnvironment('E2E_USER', defaultValue: 'e2e-rep');
const _pass = String.fromEnvironment('E2E_PASS', defaultValue: 'Demo12345!');
const _clientSecret = String.fromEnvironment(
  'E2E_CLIENT_SECRET',
  defaultValue: '7JhDTBDoqbcZ7eYMCU79hGuoxB1i89GL',
);

/// When set (E2E_EXPECT_CUSTOMER), assert the top report's customer name — the
/// live Odoo display name the client resolves via ResolveCrmNames from an opaque
/// customer id — both in the repo model and rendered on screen. Empty (default)
/// skips it so the committed test isn't coupled to a particular seeded customer.
const _expectCustomer =
    String.fromEnvironment('E2E_EXPECT_CUSTOMER', defaultValue: '');

/// When true (E2E_EXPECT_AUDIO), the top report is expected to carry audio + a
/// real (ASR) transcript: assert the audio player renders, the transcript text
/// shows, and NO "pending"/"no audio" placeholder appears. Default false so the
/// committed test doesn't require an audio-seeded report.
const _expectAudio = bool.fromEnvironment('E2E_EXPECT_AUDIO', defaultValue: false);

/// Mints a real session via the Keycloak password grant (ROPC). Test-only path,
/// so TLS verification is relaxed here; the app itself still validates against
/// the bundled dev CA on every real call.
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

/// Pumps frames until [condition] or [timeout] — the app has continuous
/// animations (reveal, progress) that never settle, so pumpAndSettle hangs.
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
    'scenario 4: open history, edit a report, and prove the edit persisted',
    timeout: const Timeout(Duration(minutes: 4)),
    (tester) async {
      await app.main();
      await tester.pump(const Duration(seconds: 1));

      await Preferences.instance.setBool(Preferences.onboardingComplete, true);
      await Preferences.instance.setBool(Preferences.deviceRegistered, true);
      final session = await _mintSession();
      await AuthService.instance.seedSession(
        access: session.access,
        refresh: session.refresh,
        id: session.id,
        expiry: session.expiry,
      );

      await _pumpUntil(
        tester,
        () => find.byType(NexembleReveal).evaluate().isEmpty,
        timeout: const Duration(seconds: 15),
        reason: 'reveal splash to finish and unmount',
      );

      // Shell up — switch to the Reports tab (scope to the nav bar so the tab
      // label isn't confused with any other "Reports" text).
      await _pumpUntil(
        tester,
        () => find.byType(NavigationBar).evaluate().isNotEmpty,
        timeout: const Duration(seconds: 30),
        reason: 'app shell with the bottom navigation bar',
      );
      final reportsTab = find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('Reports'),
      );
      await tester.tap(reportsTab);
      await tester.pump(const Duration(milliseconds: 600));

      // A loaded report card carries a StatusChip (the skeleton does not) — its
      // presence means the real ListVisitReports came back with rows.
      await _pumpUntil(
        tester,
        () => find.byType(StatusChip).evaluate().isNotEmpty,
        timeout: const Duration(seconds: 30),
        reason: 'at least one server report card (seed one via scenario 3 if '
            'the list is empty)',
      );

      // Resolve the top report straight from the repository BEFORE editing, so
      // the edit can be proven out-of-band afterwards. The queue is empty in
      // this scenario, so the top card is exactly entries.first; capture its
      // pre-edit version to assert the save bumped it.
      final entries = await ReportsRepository.instance.reports();
      expect(entries, isNotEmpty,
          reason: 'the Reports list is empty — seed a report via scenario 3');
      final id = entries.first.id!;
      final pre = await ReportsRepository.instance.reportDetail(id);

      // Real-Odoo proof (opt-in): the report carries only an opaque customer id;
      // the client resolved it to the live Odoo display name via ResolveCrmNames.
      // Assert that both in the repo model and on the rendered list card.
      if (_expectCustomer.isNotEmpty) {
        expect(entries.first.customerName, _expectCustomer,
            reason: 'ResolveCrmNames did not map the report to its real Odoo '
                'name (got "${entries.first.customerName}")');
        expect(find.text(_expectCustomer), findsWidgets,
            reason: 'the real Odoo customer name is not shown on the list');
      }

      // Audio + ASR transcript (opt-in): the report carries audio and a real
      // transcript the ASR pipeline produced (submitted -> ready).
      if (_expectAudio) {
        expect(pre.audioPresent, isTrue,
            reason: 'the top report has no audio (seed an audio report)');
        expect(pre.transcript?.trim().isNotEmpty, isTrue,
            reason: 'the ASR pipeline produced no transcript for the report');
      }

      // Open the first report's detail.
      final firstCard = find
          .ancestor(
            of: find.byType(StatusChip).first,
            matching: find.byType(InkWell),
          )
          .first;
      await tester.tap(firstCard);
      await tester.pump(const Duration(milliseconds: 600));

      // Detail loaded once the Save bar is present (i.e. an editable own report).
      await _pumpUntil(
        tester,
        () => find.text('Save changes').evaluate().isNotEmpty,
        timeout: const Duration(seconds: 30),
        reason: 'report detail with the Save bar (own, editable report)',
      );

      // The detail header shows the same resolved real-Odoo customer name.
      if (_expectCustomer.isNotEmpty) {
        expect(find.text(_expectCustomer), findsWidgets,
            reason: 'the real Odoo customer name is not shown on the detail');
      }

      // Audio report: the player renders and the real transcript is shown —
      // never a "pending"/"no audio" placeholder for a ready, transcribed report.
      if (_expectAudio) {
        expect(find.byType(AudioPlayerBar), findsOneWidget,
            reason: 'the audio player is not shown for an audio report');
        expect(find.text(pre.transcript!), findsOneWidget,
            reason: 'the real transcript text is not rendered on the detail');
        expect(find.text('Transcript pending…'), findsNothing,
            reason: 'a ready, transcribed report must not show "pending"');
        expect(find.text('No audio recorded'), findsNothing,
            reason: 'an audio report must not show the no-audio placeholder');
      }

      // Edit the notes to a unique value tied to this run.
      final note = 'p2.5 e2e edit ${DateTime.now().toIso8601String()}';
      await tester.enterText(find.byType(TextField), note);
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump(const Duration(milliseconds: 400));

      await tester.ensureVisible(find.text('Save changes'));
      await tester.tap(find.text('Save changes'));

      // Prove persistence by reading the server back through the repository, NOT
      // by find.text(note): that matcher hits the TextField's own EditableText
      // the instant enterText runs — before any PUT — so a server that persists
      // nothing would still pass. Poll GetVisitReport (every ~2 s, up to 60 s)
      // until the server returns the new note AND a bumped version — the two
      // together are what UpdateVisitReport commits.
      final deadline = DateTime.now().add(const Duration(seconds: 60));
      var persisted = false;
      while (!persisted && DateTime.now().isBefore(deadline)) {
        // ~2 s of live frames between polls (fullyLive advances real time).
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 200));
        }
        final d = await ReportsRepository.instance.reportDetail(id);
        persisted = d.notes == note && d.version > pre.version;
      }
      expect(
        persisted,
        isTrue,
        reason: 'UpdateVisitReport did not persist the edit: the server never '
            'returned notes == "$note" with a version above ${pre.version} '
            'within 60 s',
      );
    },
  );
}
