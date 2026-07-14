import 'package:flutter/material.dart';

import 'l10n/app_localizations.dart';
import 'models/tracking_models.dart';

/// Editable lead tags: the customer's assigned leads as toggle pills + a
/// dashed "Add lead" chip opening an overflow sheet. Shared by the capture
/// and report-detail screens.
class LeadSelector extends StatelessWidget {
  final List<Lead> leads;
  final Set<String> selectedIds;
  final void Function(String leadId) onToggle;

  const LeadSelector({
    super.key,
    required this.leads,
    required this.selectedIds,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final lead in leads)
          _LeadPill(
            title: lead.title,
            selected: selectedIds.contains(lead.id),
            onTap: () => onToggle(lead.id),
          ),
        _AddLeadChip(onTap: () => _openSheet(context)),
      ],
    );
  }

  Future<void> _openSheet(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    builder: (_) => _LeadSheet(
      leads: leads,
      selectedIds: selectedIds,
      onToggle: onToggle,
    ),
  );
}

/// Toggleable lead pill: selected = primary with a check, unselected =
/// outlined card surface.
class _LeadPill extends StatelessWidget {
  final String title;
  final bool selected;
  final VoidCallback onTap;

  const _LeadPill({
    required this.title,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fg = selected ? Colors.white : theme.colorScheme.onSurface;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? theme.colorScheme.primary : theme.cardTheme.color,
          borderRadius: BorderRadius.circular(999),
          border: selected
              ? null
              : Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (selected) ...[
              const Icon(Icons.check, size: 14, color: Colors.white),
              const SizedBox(width: 4),
            ],
            Text(
              title,
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

class _AddLeadChip extends StatelessWidget {
  final VoidCallback onTap;

  const _AddLeadChip({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final fg = theme.colorScheme.onSurfaceVariant;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: CustomPaint(
        painter: _DashedPillBorder(color: theme.colorScheme.outlineVariant),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.add, size: 14, color: fg),
              const SizedBox(width: 4),
              Text(
                l.addLeadChip,
                style: TextStyle(
                  color: fg,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Dashed stadium (pill) outline for the "Add lead" chip.
class _DashedPillBorder extends CustomPainter {
  final Color color;

  _DashedPillBorder({required this.color});

  static const _dashWidth = 4.0;
  static const _dashGap = 3.0;
  static const _strokeWidth = 1.2;

  @override
  void paint(Canvas canvas, Size size) {
    final radius = size.height / 2; // stadium
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    );
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = _strokeWidth;
    for (final metric in (Path()..addRRect(rrect)).computeMetrics()) {
      var dist = 0.0;
      while (dist < metric.length) {
        final end = (dist + _dashWidth).clamp(0.0, metric.length);
        canvas.drawPath(metric.extractPath(dist, end), paint);
        dist += _dashWidth + _dashGap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedPillBorder old) => old.color != color;
}

/// Full lead list with checkboxes — the many-leads overflow of the inline
/// pills; shares the same selection set.
class _LeadSheet extends StatefulWidget {
  final List<Lead> leads;
  final Set<String> selectedIds;
  final void Function(String leadId) onToggle;

  const _LeadSheet({
    required this.leads,
    required this.selectedIds,
    required this.onToggle,
  });

  @override
  State<_LeadSheet> createState() => _LeadSheetState();
}

class _LeadSheetState extends State<_LeadSheet> {
  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          for (final lead in widget.leads)
            CheckboxListTile(
              value: widget.selectedIds.contains(lead.id),
              title: Text(lead.title),
              controlAffinity: ListTileControlAffinity.leading,
              onChanged: (_) => setState(() => widget.onToggle(lead.id)),
            ),
        ],
      ),
    );
  }
}
