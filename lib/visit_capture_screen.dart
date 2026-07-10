import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';

import 'customers_repository.dart';
import 'entity_avatar.dart';
import 'l10n/app_localizations.dart';
import 'models/tracking_models.dart';
import 'theme.dart';

/// Visit-report capture (design screen 05). Entry contexts:
/// - Home FAB: nothing pre-filled — the user picks the customer.
/// - Alert "File report": [initialCustomer] + [initialLeadIds] pre-set.
/// - Geofence-exit push (future): additionally passes [detected] = true,
///   which renders the green "Detected" pill (geofence match, per the
///   design doc — not a generic "pre-filled" marker).
/// The recorder card is a visual placeholder until the recording step.
class VisitCaptureScreen extends StatefulWidget {
  final Customer? initialCustomer;
  final List<String> initialLeadIds;
  final bool detected;

  const VisitCaptureScreen({
    super.key,
    this.initialCustomer,
    this.initialLeadIds = const [],
    this.detected = false,
  });

  @override
  State<VisitCaptureScreen> createState() => _VisitCaptureScreenState();
}

class _VisitCaptureScreenState extends State<VisitCaptureScreen> {
  static const _notesMaxLength = 5000;

  Customer? _customer;
  bool _detected = false;
  List<Lead> _leads = const [];
  final Set<String> _selectedLeadIds = {};
  final TextEditingController _notes = TextEditingController();

  ReportPosition? _position;
  String? _address;
  bool _fetchingPosition = true;

  @override
  void initState() {
    super.initState();
    _customer = widget.initialCustomer;
    _detected = widget.detected && widget.initialCustomer != null;
    _selectedLeadIds.addAll(widget.initialLeadIds);
    if (_customer != null) _loadLeads(_customer!.id);
    _fetchPosition();
  }

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  Future<void> _loadLeads(String customerId) async {
    final leads = await CustomersRepository.instance.leadsForCustomer(
      customerId,
    );
    if (mounted) setState(() => _leads = leads);
  }

  /// Auto-captured report position (§2.3.3). Check-then-request: capture is
  /// a legitimate moment to ask, but a denial just leaves the card in the
  /// unavailable state — the report submits without a position.
  Future<void> _fetchPosition() async {
    setState(() {
      _fetchingPosition = true;
      _position = null;
      _address = null;
    });
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        if (mounted) setState(() => _fetchingPosition = false);
        return;
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      ).timeout(const Duration(seconds: 15));
      if (mounted) {
        setState(() {
          _position = ReportPosition(
            latitude: pos.latitude,
            longitude: pos.longitude,
            accuracyMeters: pos.accuracy,
          );
          _fetchingPosition = false;
        });
        _reverseGeocode(pos.latitude, pos.longitude); // best-effort, async
      }
    } catch (_) {
      if (mounted) setState(() => _fetchingPosition = false);
    }
  }

  /// Best-effort street address for display; coords remain the fallback and
  /// the source of truth (only report_position is submitted, §4.4).
  Future<void> _reverseGeocode(double lat, double lng) async {
    try {
      final marks = await placemarkFromCoordinates(
        lat,
        lng,
      ).timeout(const Duration(seconds: 8));
      final m = marks.firstOrNull;
      if (m == null) return;
      final parts = <String>[
        for (final p in [m.street, m.subLocality, m.locality])
          if (p != null && p.trim().isNotEmpty) p.trim(),
      ];
      // Dedupe (street/subLocality often repeat) and keep the top two.
      final address = parts.toSet().take(2).join(', ');
      if (mounted && address.isNotEmpty) setState(() => _address = address);
    } catch (_) {
      // Network/geocoder unavailable — coords stay shown.
    }
  }

  Future<void> _pickCustomer() async {
    final picked = await showModalBottomSheet<Customer>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _CustomerPickerSheet(),
    );
    if (picked != null && picked.id != _customer?.id) {
      setState(() {
        _customer = picked;
        _detected = false; // user choice overrides any detection
        _leads = const [];
        _selectedLeadIds.clear(); // old customer's leads are meaningless
      });
      _loadLeads(picked.id);
    }
  }

  void _toggleLead(Lead lead) => setState(() {
    if (!_selectedLeadIds.remove(lead.id)) _selectedLeadIds.add(lead.id);
  });

  Future<void> _openLeadSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      builder:
          (_) => _LeadSheet(
            leads: _leads,
            selected: _selectedLeadIds,
            onToggle: _toggleLead,
          ),
    );
    setState(() {}); // reflect sheet toggles
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);

    Widget sectionLabel(String text) => Padding(
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

    return Scaffold(
      appBar: AppBar(
        title: Text(
          l.newVisitReportTitle,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.pop(context), // discard guard: next step
          ),
        ],
      ),
      body: Scrollbar(
        child: ListView(
          padding: const EdgeInsets.all(16),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          children: [
            sectionLabel(l.customerLabel),
            _CustomerCard(
              customer: _customer,
              detected: _detected,
              onTap: _pickCustomer,
            ),
            if (_customer != null && _leads.isNotEmpty) ...[
              const SizedBox(height: 20),
              sectionLabel(
                _selectedLeadIds.isEmpty
                    ? l.leadsLabel
                    : l.advancingLeads(_selectedLeadIds.length),
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final lead in _leads)
                    _LeadPill(
                      lead: lead,
                      selected: _selectedLeadIds.contains(lead.id),
                      onTap: () => _toggleLead(lead),
                    ),
                  _AddLeadChip(onTap: _openLeadSheet),
                ],
              ),
            ],
            const SizedBox(height: 20),
            const _RecorderPlaceholder(),
            const SizedBox(height: 20),
            sectionLabel(l.notesLabel),
            Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 4,
                ),
                child: TextField(
                  controller: _notes,
                  maxLines: 6,
                  minLines: 3,
                  inputFormatters: [
                    LengthLimitingTextInputFormatter(_notesMaxLength),
                  ],
                  decoration: InputDecoration(
                    hintText: l.notesHint,
                    border: InputBorder.none,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 20),
            sectionLabel(l.locationLabel),
            _LocationCard(
              position: _position,
              address: _address,
              fetching: _fetchingPosition,
              onRefresh: _fetchPosition,
            ),
          ],
        ),
      ),
      // Ride above the keyboard: Scaffold doesn't apply the IME inset to
      // bottomNavigationBar, so the keyboard would cover the Submit button.
      bottomNavigationBar: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              width: double.infinity,
              height: 48,
              child: FilledButton(
                onPressed: null, // enabled with validation in the submit step
                child: Text(l.submitReportButton),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CustomerCard extends StatelessWidget {
  final Customer? customer;
  final bool detected;
  final VoidCallback onTap;

  const _CustomerCard({
    required this.customer,
    required this.detected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);

    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppTheme.cardRadius),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child:
              customer == null
                  ? Row(
                    children: [
                      Icon(
                        Icons.search,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          l.selectCustomerHint,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      Icon(
                        Icons.chevron_right,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ],
                  )
                  : Row(
                    children: [
                      EntityAvatar(
                        name: customer!.name,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              customer!.name,
                              style: theme.textTheme.bodyLarge?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              customer!.address,
                              style: TextStyle(
                                fontSize: 13,
                                color: AppTheme.mutedLabel(theme.brightness),
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (detected) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: AppTheme.success.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            l.detectedPill,
                            style: const TextStyle(
                              color: AppTheme.success,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
        ),
      ),
    );
  }
}

/// Searchable customer list (Odoo-sourced via the platform); pops with the
/// picked [Customer].
class _CustomerPickerSheet extends StatefulWidget {
  const _CustomerPickerSheet();

  @override
  State<_CustomerPickerSheet> createState() => _CustomerPickerSheetState();
}

class _CustomerPickerSheetState extends State<_CustomerPickerSheet> {
  List<Customer>? _customers;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final customers = await CustomersRepository.instance.myCustomers();
    if (mounted) setState(() => _customers = customers);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final query = _query.trim().toLowerCase();
    final visible =
        (_customers ?? [])
            .where(
              (c) =>
                  query.isEmpty ||
                  c.name.toLowerCase().contains(query) ||
                  c.address.toLowerCase().contains(query),
            )
            .toList();

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.6,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: TextField(
                  autofocus: false,
                  onChanged: (v) => setState(() => _query = v),
                  decoration: InputDecoration(
                    hintText: l.searchCustomersHint,
                    prefixIcon: const Icon(Icons.search),
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
              ),
              Expanded(
                child:
                    _customers == null
                        ? const Center(child: CircularProgressIndicator())
                        : ListView.builder(
                          itemCount: visible.length,
                          itemBuilder: (context, i) {
                            final c = visible[i];
                            return ListTile(
                              leading: EntityAvatar(
                                name: c.name,
                                color: theme.colorScheme.primary,
                              ),
                              title: Text(
                                c.name,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              subtitle: Text(
                                c.address,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: AppTheme.mutedLabel(theme.brightness),
                                ),
                              ),
                              onTap: () => Navigator.pop(context, c),
                            );
                          },
                        ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Toggleable lead pill: selected = primary with a check, unselected =
/// outlined card surface.
class _LeadPill extends StatelessWidget {
  final Lead lead;
  final bool selected;
  final VoidCallback onTap;

  const _LeadPill({
    required this.lead,
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
          border:
              selected
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
              lead.title,
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
  final Set<String> selected;
  final void Function(Lead) onToggle;

  const _LeadSheet({
    required this.leads,
    required this.selected,
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
              value: widget.selected.contains(lead.id),
              title: Text(lead.title),
              controlAffinity: ListTileControlAffinity.leading,
              onChanged: (_) => setState(() => widget.onToggle(lead)),
            ),
        ],
      ),
    );
  }
}

/// Idle-only visual until the recording step replaces it.
class _RecorderPlaceholder extends StatelessWidget {
  const _RecorderPlaceholder();

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: AppTheme.recording,
              ),
              child: const Icon(Icons.mic, color: Colors.white, size: 30),
            ),
            const SizedBox(height: 12),
            Text(
              l.tapToRecord,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LocationCard extends StatelessWidget {
  final ReportPosition? position;
  final String? address;
  final bool fetching;
  final VoidCallback onRefresh;

  const _LocationCard({
    required this.position,
    required this.address,
    required this.fetching,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;

    final Widget content;
    if (fetching) {
      content = Row(
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 12),
          Text(l.gettingLocation, style: TextStyle(color: muted)),
        ],
      );
    } else if (position == null) {
      content = Row(
        children: [
          Icon(Icons.location_off_outlined, size: 18, color: muted),
          const SizedBox(width: 12),
          Expanded(
            child: Text(l.locationUnavailable, style: TextStyle(color: muted)),
          ),
        ],
      );
    } else {
      final p = position!;
      final coords =
          '${p.latitude.toStringAsFixed(5)}, ${p.longitude.toStringAsFixed(5)}';
      final good = p.accuracyMeters <= 20;
      final accColor = good ? AppTheme.success : AppTheme.warning;
      final accWord = good ? l.accuracyGood : l.accuracyApprox;

      content = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.place_outlined,
            size: 18,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Primary: address when we have it, else the coords.
                Text(
                  address ?? coords,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                // Demoted coords small print (only when an address is shown).
                if (address != null) ...[
                  const SizedBox(height: 2),
                  Text(coords, style: TextStyle(fontSize: 11, color: muted)),
                ],
                const SizedBox(height: 6),
                Row(
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: accColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '$accWord · ±${p.accuracyMeters.round()} m',
                      style: TextStyle(fontSize: 12, color: muted),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      );
    }

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: content),
            IconButton(
              icon: const Icon(Icons.refresh, size: 20),
              onPressed: fetching ? null : onRefresh,
            ),
          ],
        ),
      ),
    );
  }
}
