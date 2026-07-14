import 'dart:io';

import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

import 'push_service.dart';

/// The permissions the first-run wizard walks through, in ask order.
enum OnboardingPermission { location, notifications, battery }

/// Current grant level for a step. [partial] only applies to location
/// (foreground "while using" held, but background "Always" not yet granted).
enum PermissionGrant { granted, partial, denied }

/// Pure logic behind the onboarding wizard (design screen 03): which steps
/// apply on this platform, and each step's current grant level. The actual
/// request/escalation semantics live in the wizard UI layer.
class PermissionsOnboarding {
  /// All steps applicable to this platform, in the order they're asked.
  /// Battery-optimization has no iOS equivalent.
  static List<OnboardingPermission> get steps => [
    OnboardingPermission.location,
    OnboardingPermission.notifications,
    if (Platform.isAndroid) OnboardingPermission.battery,
  ];

  /// Current grant level for [p].
  static Future<PermissionGrant> status(OnboardingPermission p) async {
    switch (p) {
      case OnboardingPermission.location:
        final loc = await Geolocator.checkPermission();
        if (loc == LocationPermission.always) return PermissionGrant.granted;
        if (loc == LocationPermission.whileInUse) {
          return PermissionGrant.partial;
        }
        return PermissionGrant.denied;
      case OnboardingPermission.notifications:
        return await Permission.notification.isGranted
            ? PermissionGrant.granted
            : PermissionGrant.denied;
      case OnboardingPermission.battery:
        if (!Platform.isAndroid) return PermissionGrant.granted;
        return await Permission.ignoreBatteryOptimizations.isGranted
            ? PermissionGrant.granted
            : PermissionGrant.denied;
    }
  }

  /// Steps that still need attention (status != granted), in ask order.
  /// The wizard shows exactly these, so an all-granted user sees nothing.
  static Future<List<OnboardingPermission>> pendingSteps() async {
    final result = <OnboardingPermission>[];
    for (final p in steps) {
      if (await status(p) != PermissionGrant.granted) result.add(p);
    }
    return result;
  }

  /// Requests [p] and returns the resulting grant. Location performs the
  /// mandatory two-stage escalation: foreground first, then — when already
  /// "while using" — the Always upgrade (iOS one-time prompt; Android 11+ has
  /// no dialog for background, so it routes to Settings, and the wizard
  /// re-checks on resume).
  static Future<PermissionGrant> request(OnboardingPermission p) async {
    switch (p) {
      case OnboardingPermission.location:
        var perm = await Geolocator.checkPermission();
        if (perm == LocationPermission.denied) {
          perm = await Geolocator.requestPermission();
        }
        if (perm == LocationPermission.whileInUse) {
          // Escalate to Always. Geolocator.requestPermission() no-ops once
          // while-using is held, so use permission_handler, which actually
          // calls requestAlwaysAuthorization — iOS shows "Change to Always
          // Allow?". Android 11+ has no dialog for background, so route to
          // Settings ("Allow all the time"); the wizard re-checks on resume.
          if (Platform.isIOS) {
            await Permission.locationAlways.request();
          } else {
            await Geolocator.openAppSettings();
          }
        }
        return status(OnboardingPermission.location);
      case OnboardingPermission.notifications:
        // Firebase-native request so iOS registers with APNs (FCM needs it to
        // mint a token); also covers Android 13+ POST_NOTIFICATIONS.
        await PushService.requestPermission();
        return status(OnboardingPermission.notifications);
      case OnboardingPermission.battery:
        await Permission.ignoreBatteryOptimizations.request();
        return status(OnboardingPermission.battery);
    }
  }
}
