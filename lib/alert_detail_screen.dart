import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'alerts_repository.dart';
import 'l10n/app_localizations.dart';
import 'models/tracking_models.dart';
import 'theme.dart';
import 'visit_capture_screen.dart';

/// Alert detail (design screen 10): summary card with Odoo meta, per-reason
/// amber callout, lifecycle timeline, and pinned status-dependent actions
/// (inert until the behavior step).
class AlertDetailScreen extends StatefulWidget {
  final String alertId;

  const AlertDetailScreen({super.key, required this.alertId});

  @override
  State<AlertDetailScreen> createState() => _AlertDetailScreenState();
}

class _AlertDetailScreenState extends State<AlertDetailScreen> {
  LeadAlert? _alert;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _load();
    // Re-resolve on any mutation (from this screen or the inbox behind it):
    // the timeline grows and button visibility re-evaluates in place.
    AlertsRepository.instance.changes.addListener(_load);
  }

  @override
  void dispose() {
    AlertsRepository.instance.changes.removeListener(_load);
    super.dispose();
  }

  Future<void> _ack() => AlertsRepository.instance.ack(widget.alertId);

  Future<void> _snooze() => AlertsRepository.instance.snooze(
        widget.alertId,
        DateTime.now().add(defaultSnoozeDuration),
      );

  Future<void> _fileReport() async {
    final alert = _alert;
    if (alert == null) return;
    await openCaptureForAlert(context, alert);
    if (mounted) _load(); // reflect an auto-resolve after returning
  }

  Future<void> _load() async {
    try {
      final alerts = await AlertsRepository.instance.alerts();
      final match = alerts.where((a) => a.id == widget.alertId).firstOrNull;
      if (!mounted) return;
      // A resolved alert has left the inbox; close the detail if it's on top.
      // (During submit the changes listener fires while capture is still on
      // top — the isCurrent guard defers the pop to the post-return _load.)
      if (match != null && match.status == AlertStatus.resolved) {
        if (ModalRoute.of(context)?.isCurrent ?? false) Navigator.pop(context);
        return;
      }
      setState(() {
        _alert = match;
        _error = match == null;
      });
    } catch (_) {
      if (mounted) setState(() => _error = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final alert = _alert;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          l.coverageAlertTitle,
          style: theme.textTheme.titleMedium
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      body: _error
          ? Center(child: Text(l.alertsLoadError))
          : alert == null
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    _SummaryCard(alert: alert),
                    const SizedBox(height: 16),
                    _ReasonCallout(alert: alert),
                    const SizedBox(height: 20),
                    _Timeline(alert: alert),
                  ],
                ),
      bottomNavigationBar: alert == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: _Actions(
                  alert: alert,
                  onFileReport: _fileReport,
                  onAck: _ack,
                  onSnooze: _snooze,
                ),
              ),
            ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  final LeadAlert alert;

  const _SummaryCard({required this.alert});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final locale = Localizations.localeOf(context).toString();

    String priorityLabel(AlertPriority p) => switch (p) {
          AlertPriority.high => l.priorityHigh,
          AlertPriority.medium => l.priorityMedium,
          AlertPriority.low => l.priorityLow,
        };

    // Odoo-sourced fields may be absent; absent ones drop out of the grid.
    final meta = <(String, String, Color?)>[
      if (alert.stage != null) (l.stageLabel, alert.stage!, null),
      if (alert.priority != null)
        (
          l.priorityLabel,
          priorityLabel(alert.priority!),
          alert.priority == AlertPriority.high ? AppTheme.warning : null,
        ),
      if (alert.lastCoveredAt != null)
        (
          l.lastCoveredLabel,
          DateFormat.MMMd(locale).format(alert.lastCoveredAt!),
          null,
        ),
    ];

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              alert.leadTitle,
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 2),
            Text(
              alert.accountName,
              style: TextStyle(
                fontSize: 13,
                color: AppTheme.mutedLabel(theme.brightness),
              ),
            ),
            if (meta.isNotEmpty) ...[
              const SizedBox(height: 14),
              Wrap(
                spacing: 32,
                runSpacing: 12,
                children: [
                  for (final (label, value, color) in meta)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          label,
                          style: TextStyle(
                            fontSize: 11,
                            color: AppTheme.mutedLabel(theme.brightness),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          value,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: color,
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Amber, bordered callout: bold lead-in + explanation, copy per reason.
class _ReasonCallout extends StatelessWidget {
  final LeadAlert alert;

  const _ReasonCallout({required this.alert});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);

    String priorityWord() => switch (alert.priority) {
          AlertPriority.high => l.priorityHigh.toLowerCase(),
          AlertPriority.medium => l.priorityMedium.toLowerCase(),
          AlertPriority.low => l.priorityLow.toLowerCase(),
          null => '',
        };

    final (title, body) = switch (alert.reason) {
      AlertReason.noVisitWindow => (
          l.calloutNoVisitTitle(alert.daysSinceVisit ?? 0),
          alert.priority != null
              ? l.calloutNoVisitBody(priorityWord(), alert.thresholdDays ?? 0)
              : l.calloutNoVisitBodyNoPriority(alert.thresholdDays ?? 0),
        ),
      AlertReason.nextActivityOverdue => (
          l.calloutOverdueTitle,
          l.calloutOverdueBody(alert.closeInDays ?? 0),
        ),
      AlertReason.leadStale => (l.calloutStaleTitle, l.calloutStaleBody),
    };

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.warning.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.warning.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The warning glyph marks the no-visit reason (same rule as the
          // inbox reason line), not priority.
          if (alert.reason == AlertReason.noVisitWindow) ...[
            const Icon(Icons.warning_amber_rounded,
                size: 16, color: AppTheme.warning),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Text.rich(
              TextSpan(
                text: '$title ',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.onSurface,
                  height: 1.4,
                ),
                children: [
                  TextSpan(
                    text: body,
                    style: const TextStyle(fontWeight: FontWeight.w400),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Timeline extends StatelessWidget {
  final LeadAlert alert;

  const _Timeline({required this.alert});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final ml = MaterialLocalizations.of(context);
    final locale = Localizations.localeOf(context).toString();

    String when(DateTime d) => '${DateFormat.MMMd(locale).format(d)} · '
        '${ml.formatTimeOfDay(TimeOfDay.fromDateTime(d))}';

    // Past events from history…
    final items = <(String, String?, bool)>[
      for (final e in alert.history)
        switch (e.type) {
          AlertEventType.opened => (
              l.eventOpened,
              l.eventOpenedDetail(when(e.at)),
              false,
            ),
          AlertEventType.acked => (l.eventAcked, when(e.at), false),
          AlertEventType.snoozed => (
              l.eventSnoozed,
              l.eventSnoozedUntil(
                  when(e.at),
                  e.until != null
                      ? DateFormat.MMMd(locale).format(e.until!)
                      : ''),
              false,
            ),
          AlertEventType.reopened => (l.eventReopened, when(e.at), false),
          AlertEventType.escalated => (l.eventEscalated, when(e.at), false),
        },
    ];

    // …plus one "current" item by status.
    switch (alert.status) {
      case AlertStatus.open:
        final days = alert.escalatesAt == null
            ? null
            : (alert.escalatesAt!.difference(DateTime.now()).inHours / 24)
                .ceil()
                .clamp(0, 999);
        items.add((
          l.timelineAwaitingAction,
          days == null ? null : l.timelineEscalatesIn(days),
          true,
        ));
      case AlertStatus.ack:
        items.add((l.timelineAwaitingVisit, l.timelineEscalationPaused, true));
      case AlertStatus.snoozed:
        final date = alert.snoozeUntil == null
            ? ''
            : DateFormat.MMMd(locale).format(alert.snoozeUntil!);
        items.add((l.timelineReopens(date), null, true));
      case AlertStatus.escalated:
        items.add((l.timelineAwaitingAction, null, true));
      case AlertStatus.resolved:
        break; // resolved alerts leave the inbox; no pending item
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l.timelineLabel.toUpperCase(),
          style: theme.textTheme.labelSmall?.copyWith(
            color: AppTheme.mutedLabel(theme.brightness),
            fontWeight: FontWeight.w600,
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(height: 12),
        for (final (i, item) in items.indexed)
          _TimelineItem(
            title: item.$1,
            subtitle: item.$2,
            current: item.$3,
            isLast: i == items.length - 1,
          ),
      ],
    );
  }
}

class _TimelineItem extends StatelessWidget {
  final String title;
  final String? subtitle;
  final bool current;
  final bool isLast;

  const _TimelineItem({
    required this.title,
    this.subtitle,
    required this.current,
    required this.isLast,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 20,
            child: Column(
              children: [
                Container(
                  width: 9,
                  height: 9,
                  margin: const EdgeInsets.only(top: 3),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    // Pending dot is solid neutral (measured: #CFCED7 light /
                    // #353444 dark); past events are solid primary.
                    color: current ? theme.colorScheme.outlineVariant : primary,
                  ),
                ),
                if (!isLast)
                  Expanded(
                    child: Container(
                      width: 2,
                      margin: const EdgeInsets.symmetric(vertical: 3),
                      color: theme.colorScheme.outlineVariant,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: isLast ? 0 : 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      // The pending item is de-emphasized (muted), not
                      // accented — past events get the solid ink.
                      color: current
                          ? AppTheme.mutedLabel(theme.brightness)
                          : null,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      style: TextStyle(
                        fontSize: 12,
                        color: AppTheme.mutedLabel(theme.brightness),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Pinned actions; visibility by status: acknowledged alerts can't be
/// re-acked, snoozed ones can't be re-snoozed (cap is server policy).
class _Actions extends StatelessWidget {
  final LeadAlert alert;
  final VoidCallback onFileReport;
  final VoidCallback onAck;
  final VoidCallback onSnooze;

  const _Actions({
    required this.alert,
    required this.onFileReport,
    required this.onAck,
    required this.onSnooze,
  });

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final showAck = alert.status != AlertStatus.ack;
    final showSnooze = alert.status != AlertStatus.snoozed;

    Widget pill(String label, VoidCallback onTap) => OutlinedButton(
          style: OutlinedButton.styleFrom(
            shape: const StadiumBorder(),
            side: BorderSide(color: theme.colorScheme.outlineVariant),
            backgroundColor: theme.cardTheme.color,
            foregroundColor: theme.colorScheme.onSurface,
            minimumSize: const Size(0, 44),
            textStyle:
                const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          onPressed: onTap,
          child: Text(label),
        );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: double.infinity,
          height: 48,
          child: FilledButton(
            onPressed: onFileReport,
            child: Text(
              l.fileVisitReportFor(alert.accountName.split(' ').first),
            ),
          ),
        ),
        if (showAck || showSnooze) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              if (showAck) Expanded(child: pill(l.acknowledgeButton, onAck)),
              if (showAck && showSnooze) const SizedBox(width: 10),
              if (showSnooze) Expanded(child: pill(l.snoozeButton, onSnooze)),
            ],
          ),
        ],
      ],
    );
  }
}
