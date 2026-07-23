import 'package:flutter/material.dart';

import 'alerts_repository.dart';
import 'l10n/app_localizations.dart';
import 'models/tracking_models.dart';
import 'reports_repository.dart';
import 'theme.dart';

/// Today's stats on Home (design screen 04): Visits and Reports counts from
/// ReportsRepository, open Alerts from AlertsRepository. The Alerts tile goes
/// amber with a corner dot when anything is open. Each source loads (and can
/// fail) independently; a failed tile shows a dash rather than blocking Home.
class TodayStatsRow extends StatefulWidget {
  const TodayStatsRow({super.key});

  @override
  State<TodayStatsRow> createState() => _TodayStatsRowState();
}

class _TodayStatsRowState extends State<TodayStatsRow> {
  TodayStats? _stats;
  int? _alerts;
  bool _statsError = false;
  bool _alertsError = false;

  @override
  void initState() {
    super.initState();
    _loadStats();
    _loadAlerts();
    // Keep the Alerts tile in sync with ack/snooze from the Alerts tab, and
    // the Reports tile in sync with a newly submitted report.
    AlertsRepository.instance.changes.addListener(_loadAlerts);
    ReportsRepository.instance.changes.addListener(_loadStats);
  }

  @override
  void dispose() {
    AlertsRepository.instance.changes.removeListener(_loadAlerts);
    ReportsRepository.instance.changes.removeListener(_loadStats);
    super.dispose();
  }

  Future<void> _loadStats() async {
    try {
      final stats = await ReportsRepository.instance.todayStats();
      // Clear the error on success, or a single failed load latches '–' for the
      // widget's lifetime (kept alive by the IndexedStack) despite a later
      // successful refresh.
      if (mounted) {
        setState(() {
          _stats = stats;
          _statsError = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _statsError = true);
    }
  }

  Future<void> _loadAlerts() async {
    try {
      final alerts = await AlertsRepository.instance.openAlertsCount();
      if (mounted) {
        setState(() {
          _alerts = alerts;
          _alertsError = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _alertsError = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Row(
      children: [
        Expanded(
          child: _StatTile(
            value: _stats?.visits,
            failed: _statsError,
            label: l.visitsLabel,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _StatTile(
            value: _stats?.reports,
            failed: _statsError,
            label: l.reportsLabel,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _StatTile(
            value: _alerts,
            failed: _alertsError,
            label: l.alertsTitle,
            attention: (_alerts ?? 0) > 0,
          ),
        ),
      ],
    );
  }
}

class _StatTile extends StatelessWidget {
  final int? value;
  final bool failed;
  final String label;
  final bool attention;

  const _StatTile({
    required this.value,
    required this.failed,
    required this.label,
    this.attention = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Widget number;
    if (value != null || failed) {
      number = Text(
        failed ? '–' : '$value',
        style: theme.textTheme.headlineSmall?.copyWith(
          fontWeight: FontWeight.w600,
          color: attention ? AppTheme.warning : null,
        ),
      );
    } else {
      // Loading skeleton.
      number = Container(
        width: 28,
        height: 24,
        margin: const EdgeInsets.symmetric(vertical: 4),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(6),
        ),
      );
    }

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                number,
                const SizedBox(height: 2),
                Text(
                  label,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            if (attention)
              Positioned(
                top: 0,
                right: 0,
                child: Container(
                  width: 6,
                  height: 6,
                  decoration: const BoxDecoration(
                    color: AppTheme.warning,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
