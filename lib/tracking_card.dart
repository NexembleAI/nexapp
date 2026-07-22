import 'package:flutter/material.dart';

import 'geolocation_service.dart';
import 'home_controller.dart';
import 'l10n/app_localizations.dart';
import 'models/tracking_models.dart';
import 'preferences.dart';
import 'theme.dart';
import 'tracking_repository.dart';

/// Why tracking is in its current state; drives the dot color and subtitle.
enum _TrackingStatus { on, notRegistered, noPermission, off }

/// Hero card on Home (design screen 04): live tracking status over the brand
/// spectrum gradient, the office-hours window, and today's activity bars.
/// Status is re-checked on app resume and on a short poll, since tracking is
/// app-controlled and can change right after launch (registration gate) or
/// while backgrounded (OS permission change).
class TrackingCard extends StatefulWidget {
  const TrackingCard({super.key});

  @override
  State<TrackingCard> createState() => _TrackingCardState();
}

class _TrackingCardState extends State<TrackingCard>
    with WidgetsBindingObserver {
  _TrackingStatus? _status; // null until the first check completes
  OfficeHours? _hours;
  List<double> _activity = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Re-read when tracking state changes anywhere (quick action, action://stop,
    // push command, reconcile) — no polling.
    GeolocationService.revision.addListener(_refreshStatus);
    _refreshStatus();
    _loadRepositoryData();
    // Refresh the activity graph when Home reloads (pull / focus / resume).
    HomeController.instance.addListener(_reloadActivity);
  }

  @override
  void dispose() {
    HomeController.instance.removeListener(_reloadActivity);
    GeolocationService.revision.removeListener(_refreshStatus);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _reloadActivity() async {
    final activity = await TrackingRepository.instance.weeklyActivity();
    if (mounted) setState(() => _activity = activity);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Resume catches permission changes made in OS settings (which change no
    // state here, so [GeolocationService.revision] wouldn't fire).
    if (state == AppLifecycleState.resumed) _refreshStatus();
  }

  /// Read-only: reflects tracking state, never changes it. Auto-resume is
  /// [GeolocationService.reconcile]'s job (startup + app-resume), so a Stop
  /// from the quick action / action://stop / a push command is never reverted
  /// by whichever screen happens to be visible.
  Future<void> _refreshStatus() async {
    _TrackingStatus status;
    if (Preferences.instance.getBool(Preferences.deviceRegistered) != true) {
      status = _TrackingStatus.notRegistered;
    } else if (!await GeolocationService.hasLocationPermission()) {
      // Permission is the blocker — report it, but leave the SDK's persisted
      // "enabled" intent untouched so its native background self-resume
      // (re-init on relaunch) can restart tracking once permission returns.
      // iOS isTracking() would report the stale flag as "on", which is why
      // permission is checked before trusting it.
      status = _TrackingStatus.noPermission;
    } else if (await GeolocationService.tracker.isTracking()) {
      status = _TrackingStatus.on;
    } else {
      status = _TrackingStatus.off;
    }
    if (mounted && status != _status) setState(() => _status = status);
  }

  Future<void> _loadRepositoryData() async {
    final results = await Future.wait([
      TrackingRepository.instance.officeHours(),
      TrackingRepository.instance.weeklyActivity(),
    ]);
    if (!mounted) return;
    setState(() {
      _hours = results[0] as OfficeHours;
      _activity = results[1] as List<double>;
    });
  }

  /// "Active since 9:02 · Positions syncing" — the stamp is only shown when
  /// it's from today, so a session carried across midnight doesn't show a
  /// misleading clock time.
  String _onSubtitle(AppLocalizations l, MaterialLocalizations ml) {
    final raw = Preferences.instance.getString(Preferences.trackingStartedAt);
    final startedAt = raw != null ? DateTime.tryParse(raw) : null;
    if (startedAt == null || !DateUtils.isSameDay(startedAt, DateTime.now())) {
      return l.positionsSyncing;
    }
    final time = ml.formatTimeOfDay(TimeOfDay.fromDateTime(startedAt));
    return '${l.activeSince(time)} · ${l.positionsSyncing}';
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final ml = MaterialLocalizations.of(context);

    final (dotColor, statusLabel, subtitle) = switch (_status) {
      _TrackingStatus.on => (
          AppTheme.success,
          l.trackingOn,
          _onSubtitle(l, ml),
        ),
      _TrackingStatus.notRegistered => (
          AppTheme.warning,
          l.trackingOff,
          l.deviceRegistrationError,
        ),
      _TrackingStatus.noPermission => (
          AppTheme.warning,
          l.trackingOff,
          l.trackingPermissionRequired,
        ),
      _TrackingStatus.off => (
          Colors.white54,
          l.trackingOff,
          l.trackingNotRunning,
        ),
      null => (Colors.white24, '…', ''),
    };

    final window = _hours == null
        ? '—' // still loading
        : _hours!.closed
            ? l.officeHoursClosed
            : '${ml.formatTimeOfDay(_hours!.start)} – ${ml.formatTimeOfDay(_hours!.end)}';

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppTheme.cardRadius),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppTheme.spectrumMagenta,
            AppTheme.spectrumIndigo,
            AppTheme.spectrumBlue,
          ],
        ),
        boxShadow: [
          BoxShadow(
            color: AppTheme.spectrumMagenta.withValues(alpha: 0.3),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration:
                    BoxDecoration(color: dotColor, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  statusLabel,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 16,
                  ),
                ),
              ),
              _pill(l.officeHoursBadge),
            ],
          ),
          const SizedBox(height: 12),
          Text.rich(
            TextSpan(
              text: '${l.todayWindowLabel} ',
              style: const TextStyle(color: Colors.white70, fontSize: 13),
              children: [
                TextSpan(
                  text: window,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
          const SizedBox(height: 16),
          _ActivityBars(levels: _activity),
        ],
      ),
    );
  }

  Widget _pill(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: const TextStyle(color: Colors.white, fontSize: 11),
      ),
    );
  }
}

/// Today's activity as a mini bar graph; the latest (current) slot is green.
class _ActivityBars extends StatelessWidget {
  final List<double> levels;

  const _ActivityBars({required this.levels});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 36,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (final (i, level) in levels.indexed)
            Expanded(
              child: Container(
                height: 36 * level.clamp(0.05, 1.0),
                margin: const EdgeInsets.symmetric(horizontal: 2),
                decoration: BoxDecoration(
                  color: i == levels.length - 1
                      ? AppTheme.success
                      : Colors.white.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
