import 'dart:io';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_android/shared_preferences_android.dart';
import 'package:traccar_client_sdk/traccar_client_sdk.dart';

import 'auth_config.dart';

class Preferences {
  static Future<void>? _initFuture;
  static late SharedPreferencesWithCache instance;

  static const String id = 'id';
  static const String url = 'url';
  static const String accuracy = 'accuracy';
  static const String distance = 'distance';
  static const String interval = 'interval';
  static const String angle = 'angle';
  static const String heartbeat = 'heartbeat';
  static const String buffer = 'buffer';
  static const String wakelock = 'wakelock';
  static const String stopDetection = 'stop_detection';
  static const String preferPlatformProviders = 'prefer_platform_providers';
  static const String password = 'password';
  // Set true once the device has been auto-registered with the tracking service
  // (post-login gate). Not part of the fresh-install defaults.
  static const String deviceRegistered = 'device_registered';
  // Last build-time NEX_TRACCAR_URL (AuthConfig.serverUrl) applied to `url`.
  // Lets a new build whose define changed override the persisted `url`.
  static const String urlConfig = 'url_config';
  // ISO-8601 time the current tracking session started ("Active since" on the
  // home card). Written/cleared by GeolocationService.start()/stop().
  static const String trackingStartedAt = 'tracking_started_at';
  // Set true once the first-run permission wizard has been completed/skipped.
  // Not part of the fresh-install defaults.
  static const String onboardingComplete = 'onboarding_complete';

  static Future<void> init() async {
    _initFuture ??= _createInstance();
    await _initFuture;
  }

  static Future<void> _createInstance() async {
    instance = await SharedPreferencesWithCache.create(
      sharedPreferencesOptions: Platform.isAndroid
          ? SharedPreferencesAsyncAndroidOptions(backend: SharedPreferencesAndroidBackendLibrary.SharedPreferences)
          : SharedPreferencesOptions(),
      cacheOptions: SharedPreferencesWithCacheOptions(
        allowList: {
          id, url, accuracy, distance, interval, angle, heartbeat, buffer, wakelock, stopDetection, preferPlatformProviders, password, deviceRegistered, urlConfig, trackingStartedAt, onboardingComplete,
        },
      ),
    );
    if (instance.getString(id) == null) {
      await instance.setString(id, (Random().nextInt(90000000) + 10000000).toString());
      await instance.setString(accuracy, 'high');
      await instance.setInt(interval, 60);
      await instance.setInt(distance, 25);
      await instance.setBool(buffer, true);
      await instance.setBool(stopDetection, true);
    }
    // One-time migration: the old auto-seeded default was 180s and was never a
    // deliberate user choice — bring existing installs onto the new 60s default.
    if (instance.getInt(interval) == 180) {
      await instance.setInt(interval, 60);
    }
    // Seed `url` from the build-time NEX_TRACCAR_URL, and re-apply it whenever
    // that define changes (covers fresh installs and upgrades to a build with a
    // different endpoint). Within the same build the stored value is left alone,
    // so a runtime/deep-link override survives. The SDK always reads `url`.
    if (instance.getString(urlConfig) != AuthConfig.serverUrl) {
      await instance.setString(url, AuthConfig.serverUrl);
      await instance.setString(urlConfig, AuthConfig.serverUrl);
    }
  }

  static Config buildConfig() {
    return Config(
      serverUrl: instance.getString(url) ?? '',
      deviceId: instance.getString(id) ?? '',
      location: LocationConfig(
        accuracy: switch (instance.getString(accuracy)) {
          'highest' => Accuracy.highest,
          'high' => Accuracy.high,
          'low' => Accuracy.low,
          _ => Accuracy.medium,
        },
        distanceMeters: instance.getInt(distance) ?? 25,
        intervalSeconds: instance.getInt(interval) ?? 60,
        angleDegrees: instance.getInt(angle) ?? 0,
        heartbeatIntervalSeconds: instance.getInt(heartbeat) ?? 0,
        stopDetection: instance.getBool(stopDetection) ?? true,
      ),
      wakeLock: instance.getBool(wakelock) ?? false,
      buffer: instance.getBool(buffer) ?? true,
      preferPlatformProviders: instance.getBool(preferPlatformProviders) ?? false,
    );
  }
}
