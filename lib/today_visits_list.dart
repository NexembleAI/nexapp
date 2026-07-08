import 'package:flutter/material.dart';

import 'entity_avatar.dart';
import 'l10n/app_localizations.dart';
import 'models/tracking_models.dart';
import 'reports_repository.dart';
import 'status_chip.dart';
import 'theme.dart';

/// "Today's visits" section on Home (design screen 04): section label and a
/// card of visit rows — initials avatar, customer, entry time + dwell, and a
/// status chip. Loading shows skeleton rows; empty and error states show a
/// short message instead of the list.
class TodayVisitsList extends StatefulWidget {
  const TodayVisitsList({super.key});

  @override
  State<TodayVisitsList> createState() => _TodayVisitsListState();
}

class _TodayVisitsListState extends State<TodayVisitsList> {
  List<VisitEntry>? _visits;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final visits = await ReportsRepository.instance.todayVisits();
      if (mounted) setState(() => _visits = visits);
    } catch (_) {
      if (mounted) setState(() => _error = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);

    final Widget body;
    if (_error) {
      body = _MessageCard(message: l.visitsLoadError);
    } else if (_visits == null) {
      body = const _SkeletonCard();
    } else if (_visits!.isEmpty) {
      body = _MessageCard(message: l.noVisitsToday);
    } else {
      body = Card(
        margin: EdgeInsets.zero,
        child: Column(
          children: [
            for (final (i, visit) in _visits!.indexed) ...[
              if (i > 0) const Divider(height: 1, indent: 68),
              _VisitRow(visit: visit),
            ],
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l.todaysVisitsTitle.toUpperCase(),
          style: theme.textTheme.labelSmall?.copyWith(
            color: AppTheme.mutedLabel(theme.brightness),
            fontWeight: FontWeight.w600,
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(height: 8),
        body,
      ],
    );
  }
}

class _VisitRow extends StatelessWidget {
  final VisitEntry visit;

  const _VisitRow({required this.visit});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final time = MaterialLocalizations.of(context)
        .formatTimeOfDay(TimeOfDay.fromDateTime(visit.enteredAt));

    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          EntityAvatar(
            name: visit.customerName,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  visit.customerName,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '$time · ${l.dwellMinutes(visit.dwell.inMinutes)}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          StatusChip(status: visit.status),
        ],
      ),
    );
  }
}

class _MessageCard extends StatelessWidget {
  final String message;

  const _MessageCard({required this.message});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          message,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class _SkeletonCard extends StatelessWidget {
  const _SkeletonCard();

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.surfaceContainerHighest;
    Widget bar(double width) => Container(
          width: width,
          height: 12,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(6),
          ),
        );
    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        children: [
          for (var i = 0; i < 2; i++)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [bar(140), const SizedBox(height: 6), bar(90)],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
