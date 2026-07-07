import 'package:traccar_client_sdk/traccar_client_sdk.dart';

import 'preferences.dart';

class GeolocationService {
  static final tracker = TraccarClientSdk();

  /// Starts tracking and stamps [Preferences.trackingStartedAt] (the "Active
  /// since" time on the home card). A start while already tracking keeps the
  /// original stamp; a failed start clears it and rethrows so callers keep
  /// their error handling.
  static Future<void> start() async {
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
    }
  }

  static Future<void> stop() async {
    await tracker.stop();
    await Preferences.instance.remove(Preferences.trackingStartedAt);
  }
}
