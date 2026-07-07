import 'package:flutter/material.dart';

import 'alerts_repository.dart';
import 'alerts_screen.dart';
import 'l10n/app_localizations.dart';
import 'main_screen.dart';
import 'reports_screen.dart';
import 'settings_screen.dart';
import 'theme.dart';

/// Bottom-tab shell from the design handoff (Global navigation): Home,
/// Reports, Alerts, Settings. IndexedStack keeps each tab's state alive
/// across switches.
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: const [
          MainScreen(),
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
/// hidden while loading or when there are no open alerts.
class _AlertsBadge extends StatelessWidget {
  final Widget child;

  const _AlertsBadge({required this.child});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<int>(
      future: AlertsRepository.instance.openAlertsCount(),
      builder: (context, snapshot) {
        final count = snapshot.data ?? 0;
        return Badge.count(
          count: count,
          isLabelVisible: count > 0,
          backgroundColor: AppTheme.warning,
          child: child,
        );
      },
    );
  }
}
