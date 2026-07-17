import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:just_audio/just_audio.dart';
import 'package:record/record.dart';

import 'audio_recorder_service.dart';
import 'customers_repository.dart';
import 'entity_avatar.dart';
import 'l10n/app_localizations.dart';
import 'lead_selector.dart';
import 'models/tracking_models.dart';
import 'queue_confirmation_screen.dart';
import 'theme.dart';
import 'upload_queue.dart';

/// Opens capture pre-filled for an alert: its customer (resolved for the
/// address) and its lead pre-tagged. No "Detected" pill — an alert entry is
/// intent, not a geofence match.
Future<void> openCaptureForAlert(BuildContext context, LeadAlert alert) async {
  final customers = await CustomersRepository.instance.myCustomers();
  final customer =
      customers.where((c) => c.id == alert.customerId).firstOrNull ??
          Customer(id: alert.customerId, name: alert.accountName, address: '');
  if (!context.mounted) return;
  await Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => VisitCaptureScreen(
        initialCustomer: customer,
        initialLeadIds: [alert.leadId],
      ),
    ),
  );
}

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

  final AudioRecorderService _recorder = AudioRecorderService();
  ReportAudio? _audio;
  bool _submitting = false;
  bool _isRecording = false;

  @override
  void initState() {
    super.initState();
    _customer = widget.initialCustomer;
    _detected = widget.detected && widget.initialCustomer != null;
    _selectedLeadIds.addAll(widget.initialLeadIds);
    if (_customer != null) _loadLeads(_customer!.id);
    _notes.addListener(_onChange);
    _fetchPosition();
  }

  void _onChange() {
    if (mounted) setState(() {}); // re-evaluate Submit enablement
  }

  bool get _canSubmit =>
      _customer != null &&
      (_audio != null || _notes.text.trim().isNotEmpty) &&
      !_submitting &&
      !_isRecording; // can't submit mid-recording

  bool get _hasUnsaved =>
      _audio != null || _notes.text.trim().isNotEmpty || _isRecording;

  Future<void> _submit() async {
    if (_submitting) return;
    final l = AppLocalizations.of(context)!;
    // No-leads nudge only when the customer HAS taggable leads.
    if (_leads.isNotEmpty && _selectedLeadIds.isEmpty) {
      if (await _confirmNoLeads() != true) return;
      if (!mounted) return;
    }
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _submitting = true);
    final draft = ReportDraft(
      customerId: _customer!.id,
      leadIds: _selectedLeadIds.toList(),
      notes: _notes.text.trim(),
      audio: _audio,
      position: _position,
      idempotencyKey: ReportDraft.newIdempotencyKey(),
    );
    try {
      final customerName = _customer!.name;
      await UploadQueue.instance.enqueue(draft, customerName: customerName);
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => QueueConfirmationScreen(
            customerName: customerName,
            reportId: draft.idempotencyKey,
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _submitting = false);
      messenger.showSnackBar(SnackBar(content: Text(l.reportSubmitFailed)));
    }
  }

  Future<void> _attemptClose() async {
    if (!_hasUnsaved) {
      Navigator.pop(context);
      return;
    }
    if (await _confirmDiscard() == true && mounted) {
      // The recorder card's dispose cancels an in-progress recording and
      // drops the temp file when the route pops.
      Navigator.pop(context);
    }
  }

  Future<bool?> _confirmDiscard() {
    final l = AppLocalizations.of(context)!;
    return showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: Text(l.discardReportTitle),
            content: Text(l.discardReportMessage),
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
  }

  Future<bool?> _confirmNoLeads() {
    final l = AppLocalizations.of(context)!;
    return showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: Text(l.noLeadsTitle),
            content: Text(l.noLeadsMessage),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(l.cancelButton),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(l.submitAnywayButton),
              ),
            ],
          ),
    );
  }

  @override
  void dispose() {
    _notes.dispose();
    _recorder.dispose();
    super.dispose();
  }

  Future<void> _loadLeads(String customerId) async {
    final leads = await CustomersRepository.instance.leadsForCustomer(
      customerId,
    );
    if (!mounted) return;
    setState(() {
      _leads = leads;
      // Drop any pre-seeded (alert-prefilled) id this customer no longer has:
      // its chip can't render, so the user can neither see nor untag it — yet
      // it would still ship in the draft and auto-resolve that lead's alert.
      final ids = leads.map((l) => l.id).toSet();
      _selectedLeadIds.retainWhere(ids.contains);
    });
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

  void _toggleLead(String leadId) => setState(() {
    if (!_selectedLeadIds.remove(leadId)) _selectedLeadIds.add(leadId);
  });

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

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _attemptClose();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            l.newVisitReportTitle,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          actions: [
            IconButton(icon: const Icon(Icons.close), onPressed: _attemptClose),
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
                LeadSelector(
                  leads: _leads,
                  selectedIds: _selectedLeadIds,
                  onToggle: _toggleLead,
                ),
              ],
              const SizedBox(height: 20),
              _RecorderCard(
                // Stable key: the leads section inserts above this card when a
                // customer is picked, shifting its position — without a key
                // Flutter would rebuild it by index and lose the recording.
                key: const ValueKey('recorder'),
                service: _recorder,
                onChanged: (a) => setState(() => _audio = a),
                onRecordingChanged: (v) => setState(() => _isRecording = v),
              ),
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
                  onPressed: _canSubmit ? _submit : null,
                  child:
                      _submitting
                          ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                          : Text(l.submitReportButton),
                ),
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

enum _RecState { idle, recording, reviewing }

/// Three-state voice-note recorder (design screen 05). Owns the timer, the
/// amplitude subscription, and a 5-min cap; the parent owns the service and
/// the resulting audio (for submit / discard).
class _RecorderCard extends StatefulWidget {
  final AudioRecorderService service;
  final ValueChanged<ReportAudio?> onChanged;

  /// Fires true while actively recording so the parent can treat it as
  /// unsaved (discard warning) and block submit.
  final ValueChanged<bool> onRecordingChanged;

  const _RecorderCard({
    super.key,
    required this.service,
    required this.onChanged,
    required this.onRecordingChanged,
  });

  @override
  State<_RecorderCard> createState() => _RecorderCardState();
}

class _RecorderCardState extends State<_RecorderCard> {
  // Caps worst-case file size under the §4.4 10 MB ingest cap even at the
  // inflated iOS-simulator bitrate (~130 kbps -> ~4.8 MB at 5 min).
  static const _maxDuration = Duration(minutes: 5);
  static const _barCount = 40;

  _RecState _state = _RecState.idle;

  /// True only while [_start]'s `service.start()` await is in flight. The
  /// recorder may already be running natively during that window while
  /// [_state] is still idle, so dispose() must treat it as recording.
  bool _starting = false;
  final List<double> _levels = [];
  Duration _elapsed = Duration.zero;
  int _sizeBytes = 0;
  Timer? _ticker;
  StreamSubscription<Amplitude>? _ampSub;

  ReportAudio? _audio;
  AudioPlayer? _player;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<PlayerState>? _stateSub;
  Duration _pos = Duration.zero;
  Duration _total = Duration.zero;
  bool _playing = false;

  @override
  void dispose() {
    _ticker?.cancel();
    _ampSub?.cancel();
    _posSub?.cancel();
    _stateSub?.cancel();
    _player?.dispose();
    // Single cleanup authority however the card is torn down (incl. an
    // abandoned mid-recording close): stop the mic + drop the temp file.
    // [_starting] covers the window where start() has already begun natively
    // but hasn't returned yet, so _state is still idle.
    if (_starting || _state == _RecState.recording) {
      widget.service.cancel();
    } else if (_state == _RecState.reviewing) {
      widget.service.deleteFile();
    }
    super.dispose();
  }

  Future<void> _start() async {
    final l = AppLocalizations.of(context)!;
    _starting = true;
    final bool ok;
    try {
      ok = await widget.service.start();
    } finally {
      // Clear even if start() threw, or a later dispose would cancel a
      // recorder that never started.
      _starting = false;
    }
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.microphonePermissionRequired)));
      return;
    }
    setState(() {
      _state = _RecState.recording;
      _levels.clear();
      _elapsed = Duration.zero;
      _sizeBytes = 0;
    });
    widget.onRecordingChanged(true);
    _ampSub = widget.service.amplitudeStream().listen(_onAmplitude);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
  }

  void _onAmplitude(Amplitude amp) {
    if (!mounted) return;
    setState(() {
      _levels.add(_levelFromDb(amp.current));
      if (_levels.length > _barCount) _levels.removeAt(0);
    });
  }

  Future<void> _onTick() async {
    final size = await widget.service.currentSizeBytes();
    if (!mounted) return;
    setState(() {
      _elapsed += const Duration(seconds: 1);
      _sizeBytes = size;
    });
    if (_elapsed >= _maxDuration) _stop();
  }

  Future<void> _stop() async {
    await _ampSub?.cancel();
    _ticker?.cancel();
    final audio = await widget.service.stop();
    if (!mounted) return;
    _audio = audio;
    widget.onRecordingChanged(false);
    if (audio != null) await _initPlayer(audio);
    if (!mounted) return;
    setState(() => _state = _RecState.reviewing);
    widget.onChanged(audio);
  }

  Future<void> _initPlayer(ReportAudio audio) async {
    final player = AudioPlayer();
    _player = player;
    try {
      _total = await player.setFilePath(audio.path) ?? audio.duration;
    } catch (_) {
      _total = audio.duration;
    }
    _posSub = player.positionStream.listen((p) {
      if (mounted) setState(() => _pos = p);
    });
    _stateSub = player.playerStateStream.listen((s) {
      if (!mounted) return;
      // On completion, reset to the start rather than leaving it at the end.
      if (s.processingState == ProcessingState.completed) {
        player.pause();
        player.seek(Duration.zero);
        setState(() {
          _playing = false;
          _pos = Duration.zero;
        });
      } else {
        setState(() => _playing = s.playing);
      }
    });
  }

  Future<void> _togglePlay() async {
    final p = _player;
    if (p == null) return;
    if (_playing) {
      await p.pause();
    } else {
      if (_total > Duration.zero && _pos >= _total) await p.seek(Duration.zero);
      await p.play();
    }
  }

  Future<void> _disposePlayer() async {
    await _posSub?.cancel();
    await _stateSub?.cancel();
    _posSub = null;
    _stateSub = null;
    await _player?.dispose();
    _player = null;
    _pos = Duration.zero;
    _total = Duration.zero;
    _playing = false;
  }

  Future<void> _reRecord() async {
    await _disposePlayer();
    await widget.service.deleteFile();
    if (!mounted) return;
    setState(() {
      _state = _RecState.idle;
      _levels.clear();
      _audio = null;
    });
    widget.onChanged(null);
  }

  /// dBFS (0 = loudest, negative = quieter) -> 0..1, floored at -45 dB.
  double _levelFromDb(double db) {
    if (db.isNaN || db.isInfinite) return 0;
    const minDb = -45.0;
    return ((db - minDb) / -minDb).clamp(0.0, 1.0);
  }

  String _fmtDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  String _fmtBytes(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).round()} KB';
    return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: switch (_state) {
          _RecState.idle => _buildIdle(context),
          _RecState.recording => _buildRecording(context),
          _RecState.reviewing => _buildReviewing(context),
        },
      ),
    );
  }

  Widget _buildIdle(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    return Column(
      children: [
        _circleButton(icon: Icons.mic, onTap: _start),
        const SizedBox(height: 12),
        Text(
          l.tapToRecord,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _buildRecording(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(
                    color: AppTheme.recording,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  l.recordingLabel,
                  style: const TextStyle(
                    color: AppTheme.recording,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            Text(
              _fmtDuration(_elapsed),
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 18,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _Waveform(levels: _levels),
        const SizedBox(height: 16),
        _circleButton(icon: Icons.stop, onTap: _stop),
        const SizedBox(height: 10),
        Text(
          '${widget.service.codecLabel} · ${_fmtBytes(_sizeBytes)}',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _buildReviewing(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final totalMs = _total.inMilliseconds;
    final posMs = _pos.inMilliseconds.clamp(0, totalMs == 0 ? 0 : totalMs);

    return Column(
      children: [
        Row(
          children: [
            GestureDetector(
              onTap: _togglePlay,
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: theme.colorScheme.primary,
                ),
                child: Icon(
                  _playing ? Icons.pause : Icons.play_arrow,
                  color: Colors.white,
                ),
              ),
            ),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 6,
                  ),
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 12,
                  ),
                ),
                child: Slider(
                  value: totalMs == 0 ? 0 : posMs.toDouble(),
                  max: totalMs == 0 ? 1 : totalMs.toDouble(),
                  onChanged:
                      totalMs == 0
                          ? null
                          : (v) =>
                              _player?.seek(Duration(milliseconds: v.round())),
                ),
              ),
            ),
            Text(
              '${_fmtDuration(_pos)} / ${_fmtDuration(_total)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        Row(
          children: [
            Text(
              '${widget.service.codecLabel} · '
              '${_fmtBytes(_audio?.sizeBytes ?? _sizeBytes)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: _reRecord,
              icon: const Icon(Icons.refresh, size: 18),
              label: Text(l.reRecordButton),
            ),
          ],
        ),
      ],
    );
  }

  Widget _circleButton({required IconData icon, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 72,
        height: 72,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: AppTheme.recording,
        ),
        child: Icon(icon, color: Colors.white, size: 30),
      ),
    );
  }
}

/// Amplitude bars, oldest→newest, centered vertically.
class _Waveform extends StatelessWidget {
  final List<double> levels;

  const _Waveform({required this.levels});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      width: double.infinity,
      child: CustomPaint(
        painter: _WaveformPainter(
          levels: levels,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}

class _WaveformPainter extends CustomPainter {
  final List<double> levels;
  final Color color;

  _WaveformPainter({required this.levels, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    if (levels.isEmpty) return;
    const gap = 3.0;
    final n = levels.length;
    final barW = ((size.width - gap * (n - 1)) / n).clamp(1.5, 5.0);
    final paint =
        Paint()
          ..color = color
          ..strokeCap = StrokeCap.round
          ..strokeWidth = barW;
    final cy = size.height / 2;
    for (var i = 0; i < n; i++) {
      final h = levels[i].clamp(0.04, 1.0) * size.height;
      final x = i * (barW + gap) + barW / 2;
      canvas.drawLine(Offset(x, cy - h / 2), Offset(x, cy + h / 2), paint);
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter old) => true;
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
