import 'package:flutter/material.dart';

import 'l10n/app_localizations.dart';

/// Placeholder for the coverage-alert inbox tab (design screen 09). Replaced
/// when lead alerts land (Phase 3).
class AlertsScreen extends StatelessWidget {
  const AlertsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l.alertsTitle)),
      body: Center(
        child: Text(
          l.comingSoonMessage,
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      ),
    );
  }
}
