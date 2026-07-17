import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'entity_avatar.dart';
import 'l10n/app_localizations.dart';
import 'models/tracking_models.dart';
import 'report_detail_screen.dart';
import 'reports_repository.dart';
import 'status_chip.dart';
import 'theme.dart';
import 'upload_queue.dart';

/// Orthogonal report filters; they combine with AND. "All" is not a filter —
/// it's the empty set.
enum _ReportFilter { thisWeek, ready, audio }

/// Reports history tab (design screen 07): filter chips over report cards
/// with avatar, name (+ audio glyph), relative time/dwell or the no-geofence
/// note, and a status chip. Queued cards get an amber border.
class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  List<ReportEntry>? _reports;
  bool _error = false;
  final Set<_ReportFilter> _active = {};

  @override
  void initState() {
    super.initState();
    _load();
    ReportsRepository.instance.changes.addListener(_load);
    UploadQueue.instance.changes.addListener(_onQueueChanged);
  }

  @override
  void dispose() {
    ReportsRepository.instance.changes.removeListener(_load);
    UploadQueue.instance.changes.removeListener(_onQueueChanged);
    super.dispose();
  }

  void _onQueueChanged() {
    if (mounted) setState(() {}); // re-read UploadQueue.items
  }

  Future<void> _load() async {
    try {
      final reports = await ReportsRepository.instance.reports();
      if (mounted) setState(() => _reports = reports);
    } catch (_) {
      if (mounted) setState(() => _error = true);
    }
  }

  void _toggle(_ReportFilter f) => setState(() {
    if (!_active.remove(f)) _active.add(f);
  });

  /// Server reports open the detail; queue rows act on the queue instead —
  /// queued/uploading aren't yet editable (mid-upload), and a failed upload
  /// offers a retry. Their `id` is an idempotency key, never a server report
  /// id, so these branches must come before the detail navigation.
  void _openReport(BuildContext context, ReportEntry r) {
    final l = AppLocalizations.of(context)!;
    if (r.status == ReportStatus.uploadFailed) {
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(l.uploadFailedTitle),
          content: Text(l.uploadFailedMessage),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(l.cancelButton),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                UploadQueue.instance.retryFailed(r.id!); // idempotency key
              },
              child: Text(l.retryButton),
            ),
          ],
        ),
      );
    } else if (r.status == ReportStatus.queued ||
        r.status == ReportStatus.uploading) {
      showDialog<void>(
        context: context,
        builder:
            (ctx) => AlertDialog(
              title: Text(l.stillUploadingTitle),
              content: Text(l.stillUploadingMessage),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(l.okButton),
                ),
              ],
            ),
      );
    } else if (r.id != null) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => ReportDetailScreen(reportId: r.id!)),
      );
    }
  }

  /// "This week" = current calendar week starting Monday.
  List<ReportEntry> _visible(List<ReportEntry> all) {
    var result = all;
    if (_active.contains(_ReportFilter.thisWeek)) {
      final now = DateTime.now();
      final monday = DateTime(
        now.year,
        now.month,
        now.day,
      ).subtract(Duration(days: now.weekday - 1));
      result = result.where((r) => !r.createdAt.isBefore(monday)).toList();
    }
    if (_active.contains(_ReportFilter.ready)) {
      result = result.where((r) => r.status == ReportStatus.ready).toList();
    }
    if (_active.contains(_ReportFilter.audio)) {
      result = result.where((r) => r.hasAudio).toList();
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;

    final Widget content;
    if (_error) {
      content = _Message(l.reportsLoadError);
    } else if (_reports == null) {
      content = const _SkeletonList();
    } else {
      // Local queue (queued/uploading) + server history, newest first —
      // matches "merge the local upload queue with the server list".
      final all = [
        ...UploadQueue.instance.items.map(ReportEntry.fromQueued),
        ..._reports!,
      ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));

      if (all.isEmpty) {
        content = _Message(l.noReportsYet);
      } else {
        final visible = _visible(all);
        content =
            visible.isEmpty
                ? _Message(l.noMatchingReports)
                : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: visible.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 12),
                  itemBuilder:
                      (context, i) => _ReportCard(
                        report: visible[i],
                        onTap: () => _openReport(context, visible[i]),
                      ),
                );
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(l.reportsTitle),
        actions: [
          // Full filter sheet is future work; the chips row is the filter UI.
          IconButton(
            icon: const Icon(Icons.filter_alt_outlined),
            onPressed: () {},
          ),
        ],
      ),
      body: Column(
        children: [
          _FilterRow(
            active: _active,
            onToggle: _toggle,
            onClear: () => setState(_active.clear),
          ),
          Expanded(child: content),
        ],
      ),
    );
  }
}

class _FilterRow extends StatelessWidget {
  final Set<_ReportFilter> active;
  final void Function(_ReportFilter) onToggle;
  final VoidCallback onClear;

  const _FilterRow({
    required this.active,
    required this.onToggle,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: Row(
        children: [
          _FilterChip(
            label: l.filterAll,
            selected: active.isEmpty,
            onTap: onClear,
          ),
          const SizedBox(width: 8),
          for (final (f, label, icon) in [
            (_ReportFilter.thisWeek, l.filterThisWeek, null),
            (_ReportFilter.ready, l.filterReady, null),
            (_ReportFilter.audio, l.filterAudio, Icons.headphones),
          ]) ...[
            _FilterChip(
              label: label,
              icon: icon,
              selected: active.contains(f),
              onTap: () => onToggle(f),
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }
}

/// Pill chip: selected = flat primary with white text, unselected = card
/// surface with a hairline border and muted text.
class _FilterChip extends StatelessWidget {
  final String label;
  final IconData? icon;
  final bool selected;
  final VoidCallback onTap;

  const _FilterChip({
    required this.label,
    this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fg = selected ? Colors.white : theme.colorScheme.onSurfaceVariant;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? theme.colorScheme.primary : theme.cardTheme.color,
          borderRadius: BorderRadius.circular(999),
          border:
              selected
                  ? null
                  : Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 14, color: fg),
              const SizedBox(width: 4),
            ],
            Text(
              label,
              style: TextStyle(
                color: fg,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReportCard extends StatelessWidget {
  final ReportEntry report;
  final VoidCallback onTap;

  const _ReportCard({required this.report, required this.onTap});

  /// "12:04 today" / "Yesterday" / "Jun 27" — rules inferred from the mock.
  String _when(BuildContext context, AppLocalizations l) {
    final now = DateTime.now();
    final d = report.createdAt;
    if (DateUtils.isSameDay(d, now)) {
      final time = MaterialLocalizations.of(
        context,
      ).formatTimeOfDay(TimeOfDay.fromDateTime(d));
      return l.timeToday(time);
    }
    if (DateUtils.isSameDay(d, now.subtract(const Duration(days: 1)))) {
      return l.yesterdayLabel;
    }
    return DateFormat.MMMd(
      Localizations.localeOf(context).toString(),
    ).format(d);
  }

  String _subtitle(BuildContext context, AppLocalizations l) {
    if (!report.geofencePresent) return l.noGeofenceNote;
    final when = _when(context, l);
    if (report.dwell != null) {
      return '$when · ${l.dwellMinutes(report.dwell!.inMinutes)}';
    }
    // No dwell (e.g. still in the local queue): describe the content instead.
    final content = switch ((report.hasAudio, report.hasNotes)) {
      (true, true) => l.contentAudioNotes,
      (true, false) => l.contentAudio,
      (false, true) => l.contentNotes,
      (false, false) => null,
    };
    return content == null ? when : '$when · $content';
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final queued = report.status == ReportStatus.queued;
    final accent = queued ? AppTheme.warning : theme.colorScheme.primary;

    return Card(
      margin: EdgeInsets.zero,
      shape:
          queued
              ? RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppTheme.cardRadius),
                side: BorderSide(
                  color: AppTheme.warning.withValues(alpha: 0.5),
                ),
              )
              : null,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTheme.cardRadius),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              EntityAvatar(name: report.customerName, color: accent),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            report.customerName,
                            style: theme.textTheme.bodyLarge?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (report.hasAudio)
                          Padding(
                            padding: const EdgeInsets.only(left: 4),
                            child: Icon(
                              Icons.headphones,
                              size: 14,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _subtitle(context, l),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              StatusChip(status: report.status),
            ],
          ),
        ),
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
    Widget bar(double width) => Container(
      width: width,
      height: 12,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(6),
      ),
    );
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: 3,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder:
          (_, _) => Card(
            margin: EdgeInsets.zero,
            child: Padding(
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
          ),
    );
  }
}
