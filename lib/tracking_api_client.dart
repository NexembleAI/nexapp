import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;

import 'auth_config.dart';
import 'auth_service.dart';

/// Transport-level classification of a failed tracking API call, mapped from
/// the gRPC status code in the REST error body (with an HTTP-status fallback).
/// This is the *transport* meaning only — a code's endpoint-specific business
/// meaning (e.g. RegisterDevice reading FailedPrecondition as "user already has
/// a device") stays the caller's job, via [ApiException.code].
enum ApiErrorKind {
  unauthenticated, // gRPC 16 / HTTP 401 — no valid token even after refresh
  forbidden,       // gRPC 7  / HTTP 403 — not permitted for this persona
  notFound,        // gRPC 5  / HTTP 404
  invalid,         // gRPC 3  — malformed request (a client bug)
  unavailable,     // gRPC 14 / HTTP 503 — service off/down (e.g. CRM resolver disabled)
  retryable,       // gRPC 13 / HTTP 5xx / network / timeout
}

/// Typed failure from [TrackingApiClient]. Callers switch on [kind] for the
/// transport-level reaction (e.g. CrmNameResolver treats
/// [ApiErrorKind.unavailable] as "no names"); [code] preserves the raw gRPC
/// status code so a caller that needs endpoint-specific business meaning (an
/// ack/snooze rejecting a resolved alert, say) can interpret it itself.
class ApiException implements Exception {
  final ApiErrorKind kind;
  final int? code; // raw gRPC status code from the body (null if unparseable)
  final String? message;
  final int? statusCode; // HTTP status
  const ApiException(this.kind, {this.code, this.message, this.statusCode});

  @override
  String toString() => 'ApiException(${kind.name}'
      '${code != null ? ' grpc=$code' : ''}'
      '${statusCode != null ? ' http=$statusCode' : ''}'
      '${message != null ? ' "$message"' : ''})';
}

/// Thin REST client for the Nexcore tracking read APIs (Home / Reports /
/// Alerts). Generalizes the pattern established by [TrackingService]: builds
/// `…/tenant/{id}/tracking/<path>` URLs, attaches the bearer token
/// (auto-refreshed, with one forced-refresh retry on a 401), trusts the dev CA
/// over HTTPS, bounds every call with timeouts, and maps the gRPC status code
/// in the error body to a typed [ApiException]. Returns the decoded JSON body
/// on 200.
class TrackingApiClient {
  TrackingApiClient._();
  static final TrackingApiClient instance = TrackingApiClient._();

  static final String _base =
      '${AuthConfig.nexCoreUrl}/v1/api/tenant/${AuthConfig.tenantId}/tracking';

  static const Duration _connectTimeout = Duration(seconds: 5);
  static const Duration _requestTimeout = Duration(seconds: 15); // send + read
  static const Duration _authTimeout = Duration(seconds: 10);

  /// GETs a tracking endpoint. [path] is relative to the tracking base
  /// (e.g. `'visit/session'`); [query] becomes the query string — a `List`
  /// value renders as repeated params (`?k=a&k=b`, the collectionFormat:multi
  /// the gateway expects for crm/names). [timeout] bounds the send+read for
  /// this call (defaults to [_requestTimeout]) — the audio GET passes a longer
  /// bound because a base64 audio body dwarfs the metadata reads. Returns the
  /// decoded JSON (a `Map` or `List`), or throws [ApiException].
  Future<Object?> get(String path,
          {Map<String, dynamic>? query, Duration? timeout}) =>
      _exchangeWithRetry('GET', _uri(path, query), timeout: timeout);

  /// PUTs [body] (JSON-encoded, `Content-Type: application/json`) to a tracking
  /// endpoint — the write counterpart to [get], sharing its token/401-retry
  /// path. [path] is relative to the tracking base; [timeout] bounds the call.
  /// Returns the decoded JSON on 200, or throws [ApiException].
  Future<Object?> put(String path,
          {Map<String, dynamic>? body, Duration? timeout}) =>
      _exchangeWithRetry('PUT', _uri(path, null), body: body, timeout: timeout);

  /// Runs one request with the current (proactively-refreshed) token; on a 401,
  /// forces one refresh and retries, covering a server reject of a
  /// locally-valid token. Shared by [get]/[put] so both get the same retry.
  Future<Object?> _exchangeWithRetry(String method, Uri uri,
      {Map<String, dynamic>? body, Duration? timeout}) async {
    try {
      return await _send(method, uri, await _token(force: false),
          body: body, timeout: timeout);
    } on ApiException catch (e) {
      if (e.kind != ApiErrorKind.unauthenticated) rethrow;
      return await _send(method, uri, await _token(force: true),
          body: body, timeout: timeout);
    }
  }

  Uri _uri(String path, Map<String, dynamic>? query) {
    final qp = <String, dynamic>{};
    query?.forEach((k, v) {
      if (v == null) return;
      qp[k] = v is Iterable
          ? v.map((e) => e.toString()).toList() // repeated params
          : v.toString();
    });
    return Uri.parse('$_base/$path')
        .replace(queryParameters: qp.isEmpty ? null : qp);
  }

  /// Access token, or throw. [force] uses [AuthService.refreshToken] (post-401);
  /// otherwise the normal proactively-refreshing [AuthService.accessToken].
  Future<String> _token({required bool force}) async {
    final String? t;
    try {
      t = await (force
              ? AuthService.instance.refreshToken()
              : AuthService.instance.accessToken())
          .timeout(_authTimeout);
    } on TimeoutException {
      throw const ApiException(ApiErrorKind.retryable, message: 'auth timeout');
    }
    if (t == null) {
      // accessToken()/refreshToken() returning null means the session is dead
      // (logout has run). Genuinely unauthenticated — no point retrying.
      throw const ApiException(ApiErrorKind.unauthenticated,
          message: 'no access token');
    }
    return t;
  }

  Future<Object?> _send(String method, Uri uri, String token,
      {Map<String, dynamic>? body, Duration? timeout}) async {
    final client = await _httpClient();
    try {
      return await _exchange(client, method, uri, token, body)
          .timeout(timeout ?? _requestTimeout);
    } on SocketException catch (e) {
      throw ApiException(ApiErrorKind.retryable, message: 'network: ${e.message}');
    } on HttpException catch (e) {
      throw ApiException(ApiErrorKind.retryable, message: 'http: ${e.message}');
    } on TimeoutException {
      throw const ApiException(ApiErrorKind.retryable, message: 'timeout');
    } finally {
      client.close(force: true);
    }
  }

  Future<Object?> _exchange(HttpClient client, String method, Uri uri,
      String token, Map<String, dynamic>? body) async {
    final request = await client.openUrl(method, uri);
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    if (body != null) {
      // Send a JSON body (writes UTF-8 via the request's default encoding).
      request.headers.contentType = ContentType('application', 'json');
      request.write(jsonEncode(body));
    }
    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();
    if (response.statusCode == 200) {
      if (text.isEmpty) return null;
      try {
        return jsonDecode(text);
      } catch (_) {
        throw const ApiException(ApiErrorKind.retryable, message: 'bad JSON');
      }
    }
    throw _mapError(response.statusCode, text);
  }

  /// Prefers the gRPC `code` in the JSON error body (several share HTTP 400);
  /// falls back to the HTTP status. Preserves the raw [code] on the exception
  /// for callers that need endpoint-specific business meaning.
  static ApiException _mapError(int status, String body) {
    int? code;
    String? message;
    try {
      final j = jsonDecode(body) as Map<String, dynamic>;
      code = (j['code'] as num?)?.toInt();
      message = j['message'] as String?;
    } catch (_) {}

    final kind = switch (code) {
      16 => ApiErrorKind.unauthenticated,
      7 => ApiErrorKind.forbidden,
      5 => ApiErrorKind.notFound,
      3 => ApiErrorKind.invalid,
      14 => ApiErrorKind.unavailable,
      13 => ApiErrorKind.retryable,
      _ => switch (status) {
          401 => ApiErrorKind.unauthenticated,
          403 => ApiErrorKind.forbidden,
          404 => ApiErrorKind.notFound,
          503 => ApiErrorKind.unavailable,
          _ => ApiErrorKind.retryable, // includes 5xx and anything unmapped
        },
    };
    return ApiException(kind, code: code, message: message, statusCode: status);
  }

  /// HttpClient trusting the bundled dev CA (mkcert) in dev, like
  /// [TrackingService]. dart:io ignores Android's network_security_config, so
  /// the CA is supplied via a SecurityContext, built once and reused.
  Future<HttpClient> _httpClient() async {
    _securityContext ??= await _buildSecurityContext();
    return HttpClient(context: _securityContext)
      ..connectionTimeout = _connectTimeout;
  }

  static SecurityContext? _securityContext;

  static Future<SecurityContext> _buildSecurityContext() async {
    final context = SecurityContext(withTrustedRoots: true);
    if (AuthConfig.isDev) {
      try {
        final pem = await rootBundle.load('assets/certs/nexemble_ca.pem');
        context.setTrustedCertificatesBytes(pem.buffer.asUint8List());
      } catch (e) {
        developer.log('TrackingApiClient: failed to load bundled CA', error: e);
      }
    }
    return context;
  }
}
