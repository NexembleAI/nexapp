import 'package:flutter/material.dart';

import 'l10n/app_localizations.dart';

/// Placeholder for the Reports history tab (design screen 07). Replaced when
/// visit reports land (Phase 2).
class ReportsScreen extends StatelessWidget {
  const ReportsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l.reportsTitle)),
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
