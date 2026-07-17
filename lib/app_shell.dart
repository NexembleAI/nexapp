import 'package:flutter/material.dart';

import 'alerts_repository.dart';
import 'alerts_screen.dart';
import 'geolocation_service.dart';
import 'home_screen.dart';
import 'l10n/app_localizations.dart';
import 'reports_screen.dart';
import 'settings_screen.dart';
import 'theme.dart';

/// Request the shell switch tabs (e.g. "View all reports" / "Back to Home"
/// from the queue screen). 0=Home 1=Reports 2=Alerts 3=Settings.
final ValueNotifier<int?> shellTabRequest = ValueNotifier<int?>(null);

/// Bottom-tab shell from the design handoff (Global navigation): Home,
/// Reports, Alerts, Settings. IndexedStack keeps each tab's state alive
/// across switches.
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    shellTabRequest.addListener(_onTabRequest);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    shellTabRequest.removeListener(_onTabRequest);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Returning from OS settings is when permission changes — reconcile the
    // actual tracking state against the persisted intent. Startup + resume are
    // the only auto-resume triggers; the Home card merely reflects status.
    if (state == AppLifecycleState.resumed) GeolocationService.reconcile();
  }

  void _onTabRequest() {
    final i = shellTabRequest.value;
    if (i != null && mounted) {
      setState(() => _index = i);
      shellTabRequest.value = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: const [
          HomeScreen(),
          ReportsScreen(),
          AlertsScreen(),
          SettingsScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.home_outlined),
            selectedIcon: const Icon(Icons.home),
            label: l.homeTab,
          ),
          NavigationDestination(
            icon: const Icon(Icons.description_outlined),
            selectedIcon: const Icon(Icons.description),
            label: l.reportsTab,
          ),
          NavigationDestination(
            icon: const _AlertsBadge(child: Icon(Icons.notifications_outlined)),
            selectedIcon: const _AlertsBadge(child: Icon(Icons.notifications)),
            label: l.alertsTitle,
          ),
          NavigationDestination(
            icon: const Icon(Icons.settings_outlined),
            selectedIcon: const Icon(Icons.settings),
            label: l.settingsTitle,
          ),
        ],
      ),
    );
  }
}

/// Amber count badge on the Alerts tab (design: status semantics — warning),
/// hidden while loading or when there are no open alerts. Listens to
/// [AlertsRepository.changes] so ack/snooze updates it live.
class _AlertsBadge extends StatefulWidget {
  final Widget child;

  const _AlertsBadge({required this.child});

  @override
  State<_AlertsBadge> createState() => _AlertsBadgeState();
}

class _AlertsBadgeState extends State<_AlertsBadge> {
  int _count = 0;

  @override
  void initState() {
    super.initState();
    _refresh();
    AlertsRepository.instance.changes.addListener(_refresh);
  }

  @override
  void dispose() {
    AlertsRepository.instance.changes.removeListener(_refresh);
    super.dispose();
  }

  Future<void> _refresh() async {
    final count = await AlertsRepository.instance.openAlertsCount();
    if (mounted) setState(() => _count = count);
  }

  @override
  Widget build(BuildContext context) {
    return Badge.count(
      count: _count,
      isLabelVisible: _count > 0,
      backgroundColor: AppTheme.warning,
      child: widget.child,
    );
  }
}
