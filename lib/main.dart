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
import 'nexemble_reveal.dart';
import 'preferences.dart';
import 'registration_gate.dart';
import 'reports_repository.dart';
import 'theme.dart';
import 'tracking_repository.dart';
import 'upload_queue.dart';
import 'upload_uploader.dart';

final messengerKey = GlobalKey<ScaffoldMessengerState>();
final navigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  await Preferences.init();
  await UploadQueue.instance.init();
  await ConnectivityService.instance.init();
  await GeolocationService.tracker.init(Preferences.buildConfig());
  // init() is idempotent and won't update an already-installed native config on
  // an upgraded install, so push the current Preferences to the SDK (covers the
  // NEX_TRACCAR_URL http->https migration and any future config drift).
  await GeolocationService.tracker.setConfig(Preferences.buildConfig());
  await PasswordService.migrate();
  await PushService.init();
  await AuthService.instance.restore();
  // Data-source wiring: each line flips to a real implementation as its
  // backend lands; lib/mock/ is deleted with the last one.
  final reportsMock = MockReportsRepository();
  final alertsMock = MockAlertsRepository();
  // A filed report enqueues into the durable upload queue; bump the
  // today-Reports stat on enqueue. Auto-resolve happens on upload success
  // (wired to the uploader in a later step), not here.
  UploadQueue.instance.onEnqueued = (_) => reportsMock.bumpTodayReports();
  ReportsRepository.instance = reportsMock;
  AlertsRepository.instance = alertsMock;
  TrackingRepository.instance = MockTrackingRepository();
  CustomersRepository.instance = MockCustomersRepository();
  // Uploader drains the queue while online. The POST and the server-reaction
  // are injected simulations (deleted with lib/mock/ + replaced by real HTTP).
  UploadUploader.instance.simulateUpload = (_) async => true;
  UploadUploader.instance.onUploaded = (item) {
    reportsMock.addSubmitted(item);
    if (item.leadIds.isNotEmpty) alertsMock.resolveForLeads(item.leadIds);
  };
  UploadUploader.instance.start();
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
        return const RegistrationGate(
          child: Stack(
            children: [
              QuickActionsInitializer(),
              AppShell(),
            ],
          ),
        );
      },
    );
  }
}
