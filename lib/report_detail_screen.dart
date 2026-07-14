import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'audio_player_bar.dart';
import 'customers_repository.dart';
import 'l10n/app_localizations.dart';
import 'lead_selector.dart';
import 'models/tracking_models.dart';
import 'reports_repository.dart';
import 'status_chip.dart';
import 'theme.dart';

/// Visit report detail / edit (design screen 08): audio player, transcript,
/// editable notes + leads, version history. Audio is play-only (immutable).
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

  final TextEditingController _notes = TextEditingController();
  final FocusNode _notesFocus = FocusNode();
  Set<String> _selectedLeadIds = {};
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
    _notes.addListener(_onChange);
    _notesFocus.addListener(_onChange);
  }

  @override
  void dispose() {
    _notes.dispose();
    _notesFocus.dispose();
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
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
          _notes.text = d.notes;
          _selectedLeadIds = {...d.leadIds};
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = true);
    }
  }

  bool get _hasChanges =>
      _detail != null &&
      (_notes.text.trim() != _detail!.notes ||
          !_sameLeads(_selectedLeadIds, _detail!.leadIds));

  static bool _sameLeads(Set<String> a, List<String> b) =>
      a.length == b.toSet().length && a.containsAll(b);

  Future<void> _save() async {
    if (_saving || !_hasChanges) return;
    setState(() => _saving = true);
    await ReportsRepository.instance.updateReport(
      widget.reportId,
      notes: _notes.text.trim(),
      leadIds: _selectedLeadIds.toList(),
    );
    final d = await ReportsRepository.instance.reportDetail(widget.reportId);
    if (!mounted) return;
    setState(() {
      _detail = d;
      _notes.text = d.notes;
      _selectedLeadIds = {...d.leadIds};
      _saving = false;
    });
  }

  Future<void> _confirmClose() async {
    final l = AppLocalizations.of(context)!;
    final discard = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.discardChangesTitle),
        content: Text(l.discardChangesMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l.cancelButton),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l.discardButton),
          ),
        ],
      ),
    );
    if (discard == true && mounted) Navigator.pop(context);
  }

  void _openHistory() {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final locale = Localizations.localeOf(context).toString();
    showModalBottomSheet<void>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                l.versionHistoryTitle,
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            for (final e in _detail!.edits.reversed)
              ListTile(
                leading: Text('v${e.version}'),
                title: Text(_fieldLabel(l, e.field)),
                subtitle: Text(
                  DateFormat.MMMd(locale).add_jm().format(e.editedAt),
                ),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  String _fieldLabel(AppLocalizations l, ReportEditField f) => switch (f) {
        ReportEditField.textBody => l.editFieldNotes,
        ReportEditField.leadTags => l.editFieldLeads,
        ReportEditField.audio => l.editFieldAudio,
      };

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

    return PopScope(
      canPop: !_hasChanges,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmClose();
      },
      child: Scaffold(
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
            _sectionLabel(
              context,
              l.notesLabel,
              trailing: _notesFocus.hasFocus
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.edit,
                            size: 13, color: theme.colorScheme.primary),
                        const SizedBox(width: 4),
                        Text(
                          l.editingLabel,
                          style: TextStyle(
                            color: theme.colorScheme.primary,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    )
                  : null,
            ),
            TextField(
              controller: _notes,
              focusNode: _notesFocus,
              minLines: 3,
              maxLines: null,
              onTapOutside: (_) => _notesFocus.unfocus(),
              decoration: InputDecoration(
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide(
                    color: theme.colorScheme.primary,
                    width: 1.5,
                  ),
                ),
                contentPadding: const EdgeInsets.all(14),
              ),
            ),
            const SizedBox(height: 20),
            _sectionLabel(context, l.leadsLabel),
            LeadSelector(
              leads: _customerLeads,
              selectedIds: _selectedLeadIds,
              onToggle: (id) => setState(() {
                _selectedLeadIds.contains(id)
                    ? _selectedLeadIds.remove(id)
                    : _selectedLeadIds.add(id);
              }),
            ),
            if (d.edits.isNotEmpty) ...[
              const SizedBox(height: 20),
              _VersionRow(
                version: d.version,
                editCount: d.edits.length,
                onTap: _openHistory,
              ),
            ],
          ],
        ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                if (_hasChanges)
                  Text(
                    l.unsavedChanges,
                    style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                  ),
                const Spacer(),
                FilledButton(
                  onPressed: (_hasChanges && !_saving) ? _save : null,
                  child: _saving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Text(l.saveChangesButton),
                ),
              ],
            ),
          ),
        ),
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

  Widget _sectionLabel(BuildContext context, String text, {Widget? trailing}) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Text(
            text.toUpperCase(),
            style: theme.textTheme.labelSmall?.copyWith(
              color: AppTheme.mutedLabel(theme.brightness),
              fontWeight: FontWeight.w600,
              letterSpacing: 0.8,
            ),
          ),
          const Spacer(),
          if (trailing != null) trailing,
        ],
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

class _VersionRow extends StatelessWidget {
  final int version;
  final int editCount;
  final VoidCallback onTap;

  const _VersionRow({
    required this.version,
    required this.editCount,
    required this.onTap,
  });

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
        onTap: onTap,
      ),
    );
  }
}
