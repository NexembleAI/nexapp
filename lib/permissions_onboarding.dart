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
  static Future<PermissionGrant> request(
    OnboardingPermission p, {
    bool settingsFallback = false,
  }) async {
    switch (p) {
      case OnboardingPermission.location:
        var perm = await Geolocator.checkPermission();
        if (perm == LocationPermission.denied) {
          // Stage 1: foreground prompt only. Stop here so "Allow Once" /
          // "While using" just updates the pill; the next tap does the upgrade.
          perm = await Geolocator.requestPermission();
        } else if (perm == LocationPermission.whileInUse) {
          // Stage 2: escalate to Always. On iOS the first tap shows "Change to
          // Always Allow?" — its result arrives asynchronously (provisional),
          // so we do NOT open Settings here (that would pop Settings on top of
          // the prompt); a resume re-check advances the wizard once Always is
          // granted. Only when the user is still stuck on a later tap
          // ([settingsFallback]) do we route to Settings — covering a declined
          // prompt or a one-time "Allow Once" that can't be upgraded. Android
          // 11+ has no background dialog, so it always goes to Settings.
          if (Platform.isIOS && !settingsFallback) {
            await Permission.locationAlways.request();
          } else {
            await Geolocator.openAppSettings();
          }
        }
        // Foreground permanently denied — Settings is the only way back.
        if (perm == LocationPermission.deniedForever) {
          await Geolocator.openAppSettings();
        }
        return status(OnboardingPermission.location);
      case OnboardingPermission.notifications:
        final notif = await Permission.notification.status;
        if (notif.isPermanentlyDenied) {
          // iOS only shows the notification dialog once; once denied it no-ops,
          // so Settings is the only path (also covers Android after repeated
          // denials). Avoids a dead button. The wizard re-checks on resume.
          await openAppSettings();
        } else {
          // Not yet decided — show the OS dialog. Firebase-native so iOS
          // registers with APNs (FCM needs it to mint a token); also covers
          // Android 13+ POST_NOTIFICATIONS.
          await PushService.requestPermission();
        }
        return status(OnboardingPermission.notifications);
      case OnboardingPermission.battery:
        await Permission.ignoreBatteryOptimizations.request();
        return status(OnboardingPermission.battery);
    }
  }
}
