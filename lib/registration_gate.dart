import 'package:flutter/material.dart';

import 'auth_service.dart';
import 'l10n/app_localizations.dart';
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

  @override
  void initState() {
    super.initState();
    if (_ready) {
      registerDebugLog('device already registered; skipping gate');
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
    return const Scaffold(
      body: Center(child: CircularProgressIndicator()),
    );
  }
}
