import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';

import 'auth_service.dart';
import 'geolocation_service.dart';
import 'l10n/app_localizations.dart';
import 'main.dart';
import 'preferences.dart';
import 'tracking_service.dart';

/// Post-login gate: ensures the device is auto-registered with the tracking
/// service before showing [child], displaying a blocking spinner meanwhile.
///
/// A device already marked [Preferences.deviceRegistered] skips straight to
/// [child] (no spinner). Otherwise registration is attempted once per mount;
/// the flag is persisted only on success, so a failed attempt is retried on the
/// next login. Every outcome ultimately falls through to [child] — tracking
/// simply stays unregistered on failure.
class RegistrationGate extends StatefulWidget {
  final Widget child;
  const RegistrationGate({super.key, required this.child});

  @override
  State<RegistrationGate> createState() => _RegistrationGateState();
}

class _RegistrationGateState extends State<RegistrationGate> {
  // Sync cache read: already-registered devices never show the spinner.
  late bool _ready =
      Preferences.instance.getBool(Preferences.deviceRegistered) == true;

  int _attempt = 1;
  bool _retrying = false;

  @override
  void initState() {
    super.initState();
    if (_ready) {
      registerDebugLog('device already registered; skipping gate');
      _ensureTracking(); // resume continuous tracking on this launch
    } else {
      registerDebugLog('not registered; starting registration gate');
      _register();
    }
  }

  /// Max register attempts for a [RegisterOutcome.retryable] result
  /// (code 13 / 5xx / network). Non-retryable outcomes are single-shot.
  static const int _maxAttempts = 3;

  Future<void> _register() async {
    var result = const RegisterResult(RegisterOutcome.retryable);
    for (var attempt = 1; attempt <= _maxAttempts; attempt++) {
      if (attempt > 1 && mounted) {
        setState(() {
          _attempt = attempt;
          _retrying = true;
        });
      }
      registerDebugLog('attempt $attempt/$_maxAttempts');
      result = await TrackingService.registerDevice();
      if (result.outcome != RegisterOutcome.retryable) break;
      if (attempt < _maxAttempts) {
        // Linear backoff: 1s, then 2s.
        registerDebugLog('retryable; backing off ${attempt}s before retry');
        await Future.delayed(Duration(seconds: attempt));
        if (!mounted) return;
      }
    }

    if (!mounted) return;

    if (result.outcome == RegisterOutcome.success) {
      registerDebugLog('success -> persist flag -> home');
      await Preferences.instance.setBool(Preferences.deviceRegistered, true);
      await _ensureTracking(); // enable continuous tracking on registration
    } else if (result.outcome == RegisterOutcome.unauthenticated) {
      // Token rejected / refresh failed — force re-authentication. AuthGate
      // then shows the login screen; don't fall through to the home app.
      registerDebugLog('unauthenticated -> logout');
      await AuthService.instance.logout();
      return;
    } else {
      registerDebugLog('${result.outcome.name} -> error dialog -> home');
      await _showErrorDialog(result.outcome);
    }

    if (mounted) setState(() => _ready = true);
  }

  /// Starts continuous tracking once the device is registered (idempotent —
  /// no-op if already tracking). The SDK prompts for location permission; a
  /// denial throws [PlatformException], which we surface rather than fail
  /// silently. The manual home-screen toggle still lets the user pause/resume.
  Future<void> _ensureTracking() async {
    // The SDK swallows a location-permission denial on iOS (start() doesn't
    // throw), so check permission ourselves and surface it consistently on
    // both platforms. The home card derives its status from the same check.
    if (!await _hasLocationPermission()) {
      // Don't stop() here: that would persist "tracking off" and disarm the
      // SDK's background self-resume over a temporary OS condition.
      registerDebugLog('location permission not granted');
      _showTrackingPermissionSnackBar();
      return;
    }
    if (await GeolocationService.tracker.isTracking()) return;
    try {
      await GeolocationService.start();
      registerDebugLog('tracking started');
    } on PlatformException catch (e) {
      registerDebugLog('tracking start failed: ${e.message}');
      _showTrackingPermissionSnackBar();
    } catch (e) {
      registerDebugLog('tracking start error: $e');
    }
  }

  /// True when location permission is sufficient to start tracking (matches the
  /// SDK's own always/whileInUse check). Requests it if not yet determined.
  Future<bool> _hasLocationPermission() async {
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    return permission == LocationPermission.always ||
        permission == LocationPermission.whileInUse;
  }

  void _showTrackingPermissionSnackBar() {
    if (!mounted) return;
    messengerKey.currentState?.showSnackBar(
      SnackBar(
        content: Text(AppLocalizations.of(context)!.trackingPermissionRequired),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  Future<void> _showErrorDialog(RegisterOutcome outcome) async {
    if (!mounted) return;
    final l = AppLocalizations.of(context)!;
    final message = switch (outcome) {
      RegisterOutcome.conflictUser => l.deviceRegistrationConflictUser,
      RegisterOutcome.conflictDevice => l.deviceRegistrationConflictDevice,
      _ => l.deviceRegistrationError, // forbidden / retryable / invalid
    };
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.deviceRegistrationTitle),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l.okButton),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_ready) return widget.child;
    final l = AppLocalizations.of(context)!;
    final message = _retrying
        ? '${l.registrationRetrying} ($_attempt/$_maxAttempts)'
        : l.registrationInProgress;
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(message, textAlign: TextAlign.center),
            ),
          ],
        ),
      ),
    );
  }
}
