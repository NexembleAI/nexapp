import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'audio_player_bar.dart';
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
  // Transcript arrives async (submitted -> transcribing -> ready/failed): poll
  // GetVisitReport while pending, bounded so a stuck transcribe can't poll
  // forever (§3.4).
  static const _pollInterval = Duration(seconds: 5);
  static const _pollCap = Duration(minutes: 2);

  ReportDetail? _detail;
  bool _error = false;

  final TextEditingController _notes = TextEditingController();
  final FocusNode _notesFocus = FocusNode();
  Set<String> _selectedLeadIds = {};
  bool _saving = false;

  // A generation counter + a single self-chaining loop (never Timer.periodic):
  // polls can't overlap, and a delayed response from a superseded generation is
  // dropped so a stale TRANSCRIBING can't regress a READY transcript/status.
  int _pollGen = 0;
  bool _pollActive = false;

  @override
  void initState() {
    super.initState();
    _load();
    _notes.addListener(_onChange);
    _notesFocus.addListener(_onChange);
  }

  @override
  void dispose() {
    _stopPolling();
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
      if (mounted) {
        setState(() {
          _detail = d;
          _notes.text = d.notes;
          _selectedLeadIds = {...d.leadIds};
        });
        _maybeStartPolling();
      }
    } catch (_) {
      if (mounted) setState(() => _error = true);
    }
  }

  /// Poll the transcript/status while the report is still processing; stop once
  /// it's terminal (ready / transcript_failed), disposed, or the cap elapses.
  /// Starts the single self-chaining loop; a no-op while one is already active.
  void _maybeStartPolling() {
    final d = _detail;
    // Only an audio report gains a transcript, so a text-only report is never
    // "pending" — don't spin the poll for it (it would never resolve).
    final pending = d != null &&
        d.audioPresent &&
        (d.status == ReportStatus.submitted ||
            d.status == ReportStatus.transcribing);
    if (!pending) {
      _stopPolling();
      return;
    }
    if (_pollActive) return;
    _pollActive = true;
    // Fire-and-forget: the loop chains its own delays and owns _pollActive.
    _pollLoop(++_pollGen);
  }

  /// One poll at a time, bounded by [_pollCap]. Tagged with [gen] so a poll from
  /// a superseded generation (dispose / a newer start) drops its response before
  /// touching state — a stale in-flight response can never regress a newer one.
  Future<void> _pollLoop(int gen) async {
    final deadline = DateTime.now().add(_pollCap);
    while (mounted && gen == _pollGen && DateTime.now().isBefore(deadline)) {
      await Future.delayed(_pollInterval);
      if (!mounted || gen != _pollGen) break;
      ReportStatusUpdate upd;
      try {
        upd = await ReportsRepository.instance.reportStatus(widget.reportId);
      } catch (_) {
        continue; // transient — keep polling until the cap
      }
      if (!mounted || gen != _pollGen) break;
      // Only the volatile bits change — never clobber the user's in-progress
      // note / lead edits.
      setState(() =>
          _detail = _detail?.copyWith(status: upd.status, transcript: upd.transcript));
      if (upd.status != ReportStatus.submitted &&
          upd.status != ReportStatus.transcribing) {
        break;
      }
    }
    if (gen == _pollGen) _pollActive = false;
  }

  void _stopPolling() {
    // Bump the generation so any in-flight poll drops its response; the loop's
    // own guard then exits.
    _pollGen++;
    _pollActive = false;
  }

  bool get _hasChanges =>
      _detail != null &&
      (_notes.text.trim() != _detail!.notes ||
          !_sameLeads(_selectedLeadIds, _detail!.leadIds));

  /// UpdateVisitReport has NO server-side content check (unlike Submit) — an
  /// empty textBody genuinely clears the column via NULLIF, so an audio-less
  /// report must not be saveable with empty notes (that would wipe its only
  /// content). An audio report may clear its notes freely.
  bool get _canSave =>
      _hasChanges && (_detail!.audioPresent || _notes.text.trim().isNotEmpty);

  static bool _sameLeads(Set<String> a, List<String> b) =>
      a.length == b.toSet().length && a.containsAll(b);

  Future<void> _save() async {
    if (_saving || !_canSave) return;
    setState(() => _saving = true);
    try {
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
      // The refetch may carry a changed status; re-arm the transcript poll off it.
      _maybeStartPolling();
    } catch (_) {
      // The real repo throws on a failed PUT/refetch (the mock never did) —
      // without this the spinner wedges forever and the exception escapes
      // unhandled. Release the spinner and offer a retry via a snackbar.
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context)!.reportSubmitFailed),
        ),
      );
    }
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

    // Author-only edit (§3.5): a non-author (e.g. a manager) sees the report
    // read-only — no editable notes, no lead toggles, no Save bar.
    final editable = d.editable;

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
              AudioPlayerBar(
                // Streamed on demand — resolves + decodes on first play only.
                resolve: () =>
                    ReportsRepository.instance.reportAudio(widget.reportId),
              ),
              const SizedBox(height: 20),
            ],
            _sectionLabel(context, l.transcriptLabel),
            _Card(child: _transcript(context, d)),
            const SizedBox(height: 20),
            _sectionLabel(
              context,
              l.notesLabel,
              trailing: (editable && _notesFocus.hasFocus)
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
              // Lock inputs during a save: the post-save refetch overwrites the
              // controllers, so an edit made mid round-trip would be silently
              // discarded.
              readOnly: !editable || _saving,
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
              leads: d.leadOptions,
              selectedIds: _selectedLeadIds,
              // Locked mid-save for the same reason as the notes field: the
              // refetch overwrites _selectedLeadIds.
              enabled: editable && !_saving,
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
        bottomNavigationBar: editable
            ? SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      if (_hasChanges)
                        Text(
                          l.unsavedChanges,
                          style: TextStyle(
                              color: theme.colorScheme.onSurfaceVariant),
                        ),
                      const Spacer(),
                      FilledButton(
                        onPressed: (_canSave && !_saving) ? _save : null,
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
              )
            : null,
      ),
    );
  }

  Widget _transcript(BuildContext context, ReportDetail d) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    if (d.transcript != null && d.transcript!.isNotEmpty) {
      return Text(d.transcript!, style: theme.textTheme.bodyMedium);
    }
    // No transcript text. "Pending" is only honest while an audio report is
    // still being transcribed — a text-only report has nothing to transcribe,
    // and a finished (ready/failed) report that produced no text is done, not
    // pending. Otherwise the message never resolves and misleads the user.
    final String msg;
    if (!d.audioPresent) {
      msg = l.transcriptNoAudio;
    } else if (d.status == ReportStatus.submitted ||
        d.status == ReportStatus.transcribing) {
      msg = l.transcriptPending; // audio present, still processing
    } else {
      msg = l.transcriptUnavailable; // failed, or finished with no speech
    }
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
