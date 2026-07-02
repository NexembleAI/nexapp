import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'auth_config.dart';
import 'auth_service.dart';
import 'preferences.dart';

/// Debug-only logger for the device-registration flow. Prints with a
/// `[register]` prefix so it's easy to spot in `flutter run`; a no-op in
/// release builds.
void registerDebugLog(String message) {
  if (kDebugMode) debugPrint('[register] $message');
}

/// Outcome of a single device-registration attempt, mapped from the tracking
/// service's gRPC status code (surfaced in the REST error body's `code`) with
/// an HTTP-status fallback.
enum RegisterOutcome {
  /// 200 — registered (or idempotently re-registered) and provisioned.
  success,

  /// code 9 (FailedPrecondition) — the user already has an active device with a
  /// different unique_id. Terminal for this session; retried on next login.
  conflictUser,

  /// code 6 (AlreadyExists) — this unique_id already belongs to another device
  /// / user. Terminal for this session; retried on next login.
  conflictDevice,

  /// code 16 / HTTP 401 — token missing or expired; refresh / re-auth.
  unauthenticated,

  /// HTTP 403 (INVALID_LICENSE) or code 7 (PermissionDenied) — nothing the
  /// client can fix; retried on next login.
  forbidden,

  /// code 13 (Internal) / HTTP 5xx / network error — safe to retry.
  retryable,

  /// code 3 (InvalidArgument) — malformed request (a client bug).
  invalid,
}

/// Typed result of [TrackingService.registerDevice].
class RegisterResult {
  final RegisterOutcome outcome;

  /// Server-provided message, kept for logs / dialog detail (may be null).
  final String? message;

  /// Parsed Device JSON on [RegisterOutcome.success] (may be null).
  final Map<String, dynamic>? device;

  const RegisterResult(this.outcome, {this.message, this.device});
}

/// Client for the Nexcore tracking device endpoints.
///
/// Performs a SINGLE registration attempt and returns a typed result; retry,
/// the blocking spinner, error dialogs, and the persisted "registered" flag are
/// the caller's concern (the post-login registration gate).
class TrackingService {
  TrackingService._();

  static final Uri _registerUri = Uri.parse(
    '${AuthConfig.nexCoreUrl}/v1/api/tenant/${AuthConfig.tenantId}/tracking/device/register',
  );

  /// Registers the current device for the logged-in user. Idempotent
  /// server-side: re-registering the same user + unique_id returns the existing
  /// device. `user_id` is resolved from the access token, never sent.
  static Future<RegisterResult> registerDevice() async {
    final token = await AuthService.instance.accessToken();
    if (token == null) {
      registerDebugLog('no access token -> unauthenticated');
      return const RegisterResult(RegisterOutcome.unauthenticated,
          message: 'no access token');
    }

    final uniqueId = Preferences.instance.getString(Preferences.id);
    if (uniqueId == null || uniqueId.isEmpty) {
      registerDebugLog('missing device id (Preferences.id) -> invalid');
      return const RegisterResult(RegisterOutcome.invalid,
          message: 'missing device id (Preferences.id)');
    }

    final info = await _deviceInfo();
    final notificationToken = await _fcmToken(); // best-effort; may be null

    final body = <String, dynamic>{
      'unique_id': uniqueId,
      'phone_model': info.model,
      'os': info.os,
    };
    if (notificationToken != null && notificationToken.isNotEmpty) {
      body['notification_token'] = notificationToken;
    }

    registerDebugLog('POST $_registerUri  unique_id=$uniqueId '
        'model="${info.model}" os="${info.os}" '
        'fcm=${body.containsKey('notification_token') ? 'yes' : 'no'}');

    final client = await _httpClient();
    try {
      final request = await client.postUrl(_registerUri);
      request.headers.contentType = ContentType.json;
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      request.write(jsonEncode(body));
      final response = await request.close();
      final text = await response.transform(utf8.decoder).join();
      final result = _mapResponse(response.statusCode, text);
      registerDebugLog('HTTP ${response.statusCode} -> ${result.outcome.name}'
          '${result.message != null ? ' (${result.message})' : ''}'
          '${result.device != null ? ' traccarDeviceId=${result.device!['traccarDeviceId'] ?? result.device!['traccar_device_id']}' : ''}');
      return result;
    } on SocketException catch (e) {
      registerDebugLog('network error: ${e.message} -> retryable');
      developer.log('registerDevice: network error', error: e);
      return const RegisterResult(RegisterOutcome.retryable,
          message: 'network error');
    } on HttpException catch (e) {
      registerDebugLog('http error: ${e.message} -> retryable');
      developer.log('registerDevice: http error', error: e);
      return const RegisterResult(RegisterOutcome.retryable,
          message: 'http error');
    } catch (e) {
      registerDebugLog('unexpected error: $e -> retryable');
      developer.log('registerDevice: unexpected error', error: e);
      return RegisterResult(RegisterOutcome.retryable, message: e.toString());
    } finally {
      client.close(force: true);
    }
  }

  /// Maps an HTTP status + body to a [RegisterResult]. Prefers the gRPC `code`
  /// in the JSON error body (several codes share HTTP 400); falls back to the
  /// HTTP status when the code is absent/unknown.
  static RegisterResult _mapResponse(int status, String bodyText) {
    if (status == 200) {
      Map<String, dynamic>? device;
      try {
        device = jsonDecode(bodyText) as Map<String, dynamic>;
      } catch (_) {}
      return RegisterResult(RegisterOutcome.success, device: device);
    }

    int? code;
    String? message;
    try {
      final j = jsonDecode(bodyText) as Map<String, dynamic>;
      code = (j['code'] as num?)?.toInt();
      message = j['message'] as String?;
    } catch (_) {}

    switch (code) {
      case 9:
        return RegisterResult(RegisterOutcome.conflictUser, message: message);
      case 6:
        return RegisterResult(RegisterOutcome.conflictDevice, message: message);
      case 16:
        return RegisterResult(RegisterOutcome.unauthenticated, message: message);
      case 7:
        return RegisterResult(RegisterOutcome.forbidden, message: message);
      case 3:
        return RegisterResult(RegisterOutcome.invalid, message: message);
      case 13:
        return RegisterResult(RegisterOutcome.retryable, message: message);
    }

    // HTTP-status fallback when there was no recognizable gRPC code.
    if (status == 401) {
      return RegisterResult(RegisterOutcome.unauthenticated, message: message);
    }
    if (status == 403) {
      return RegisterResult(RegisterOutcome.forbidden, message: message);
    }
    if (status >= 500) {
      return RegisterResult(RegisterOutcome.retryable, message: message);
    }
    return RegisterResult(RegisterOutcome.retryable,
        message: message ?? 'HTTP $status');
  }

  /// Best-effort device model + OS string; empty strings on failure (both are
  /// optional on the server).
  static Future<({String model, String os})> _deviceInfo() async {
    try {
      final plugin = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final a = await plugin.androidInfo;
        return (model: a.model, os: 'Android ${a.version.release}');
      } else if (Platform.isIOS) {
        final i = await plugin.iosInfo;
        return (model: i.utsname.machine, os: '${i.systemName} ${i.systemVersion}');
      }
    } catch (e) {
      developer.log('registerDevice: device info failed', error: e);
    }
    return (model: '', os: '');
  }

  /// Best-effort FCM token for the push registry (§2.3.5). Null when Firebase
  /// isn't configured or the fetch fails — registration proceeds without it.
  static Future<String?> _fcmToken() async {
    try {
      return await FirebaseMessaging.instance.getToken();
    } catch (e) {
      developer.log('registerDevice: fcm token failed', error: e);
      return null;
    }
  }

  /// HttpClient that trusts the bundled Nexemble dev CA (mkcert) in addition to
  /// the platform's public roots, so HTTPS to the NexCore edge validates
  /// properly. dart:io's HttpClient ignores Android's network_security_config,
  /// so the CA is supplied here explicitly via a SecurityContext. The context is
  /// built once and reused.
  static Future<HttpClient> _httpClient() async {
    _securityContext ??= await _buildSecurityContext();
    return HttpClient(context: _securityContext);
  }

  static SecurityContext? _securityContext;

  static Future<SecurityContext> _buildSecurityContext() async {
    final context = SecurityContext(withTrustedRoots: true);
    try {
      final pem = await rootBundle.load('assets/certs/nexemble_ca.pem');
      context.setTrustedCertificatesBytes(pem.buffer.asUint8List());
    } catch (e) {
      developer.log('registerDevice: failed to load bundled CA', error: e);
    }
    return context;
  }
}
