import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_appauth/flutter_appauth.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'auth_config.dart';
import 'geolocation_service.dart';
import 'preferences.dart';

/// Keycloak OIDC (Authorization Code + PKCE) via the system browser.
///
/// Tokens are kept in the secure store. [authState] drives the auth gate:
/// `null` = unknown/checking, `true` = signed in, `false` = signed out.
class AuthService {
  AuthService._();
  static final AuthService instance = AuthService._();

  final FlutterAppAuth _appAuth = const FlutterAppAuth();
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  final ValueNotifier<bool?> authState = ValueNotifier<bool?>(null);

  static const _kAccess = 'auth_access_token';
  static const _kRefresh = 'auth_refresh_token';
  static const _kId = 'auth_id_token';
  static const _kExpiry = 'auth_expiry';

  /// Loads persisted session state at startup (sets [authState]).
  Future<void> restore() async {
    final refresh = await _storage.read(key: _kRefresh);
    authState.value = refresh != null && refresh.isNotEmpty;
  }

  /// Launches the Keycloak login and persists the resulting tokens.
  Future<void> login() async {
    final result = await _appAuth.authorizeAndExchangeCode(
      AuthorizationTokenRequest(
        AuthConfig.clientId,
        AuthConfig.redirectUrl,
        issuer: AuthConfig.issuer,
        scopes: AuthConfig.scopes,
        promptValues: const ['login'],
      ),
    );
    await _store(
      access: result.accessToken,
      refresh: result.refreshToken,
      id: result.idToken,
      expiry: result.accessTokenExpirationDateTime,
    );
    authState.value = true;
  }

  /// Returns a valid access token, refreshing if needed; null if signed out.
  Future<String?> accessToken() async {
    final access = await _storage.read(key: _kAccess);
    final expiryStr = await _storage.read(key: _kExpiry);
    final expiry = expiryStr != null ? DateTime.tryParse(expiryStr) : null;
    if (access != null &&
        expiry != null &&
        expiry.isAfter(DateTime.now().add(const Duration(seconds: 30)))) {
      return access;
    }
    return _refresh();
  }

  Future<String?> _refresh() async {
    final refresh = await _storage.read(key: _kRefresh);
    if (refresh == null || refresh.isEmpty) return null;
    try {
      final result = await _appAuth.token(
        TokenRequest(
          AuthConfig.clientId,
          AuthConfig.redirectUrl,
          issuer: AuthConfig.issuer,
          refreshToken: refresh,
          scopes: AuthConfig.scopes,
        ),
      );
      await _store(
        access: result.accessToken,
        refresh: result.refreshToken ?? refresh,
        id: result.idToken,
        expiry: result.accessTokenExpirationDateTime,
      );
      return result.accessToken;
    } catch (_) {
      await logout();
      return null;
    }
  }

  /// Decoded ID-token claims (e.g. name / preferred_username / email).
  Future<Map<String, dynamic>?> idTokenClaims() async {
    final idToken = await _storage.read(key: _kId);
    if (idToken == null) return null;
    final parts = idToken.split('.');
    if (parts.length != 3) return null;
    try {
      final payload = utf8.decode(base64Url.decode(base64Url.normalize(parts[1])));
      return jsonDecode(payload) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<void> logout() async {
    // Stop continuous tracking on sign-out (best-effort; must not block logout).
    try {
      await GeolocationService.tracker.stop();
    } catch (_) {}
    // Clear the registration flag so the next login re-registers (idempotent
    // for the same user+device; surfaces a conflict on user switch).
    await Preferences.instance.setBool(Preferences.deviceRegistered, false);
    await Future.wait([
      _storage.delete(key: _kAccess),
      _storage.delete(key: _kRefresh),
      _storage.delete(key: _kId),
      _storage.delete(key: _kExpiry),
    ]);
    authState.value = false;
  }

  Future<void> _store({
    required String? access,
    required String? refresh,
    required String? id,
    required DateTime? expiry,
  }) async {
    await _storage.write(key: _kAccess, value: access);
    await _storage.write(key: _kRefresh, value: refresh);
    await _storage.write(key: _kId, value: id);
    await _storage.write(key: _kExpiry, value: expiry?.toIso8601String());
  }
}
