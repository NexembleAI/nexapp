import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'audio_player_bar.dart';
import 'customers_repository.dart';
import 'l10n/app_localizations.dart';
import 'models/tracking_models.dart';
import 'reports_repository.dart';
import 'status_chip.dart';
import 'theme.dart';

/// Visit report detail / edit (design screen 08). This step: read-only view
/// (audio player, transcript, notes, leads, version row). Editing lands next.
class ReportDetailScreen extends StatefulWidget {
  final String reportId;

  const ReportDetailScreen({super.key, required this.reportId});

  @override
  State<ReportDetailScreen> createState() => _ReportDetailScreenState();
}

class _ReportDetailScreenState extends State<ReportDetailScreen> {
  static const _sampleAudio = 'assets/audio/sample_note.wav';

  ReportDetail? _detail;
  List<Lead> _customerLeads = const [];
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await ReportsRepository.instance.reportDetail(widget.reportId);
      final leads = await CustomersRepository.instance.leadsForCustomer(
        d.customerId,
      );
      if (mounted) {
        setState(() {
          _detail = d;
          _customerLeads = leads;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = true);
    }
  }

  String _meta(BuildContext context, ReportDetail d) {
    final locale = Localizations.localeOf(context).toString();
    final l = AppLocalizations.of(context)!;
    final date = DateFormat.MMMd(locale).format(d.createdAt);
    final time = MaterialLocalizations.of(
      context,
    ).formatTimeOfDay(TimeOfDay.fromDateTime(d.createdAt));
    final parts = [date, time];
    if (d.dwell != null) parts.add(l.dwellMinutes(d.dwell!.inMinutes));
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final d = _detail;

    if (_error) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Icon(Icons.error_outline)),
      );
    }
    if (d == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final taggedTitles = _customerLeads
        .where((lead) => d.leadIds.contains(lead.id))
        .map((lead) => lead.title)
        .toList();

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              d.customerName,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            Text(
              _meta(context, d),
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppTheme.mutedLabel(theme.brightness),
              ),
            ),
          ],
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(child: StatusChip(status: d.status)),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (d.audioPresent) ...[
            const AudioPlayerBar(assetPath: _sampleAudio),
            const SizedBox(height: 20),
          ],
          _sectionLabel(context, l.transcriptLabel),
          _Card(child: _transcript(context, d)),
          const SizedBox(height: 20),
          _sectionLabel(context, l.notesLabel),
          _Card(
            child: Text(
              d.notes.isEmpty ? '—' : d.notes,
              style: theme.textTheme.bodyMedium,
            ),
          ),
          const SizedBox(height: 20),
          _sectionLabel(context, l.leadsLabel),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final title in taggedTitles) _LeadChip(title: title),
              if (taggedTitles.isEmpty)
                Text(
                  '—',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
          if (d.edits.isNotEmpty) ...[
            const SizedBox(height: 20),
            _VersionRow(version: d.version, editCount: d.edits.length),
          ],
        ],
      ),
    );
  }

  Widget _transcript(BuildContext context, ReportDetail d) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    if (d.transcript != null && d.transcript!.isNotEmpty) {
      return Text(d.transcript!, style: theme.textTheme.bodyMedium);
    }
    final msg = d.status == ReportStatus.transcriptFailed
        ? l.transcriptUnavailable
        : l.transcriptPending;
    return Text(
      msg,
      style: theme.textTheme.bodyMedium?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
        fontStyle: FontStyle.italic,
      ),
    );
  }

  Widget _sectionLabel(BuildContext context, String text) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
          color: AppTheme.mutedLabel(theme.brightness),
          fontWeight: FontWeight.w600,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  final Widget child;

  const _Card({required this.child});

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    child: Padding(padding: const EdgeInsets.all(14), child: child),
  );
}

class _LeadChip extends StatelessWidget {
  final String title;

  const _LeadChip({required this.title});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        title,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 13,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

class _VersionRow extends StatelessWidget {
  final int version;
  final int editCount;

  const _VersionRow({required this.version, required this.editCount});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: Icon(
          Icons.history,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        title: Text('${l.editedTimes(editCount)} · v$version'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () {}, // version-history sheet lands in step 3
      ),
    );
  }
}
