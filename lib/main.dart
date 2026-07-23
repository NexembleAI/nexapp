import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:app_links/app_links.dart';
import 'package:traccar_client/password_service.dart';
import 'package:traccar_client/push_service.dart';
import 'package:traccar_client/quick_actions.dart';

import 'auth_service.dart';
import 'configuration_service.dart';
import 'connectivity_service.dart';
import 'geolocation_service.dart';
import 'l10n/app_localizations.dart';
import 'alerts_repository.dart';
import 'app_shell.dart';
import 'customers_repository.dart';
import 'login_screen.dart';
import 'mock/mock_repositories.dart'; // TODO(mock): remove with lib/mock/
import 'crm_name_resolver.dart';
import 'device_service.dart';
import 'home_controller.dart';
import 'nexcore_alerts_repository.dart';
import 'nexcore_reports_repository.dart';
import 'nexcore_tracking_repository.dart';
import 'nexcore_visit_reports.dart';
import 'nexemble_reveal.dart';
import 'onboarding_screen.dart';
import 'preferences.dart';
import 'registration_gate.dart';
import 'reports_repository.dart';
import 'theme.dart';
import 'tracking_repository.dart';
import 'upload_queue.dart';
import 'upload_uploader.dart';
import 'visit_report_client.dart';

final messengerKey = GlobalKey<ScaffoldMessengerState>();
final navigatorKey = GlobalKey<NavigatorState>();

// Future (not void) so integration tests can await the async boot sequence
// (Preferences/queue/auth init) before driving the UI.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  await Preferences.init();
  await UploadQueue.instance.init();
  ConnectivityService.instance.init();
  await GeolocationService.initWithConfig();
  await PasswordService.migrate();
  await PushService.init();
  // iOS Keychain outlives app reinstall while shared_preferences does not, so a
  // fresh install (prefs just seeded) can inherit a stale Keychain token that
  // skips login and then fails on the first API call. Drop it on fresh install
  // only — an upgrade keeps its prefs (and session), so this won't sign anyone
  // out on update.
  if (Preferences.firstRun) await AuthService.instance.clearStaleSession();
  await AuthService.instance.restore();
  // Data-source wiring: each line flips to a real implementation as its
  // backend lands; lib/mock/ is deleted with the last one.
  // Home is backend-backed via HomeController; the Reports TAB is now the real
  // Nexcore-backed tab (#13), while the Alerts TAB still reads the mock until
  // it's wired — so the real repos wrap their tab and delegate to it.
  final visitReportsTab = NexcoreVisitReportsTab();
  final alertsMock = MockAlertsRepository();
  ReportsRepository.instance = NexcoreReportsRepository(visitReportsTab);
  AlertsRepository.instance = NexcoreAlertsRepository(alertsMock);
  TrackingRepository.instance = NexcoreTrackingRepository();
  CustomersRepository.instance = MockCustomersRepository();
  // Uploader drains the queue while online. The POST is the real
  // SubmitVisitReport client (multipart to the tracking REST edge); the report
  // server-reaction below is now the real Reports tab (#13), while the alert
  // auto-resolve stays a mock until the Alerts tab is wired.
  UploadUploader.instance.upload = VisitReportClient().submit;
  UploadUploader.instance.onUploaded = (item) {
    // Overlay the just-uploaded report on the real Reports tab (until a list
    // refetch sees the server row), keep the (mock) Alerts tab consistent, and
    // refresh real Home so the new report + any auto-resolved alert show once
    // the POST lands.
    visitReportsTab.reportUploaded(item);
    if (item.leadIds.isNotEmpty) alertsMock.resolveForLeads(item.leadIds);
    HomeController.instance.refresh();
  };
  UploadUploader.instance.start();
  // A rejected session pauses the drain; resume once signed in again.
  AuthService.instance.authState.addListener(() {
    if (AuthService.instance.authState.value == true) {
      UploadUploader.instance.resume();
    } else {
      // Sign-out: drop the previous session's cached data so the next account
      // (possibly a different user on a shared device) never sees it.
      HomeController.instance.reset();
      DeviceService.clearCache();
      CrmNameResolver.instance.clear();
    }
  });
  runApp(const MainApp());
}

class MainApp extends StatefulWidget {
  const MainApp({super.key});

  @override
  State<MainApp> createState() => _MainAppState();
}

class _MainAppState extends State<MainApp> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _initLinks();
    });
  }

  Future<void> _initLinks() async {
    AppLinks().uriLinkStream.listen(_handleUri);
  }

  Future<void> _handleUri(Uri uri) async {
    if (uri.host == 'action') {
      switch (uri.pathSegments.firstOrNull) {
        case 'start':
          await GeolocationService.start();
        case 'stop':
          await GeolocationService.stop();
      }
      return;
    }
    final context = navigatorKey.currentContext;
    if (context == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(AppLocalizations.of(context)!.configurationMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(AppLocalizations.of(context)!.cancelButton),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(AppLocalizations.of(context)!.okButton),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ConfigurationService.applyUri(uri);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      scaffoldMessengerKey: messengerKey,
      navigatorKey: navigatorKey,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      home: const RevealGate(child: AuthGate()),
    );
  }
}

/// Shows the login screen when signed out and the app when signed in,
/// driven by [AuthService.authState].
class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool?>(
      valueListenable: AuthService.instance.authState,
      builder: (context, signedIn, _) {
        if (signedIn != true) {
          return const LoginScreen();
        }
        return OnboardingGate(
          child: const RegistrationGate(
            child: Stack(
              children: [
                QuickActionsInitializer(),
                AppShell(),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Shows the first-run permission wizard (design screen 03) until it's been
/// completed or skipped, then renders [child]. Gated on a persisted flag so it
/// only appears once.
class OnboardingGate extends StatefulWidget {
  final Widget child;
  const OnboardingGate({super.key, required this.child});

  @override
  State<OnboardingGate> createState() => _OnboardingGateState();
}

class _OnboardingGateState extends State<OnboardingGate> {
  late bool _done =
      Preferences.instance.getBool(Preferences.onboardingComplete) == true;

  @override
  Widget build(BuildContext context) {
    if (_done) return widget.child;
    return OnboardingScreen(
      // Persist as soon as the wizard reaches its last page, not only on the
      // final tap. RegistrationGate sits behind this gate, so a user who
      // granted everything and then killed the app would otherwise get no
      // registration and no tracking that session — and re-enter the wizard.
      onReachedEnd: () => Preferences.instance.setBool(
        Preferences.onboardingComplete,
        true,
      ),
      onFinish: () async {
        await Preferences.instance.setBool(
          Preferences.onboardingComplete,
          true,
        );
        if (mounted) setState(() => _done = true);
      },
    );
  }
}
