import 'geolocation_service.dart';
import 'preferences.dart';

/// Applies tracking configuration from a deep link. Since the Settings rewrite
/// (which exposes only accuracy, distance and interval, per the design) this is
/// the **only** way to reach the remaining prefs — buffer, wakelock,
/// stop_detection, prefer_platform_providers, angle, heartbeat, id, url. Those
/// are still applied by [Preferences.buildConfig] from their stored/default
/// values; dropping the UI froze them, it didn't disable them.
///
/// Format, parameters and examples (incl. `prefer_platform_providers`, the
/// emulator-debug lever): see `doc/ConfigDeepLink.md`. Note the scheme is
/// `org.traccar.client`, not the OIDC redirect scheme `com.nexemble.nexapp`.
///
/// `password` is deliberately not handled here — the settings-password gate was
/// dropped and PasswordService.authenticate() is no longer called.
class ConfigurationService {
  static Future<void> applyUri(Uri uri) async {
    if (uri.scheme == 'http' || uri.scheme == 'https') {
      await Preferences.instance.setString(Preferences.url, '${uri.origin}${uri.path}');
    } else {
      final url = uri.queryParameters['url'];
      if (url != null) {
        await Preferences.instance.setString(Preferences.url, url);
      }
    }
    final parameters = uri.queryParameters;
    await _applyStringParameter(parameters, Preferences.id);
    await _applyStringParameter(parameters, Preferences.accuracy);
    await _applyIntParameter(parameters, Preferences.distance);
    await _applyIntParameter(parameters, Preferences.interval);
    await _applyIntParameter(parameters, Preferences.angle);
    await _applyIntParameter(parameters, Preferences.heartbeat);
    await _applyBoolParameter(parameters, Preferences.buffer);
    await _applyBoolParameter(parameters, Preferences.wakelock);
    await _applyBoolParameter(parameters, Preferences.stopDetection);
    await _applyBoolParameter(parameters, Preferences.preferPlatformProviders);
    await GeolocationService.tracker.setConfig(Preferences.buildConfig());
  }

  static Future<void> _applyStringParameter(
      Map<String, String> parameters, String key) async {
    final value = parameters[key];
    if (value != null) {
      await Preferences.instance.setString(key, value);
    }
  }

  static Future<void> _applyIntParameter(
      Map<String, String> parameters, String key) async {
    final stringValue = parameters[key];
    if (stringValue != null) {
      final value = int.tryParse(stringValue);
      if (value != null) {
        await Preferences.instance.setInt(key, value);
      }
    }
  }

  static Future<void> _applyBoolParameter(
      Map<String, String> parameters, String key) async {
    final value = parameters[key];
    if (value != null) {
      switch (value) {
        case 'false':
          await Preferences.instance.setBool(key, false);
        case 'true':
          await Preferences.instance.setBool(key, true);
      }
    }
  }
}
