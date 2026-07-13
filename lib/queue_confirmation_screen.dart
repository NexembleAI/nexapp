import 'package:flutter/material.dart';

import 'app_shell.dart';
import 'connectivity_service.dart';
import 'l10n/app_localizations.dart';
import 'models/tracking_models.dart';
import 'status_chip.dart';
import 'theme.dart';
import 'upload_queue.dart';

/// Post-submit confirmation (design screen 06): offline banner, "saved — will
/// upload" hero, and the live upload queue. Reached via pushReplacement from
/// the capture screen.
class QueueConfirmationScreen extends StatelessWidget {
  final String customerName;

  const QueueConfirmationScreen({super.key, required this.customerName});

  void _backToHome(BuildContext context) {
    Navigator.of(context).popUntil((r) => r.isFirst);
    shellTabRequest.value = 0; // Home
  }

  void _viewAllReports(BuildContext context) {
    Navigator.of(context).popUntil((r) => r.isFirst);
    shellTabRequest.value = 1; // Reports
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // Offline banner — reacts to connectivity.
            ListenableBuilder(
              listenable: ConnectivityService.instance.changes,
              builder: (context, _) => ConnectivityService.instance.isOnline
                  ? const SizedBox.shrink()
                  : Container(
                      width: double.infinity,
                      color: AppTheme.warning.withValues(alpha: 0.15),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.cloud_off,
                            size: 16,
                            color: AppTheme.warning,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              l.offlineBanner,
                              style: const TextStyle(
                                color: AppTheme.warning,
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  const SizedBox(height: 16),
                  Center(
                    child: Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppTheme.warning.withValues(alpha: 0.14),
                      ),
                      child: const Icon(
                        Icons.cloud_upload_outlined,
                        color: AppTheme.warning,
                        size: 34,
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    l.queueSavedTitle,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  // Copy reflects connectivity: "uploading now" vs "when you
                  // reconnect".
                  ListenableBuilder(
                    listenable: ConnectivityService.instance.changes,
                    builder: (context, _) => Text(
                      ConnectivityService.instance.isOnline
                          ? l.queueSavedBodyOnline(customerName)
                          : l.queueSavedBody(customerName),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const SizedBox(height: 28),
                  // Live queue.
                  ListenableBuilder(
                    listenable: UploadQueue.instance.changes,
                    builder: (context, _) {
                      final items = UploadQueue.instance.items;
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${l.uploadQueueLabel.toUpperCase()} · ${items.length}',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: AppTheme.mutedLabel(theme.brightness),
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.8,
                            ),
                          ),
                          const SizedBox(height: 8),
                          if (items.isEmpty)
                            _MessageCard(l.queueEmpty)
                          else
                            Card(
                              margin: EdgeInsets.zero,
                              child: Column(
                                children: [
                                  for (final (i, item) in items.indexed) ...[
                                    if (i > 0)
                                      const Divider(height: 1, indent: 16),
                                    _QueueRow(item: item),
                                  ],
                                ],
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: FilledButton(
                      onPressed: () => _backToHome(context),
                      child: Text(l.backToHomeButton),
                    ),
                  ),
                  TextButton(
                    onPressed: () => _viewAllReports(context),
                    child: Text(l.viewAllReportsButton),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QueueRow extends StatelessWidget {
  final QueuedReport item;

  const _QueueRow({required this.item});

  String _fmtBytes(int b) => b < 1024
      ? '$b B'
      : b < 1024 * 1024
          ? '${(b / 1024).round()} KB'
          : '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final content = switch ((item.hasAudio, item.hasNotes)) {
      (true, true) => l.contentAudioNotes,
      (true, false) => l.contentAudio,
      (false, true) => l.contentNotes,
      (false, false) => null,
    };
    final size = item.audioSizeBytes != null
        ? _fmtBytes(item.audioSizeBytes!)
        : null;
    final subtitle = [content, size].whereType<String>().join(' · ');
    final chipStatus = item.status == QueueStatus.uploading
        ? ReportStatus.uploading
        : ReportStatus.queued;

    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.customerName,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (subtitle.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              StatusChip(status: chipStatus),
            ],
          ),
          if (item.status == QueueStatus.uploading) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: item.progress,
                minHeight: 4,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _MessageCard extends StatelessWidget {
  final String message;

  const _MessageCard(this.message);

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
