import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'alert_detail_screen.dart';
import 'alerts_repository.dart';
import 'l10n/app_localizations.dart';
import 'models/tracking_models.dart';
import 'theme.dart';

/// Coverage-alert inbox (design screen 09): needs-action cards (accent bar,
/// reason line, File report / Snooze / Ack) over a dimmed EARLIER section
/// (acknowledged / snoozed). Read-only for now — actions are wired next.
class AlertsScreen extends StatefulWidget {
  const AlertsScreen({super.key});

  @override
  State<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends State<AlertsScreen> {
  List<LeadAlert>? _alerts;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _load();
    AlertsRepository.instance.changes.addListener(_load);
  }

  @override
  void dispose() {
    AlertsRepository.instance.changes.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final alerts = await AlertsRepository.instance.alerts();
      if (mounted) setState(() => _alerts = alerts);
    } catch (_) {
      if (mounted) setState(() => _error = true);
    }
  }

  /// Placeholder until snooze policy (duration/cap) is defined server-side —
  /// the coverage_rule schema has no snooze columns yet (§4.6 gap).
  static const _snoozeDuration = Duration(days: 3);

  Future<void> _ack(LeadAlert a) => AlertsRepository.instance.ack(a.id);

  Future<void> _snooze(LeadAlert a) => AlertsRepository.instance.snooze(
    a.id,
    DateTime.now().add(_snoozeDuration),
  );

  void _openDetail(LeadAlert a) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => AlertDetailScreen(alertId: a.id)),
    );
  }

  void _fileReport(LeadAlert a) {
    // Opens visit capture (design screen 05) pre-targeted at this lead,
    // once built.
    final l = AppLocalizations.of(context)!;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(l.comingSoonMessage),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);

    final needs =
        (_alerts ?? []).where((a) => a.needsAction).toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    // Handled-but-unresolved alerts; resolved ones leave the inbox.
    final earlier =
        (_alerts ?? [])
            .where(
              (a) =>
                  a.status == AlertStatus.ack ||
                  a.status == AlertStatus.snoozed,
            )
            .toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

    final Widget content;
    if (_error) {
      content = _Message(l.alertsLoadError);
    } else if (_alerts == null) {
      content = const _SkeletonList();
    } else if (needs.isEmpty && earlier.isEmpty) {
      content = _Message(l.noAlerts);
    } else {
      content = ListView(
        padding: const EdgeInsets.all(16),
        children: [
          for (final a in needs) ...[
            _NeedsActionCard(
              alert: a,
              onTap: () => _openDetail(a),
              onFileReport: () => _fileReport(a),
              onSnooze: () => _snooze(a),
              onAck: () => _ack(a),
            ),
            const SizedBox(height: 12),
          ],
          if (earlier.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              l.earlierLabel.toUpperCase(),
              style: theme.textTheme.labelSmall?.copyWith(
                color: AppTheme.mutedLabel(theme.brightness),
                fontWeight: FontWeight.w600,
                letterSpacing: 0.8,
              ),
            ),
            const SizedBox(height: 8),
            for (final a in earlier) ...[
              _EarlierCard(alert: a, onTap: () => _openDetail(a)),
              const SizedBox(height: 12),
            ],
          ],
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(l.alertsTitle),
            if (needs.isNotEmpty) ...[
              const SizedBox(width: 8),
              Text(
                l.needActionCount(needs.length),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
          ],
        ),
      ),
      body: content,
    );
  }
}

/// "Apex Manufacturing" or "Coastal Retail Group · 1d ago" (no suffix for
/// alerts created today).
String _accountLine(BuildContext context, LeadAlert alert) {
  final l = AppLocalizations.of(context)!;
  final days = DateTime.now().difference(alert.createdAt).inDays;
  return days < 1
      ? alert.accountName
      : '${alert.accountName} · ${l.daysAgo(days)}';
}

class _NeedsActionCard extends StatelessWidget {
  final LeadAlert alert;
  final VoidCallback onTap;
  final VoidCallback onFileReport;
  final VoidCallback onSnooze;
  final VoidCallback onAck;

  const _NeedsActionCard({
    required this.alert,
    required this.onTap,
    required this.onFileReport,
    required this.onSnooze,
    required this.onAck,
  });

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: theme.cardTheme.color,
          borderRadius: BorderRadius.circular(AppTheme.cardRadius),
          border: Border.all(color: primary.withValues(alpha: 0.30)),
        ),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(width: 3, color: primary), // left accent bar
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(
                              alert.leadTitle,
                              style: theme.textTheme.bodyLarge?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          const _ActionNeededChip(),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _accountLine(context, alert),
                        style: TextStyle(
                          fontSize: 13,
                          color: AppTheme.mutedLabel(theme.brightness),
                        ),
                      ),
                      const SizedBox(height: 10),
                      _ReasonLine(alert: alert),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          FilledButton(
                            style: FilledButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 18,
                              ),
                              minimumSize: const Size(0, 38),
                            ),
                            onPressed: onFileReport,
                            child: Text(l.fileReportButton),
                          ),
                          const SizedBox(width: 8),
                          _PillButton(label: l.snoozeButton, onTap: onSnooze),
                          const SizedBox(width: 8),
                          _PillButton(label: l.ackButton, onTap: onAck),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Reason styling varies by type (measured from the mock): no-visit = amber
/// warning icon + regular text; next-activity-overdue = primary-colored text.
class _ReasonLine extends StatelessWidget {
  final LeadAlert alert;

  const _ReasonLine({required this.alert});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    switch (alert.reason) {
      case AlertReason.noVisitWindow:
        return Row(
          children: [
            const Icon(
              Icons.warning_amber_rounded,
              size: 16,
              color: AppTheme.warning,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                l.reasonNoVisit(
                  alert.daysSinceVisit ?? 0,
                  alert.thresholdDays ?? 0,
                ),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface,
                ),
              ),
            ),
          ],
        );
      case AlertReason.nextActivityOverdue:
        return Text(
          l.reasonNextActivityOverdue(alert.closeInDays ?? 0),
          style: theme.textTheme.bodySmall?.copyWith(
            color: AppTheme.mutedLabel(theme.brightness),
          ),
        );
      case AlertReason.leadStale:
        return Text(
          l.reasonLeadStale,
          style: theme.textTheme.bodySmall?.copyWith(
            color: AppTheme.mutedLabel(theme.brightness),
          ),
        );
    }
  }
}

class _ActionNeededChip extends StatelessWidget {
  const _ActionNeededChip();

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final primary = Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        l.actionNeeded,
        style: TextStyle(
          color: primary,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// White pill secondary action (Snooze / Ack).
class _PillButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _PillButton({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return OutlinedButton(
      style: OutlinedButton.styleFrom(
        shape: const StadiumBorder(),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
        backgroundColor: theme.cardTheme.color,
        foregroundColor: theme.colorScheme.onSurface,
        padding: const EdgeInsets.symmetric(horizontal: 18),
        minimumSize: const Size(0, 38),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
      onPressed: onTap,
      child: Text(label),
    );
  }
}

class _EarlierCard extends StatelessWidget {
  final LeadAlert alert;
  final VoidCallback onTap;

  const _EarlierCard({required this.alert, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = AppLocalizations.of(context)!;

    // Both EARLIER chips are neutral/de-emphasized (measured from the mock —
    // snoozed is NOT amber; nothing in the handled section shouts).
    final Widget chip;
    if (alert.status == AlertStatus.snoozed && alert.snoozeUntil != null) {
      final date = DateFormat.MMMd(
        Localizations.localeOf(context).toString(),
      ).format(alert.snoozeUntil!);
      chip = _StatusPill(
        icon: Icons.schedule,
        label: l.untilChip(date),
        color: theme.colorScheme.onSurfaceVariant,
      );
    } else {
      chip = _StatusPill(
        label: l.acknowledgedChip,
        color: theme.colorScheme.onSurfaceVariant,
      );
    }

    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppTheme.cardRadius),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      alert.leadTitle,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.75,
                        ),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _accountLine(context, alert),
                      style: TextStyle(
                        fontSize: 13,
                        color: AppTheme.mutedLabel(
                          theme.brightness,
                        ).withValues(alpha: 0.8),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              chip,
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  final IconData? icon;
  final String label;
  final Color color;

  const _StatusPill({this.icon, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: color),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  final String message;

  const _Message(this.message);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class _SkeletonList extends StatelessWidget {
  const _SkeletonList();

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.surfaceContainerHighest;
    Widget bar(double w) => Container(
      width: w,
      height: 12,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(6),
      ),
    );
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: 2,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder:
          (_, _) => Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  bar(160),
                  const SizedBox(height: 8),
                  bar(110),
                  const SizedBox(height: 8),
                  bar(200),
                ],
              ),
            ),
          ),
    );
  }
}
