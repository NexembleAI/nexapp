import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:traccar_client_sdk/traccar_client_sdk.dart';

import 'preferences.dart';

class GeolocationService {
  static final tracker = TraccarClientSdk();

  /// Brings the native SDK config in line with the current [Preferences].
  /// `init()` is idempotent and won't update an already-installed native config
  /// on an upgraded install, so the follow-up `setConfig()` pushes the current
  /// values through (covers the NEX_TRACCAR_URL http->https migration, the
  /// interval default, and any future config drift). Shared by both entry
  /// points — main() and the FCM background isolate — so neither can forget the
  /// setConfig() step (each isolate still runs its own Firebase/Preferences
  /// init first, since isolate memory isn't shared).
  static Future<void> initWithConfig() async {
    final config = Preferences.buildConfig();
    await tracker.init(config);
    await tracker.setConfig(config);
  }

  /// Bumped whenever tracking state may have changed (start / stop /
  /// reconcile), so UI can re-read status instead of polling.
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// Whether tracking is *wanted*. Distinct from whether it's running: a
  /// permission outage must not clear it (so tracking resumes when permission
  /// comes back), while a deliberate Stop must (so nothing auto-resumes).
  static bool get intent =>
      Preferences.instance.getBool(Preferences.trackingIntent) == true;

  static Future<void> setIntent(bool wanted) =>
      Preferences.instance.setBool(Preferences.trackingIntent, wanted);

  /// True when location permission is sufficient to track (check only —
  /// never prompts).
  static Future<bool> hasLocationPermission() async {
    final permission = await Geolocator.checkPermission();
    return permission == LocationPermission.always ||
        permission == LocationPermission.whileInUse;
  }

  /// Starts tracking and stamps [Preferences.trackingStartedAt] (the "Active
  /// since" time on the home card). A start while already tracking keeps the
  /// original stamp; a failed start clears it and rethrows so callers keep
  /// their error handling. Also records the intent to track, so every Start
  /// surface (quick action, deep link, push command, registration) sets it for
  /// free.
  static Future<void> start() async {
    await setIntent(true);
    final wasTracking = await tracker.isTracking();
    try {
      await tracker.start();
      if (!wasTracking) {
        await Preferences.instance.setString(
          Preferences.trackingStartedAt,
          DateTime.now().toIso8601String(),
        );
      }
    } catch (_) {
      await Preferences.instance.remove(Preferences.trackingStartedAt);
      rethrow;
    } finally {
      revision.value++; // success or failure — let the UI re-read
    }
  }

  /// Stops tracking and clears the intent, so nothing auto-resumes it. Every
  /// Stop surface (quick action, action://stop, push 'positionStop') lands
  /// here, so they all record the intent for free. Clearing the SDK's own
  /// persisted "enabled" flag also prevents its native background self-resume
  /// from reviving a deliberate stop.
  static Future<void> stop() async {
    await setIntent(false);
    try {
      await tracker.stop();
      await Preferences.instance.remove(Preferences.trackingStartedAt);
    } finally {
      // Success or failure, let the UI re-read (mirrors start()). On a throw
      // the intent is already cleared, so reconcile() won't revive it; without
      // this bump the card would keep showing "Active" against a dead session.
      revision.value++;
    }
  }

  static bool _reconciling = false;

  /// Makes the actual tracking state match [intent], given registration and
  /// permission. The ONLY place allowed to auto-(re)start: called at startup
  /// and on app-resume, so granting permission in OS settings resumes tracking
  /// — but only when tracking was actually wanted, so a user/server Stop is
  /// never reverted. (The office-hours gate becomes another term here.)
  ///
  /// Non-reentrant: overlapping calls (e.g. a resume landing on top of startup)
  /// would each see `isTracking() == false` and start twice, double-stamping
  /// [Preferences.trackingStartedAt].
  static Future<void> reconcile() async {
    if (_reconciling) return;
    _reconciling = true;
    try {
      // Our cache is a per-isolate snapshot. The FCM background isolate writes
      // intent (a positionStop/positionPeriodic push) straight to disk without
      // touching this copy, so read intent fresh FROM DISK before trusting it —
      // otherwise a server-pushed Stop arriving while we're backgrounded-but-
      // alive looks like it never happened and we'd revert it on the next
      // resume. A whole-cache reloadCache() would work but transiently EMPTIES
      // the shared cache (clear-then-async-repopulate), racing concurrent
      // synchronous reads (Preferences.id read null at startup → office hours
      // defaulted); a targeted disk read avoids that.
      final wanted = await Preferences.diskBool(Preferences.trackingIntent);
      if (wanted != true) return;
      if (Preferences.instance.getBool(Preferences.deviceRegistered) != true) {
        return;
      }
      if (!await hasLocationPermission()) return;
      if (await tracker.isTracking()) return;
      // Re-check right before starting: a Stop that landed during the awaits
      // above (e.g. a quick action, same isolate so it wrote through the cache)
      // must win, not be reverted a few milliseconds later.
      if (!intent) return;
      try {
        await start();
      } catch (_) {
        // Best-effort: a failed resume just leaves the card showing "off".
      }
    } finally {
      _reconciling = false;
    }
  }
}
