import 'package:flutter/material.dart';

import 'l10n/app_localizations.dart';
import 'models/tracking_models.dart';
import 'theme.dart';

/// Status chip per the design's status semantics: green = ready, amber =
/// in-flight or needs attention (queued/uploading/transcribing/failed),
/// primary = submitted, muted = archived.
class StatusChip extends StatelessWidget {
  final ReportStatus status;

  const StatusChip({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final (color, label) = switch (status) {
      ReportStatus.ready => (AppTheme.success, l.statusReady),
      ReportStatus.transcribing => (AppTheme.warning, l.statusTranscribing),
      ReportStatus.queued => (AppTheme.warning, l.statusQueued),
      ReportStatus.uploading => (AppTheme.warning, l.statusUploading),
      ReportStatus.transcriptFailed =>
        (AppTheme.warning, l.statusTranscriptFailed),
      ReportStatus.submitted =>
        (Theme.of(context).colorScheme.primary, l.statusSubmitted),
      ReportStatus.archived =>
        (Theme.of(context).colorScheme.onSurfaceVariant, l.statusArchived),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style:
            TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600),
      ),
    );
  }
}
