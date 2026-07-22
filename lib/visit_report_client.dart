import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'auth_config.dart';
import 'auth_service.dart';
import 'models/tracking_models.dart';
import 'upload_queue.dart';
import 'upload_uploader.dart';

/// Debug-only logger for the visit-report upload. `[report]` prefix so it's
/// easy to spot in `flutter run`; a no-op in release builds. Mirrors
/// [registerDebugLog] in tracking_service.dart.
void reportDebugLog(String message) {
  if (kDebugMode) debugPrint('[report] $message');
}

/// The transport seam under [VisitReportClient] — the one thing that touches
/// dart:io. Split out so the classification and 401 logic are unit-testable
/// against a fake without a live socket. Returns the `(status, body)` pair;
/// throws SocketException / TimeoutException / TlsException / HttpException for
/// the transient failures the policy treats as retryable.
abstract class VisitReportTransport {
  Future<(int statusCode, String body)> send({
    required Uri uri,
    required String token,
    required Map<String, dynamic> metadata,
    String? audioFilePath,
    String? audioMime,
  });
}

/// Real transport for [SubmitVisitReport] — POSTs `multipart/form-data` to the
/// tracking REST edge.
///
/// The proto's "REST edge accepts multipart" is now real: the backend edge
/// (mirroring `apiserver/lib/portability_upload.go`) parses a `report` JSON
/// part (protojson of SubmitVisitReportRequest, minus the audio bytes) and an
/// optional `audio` byte part streamed into `audio_bytes`. Streaming the file
/// means the audio never sits base64-inflated in memory or on the wire.
class HttpMultipartVisitReportTransport implements VisitReportTransport {
  const HttpMultipartVisitReportTransport();

  // A hung connect / stalled edge must not wedge the drain forever. A timeout
  // maps to a thrown TimeoutException -> retryable, feeding the queue's backoff.
  static const Duration _connectTimeout = Duration(seconds: 30);
  static const Duration _totalTimeout = Duration(seconds: 60); // whole send+read

  @override
  Future<(int, String)> send({
    required Uri uri,
    required String token,
    required Map<String, dynamic> metadata,
    String? audioFilePath,
    String? audioMime,
  }) async {
    final client = await _httpClient();
    try {
      return await _send(client, uri, token, metadata, audioFilePath, audioMime)
          .timeout(_totalTimeout);
    } finally {
      client.close(force: true);
    }
  }

  Future<(int, String)> _send(
    HttpClient client,
    Uri uri,
    String token,
    Map<String, dynamic> metadata,
    String? audioFilePath,
    String? audioMime,
  ) async {
    final boundary = _newBoundary();
    final request = await client.postUrl(uri);
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    request.headers.contentType =
        ContentType('multipart', 'form-data', parameters: {'boundary': boundary});

    // Part 1 — the metadata as protobuf-JSON (camelCase). Ends with the CRLF
    // that separates it from the next boundary.
    final head = utf8.encode(
      '--$boundary\r\n'
      'Content-Disposition: form-data; name="report"\r\n'
      'Content-Type: application/json; charset=utf-8\r\n'
      '\r\n'
      '${jsonEncode(metadata)}\r\n',
    );

    // Part 2 (optional) — the raw audio bytes, streamed from disk.
    List<int> audioHeader = const [];
    List<int> tail;
    File? audioFile;
    var audioLen = 0;
    if (audioFilePath != null) {
      audioFile = File(audioFilePath);
      audioLen = await audioFile.length();
      audioHeader = utf8.encode(
        '--$boundary\r\n'
        'Content-Disposition: form-data; name="audio"; filename="audio"\r\n'
        'Content-Type: ${audioMime ?? 'application/octet-stream'}\r\n'
        '\r\n',
      );
      tail = utf8.encode('\r\n--$boundary--\r\n');
    } else {
      tail = utf8.encode('--$boundary--\r\n');
    }

    // A known Content-Length keeps the upload off chunked encoding — friendlier
    // to the edge's multipart parser than a streamed unknown length. audioLen is
    // read once above; the queue's audio file is immutable after enqueue, so it
    // can't desync the stream (and dart:io errors rather than corrupting if it
    // ever did -> retryable).
    request.contentLength = head.length + audioHeader.length + audioLen + tail.length;

    request.add(head);
    if (audioFile != null) {
      request.add(audioHeader);
      await request.addStream(audioFile.openRead());
    }
    request.add(tail);

    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    return (response.statusCode, body);
  }

  static String _newBoundary() {
    final rand = Random();
    final suffix = List.generate(
      16,
      (_) => rand.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    return '----nexappVisitReport$suffix';
  }

  /// HttpClient that trusts the bundled Nexemble dev CA (mkcert) in dev, exactly
  /// like [TrackingService] — dart:io ignores Android's network_security_config,
  /// so the CA must be supplied via a SecurityContext. Dead-code-eliminated in
  /// prod by the `AuthConfig.isDev` const gate. Context built once and reused.
  static Future<HttpClient> _httpClient() async {
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
        developer.log('visit-report: failed to load bundled CA', error: e);
      }
    }
    return context;
  }
}

/// Real `SubmitVisitReport` transport injected into [UploadUploader.upload]
/// (replacing the PR #16 simulation). Maps a queued report to the multipart
/// request, POSTs it with the Keycloak bearer token, and classifies the
/// response into an [UploadOutcome] — never throws for transport errors.
///
/// This is the whole seam: the durable queue (P2.4) owns retry/backoff/
/// idempotency around this hook, so the client's only job is to submit once and
/// return the right verdict. The idempotency key is sourced from the queue row
/// (stable across retries and restarts), so a re-send reuses the server row.
class VisitReportClient {
  VisitReportClient({
    VisitReportTransport? transport,
    Future<String?> Function()? accessToken,
    Future<String?> Function()? refreshToken,
    void Function()? markSessionRejected,
    String? Function(QueuedReport)? audioPathResolver,
    Uri? endpoint,
  })  : _transport = transport ?? const HttpMultipartVisitReportTransport(),
        _accessToken = accessToken ?? AuthService.instance.accessToken,
        _refreshToken = refreshToken ?? AuthService.instance.refreshToken,
        _markSessionRejected =
            markSessionRejected ?? AuthService.instance.markSessionRejected,
        _audioPathResolver =
            audioPathResolver ?? UploadQueue.instance.absoluteAudioPath,
        _endpoint = endpoint ?? _defaultEndpoint;

  final VisitReportTransport _transport;
  final Future<String?> Function() _accessToken;
  final Future<String?> Function() _refreshToken;
  final void Function() _markSessionRejected;
  final String? Function(QueuedReport) _audioPathResolver;
  final Uri _endpoint;

  static final Uri _defaultEndpoint = Uri.parse(
    '${AuthConfig.nexCoreUrl}/v1/api/tenant/${AuthConfig.tenantId}/tracking/visit/report',
  );

  /// Submits one queued report and returns its classified outcome. Wire as
  /// `UploadUploader.instance.upload = VisitReportClient().submit`.
  Future<UploadOutcome> submit(QueuedReport item) async {
    final token = await _accessToken();
    if (token == null) {
      // No usable session at all. Make sure a resume edge exists (see below) and
      // pause the drain until the user signs in again.
      reportDebugLog('no access token -> unauthenticated');
      _markSessionRejected();
      return UploadOutcome.unauthenticated;
    }

    final first = await _attempt(item, token);
    if (first != UploadOutcome.unauthenticated) return first;

    // 401: the token was rejected server-side (revoked or clock-skewed — a plain
    // expiry would already have been refreshed by accessToken()). Force one
    // refresh and retry before giving up.
    reportDebugLog('401 -> forcing token refresh and retrying once');
    final refreshed = await _refreshToken();
    if (refreshed == null) {
      // Refresh failed: AuthService.logout() has already flipped authState=false,
      // so the resume edge is covered. Just pause the drain.
      reportDebugLog('refresh failed -> unauthenticated');
      return UploadOutcome.unauthenticated;
    }

    final second = await _attempt(item, refreshed);
    if (second == UploadOutcome.unauthenticated) {
      // Still 401 with a fresh token: the session itself is dead. Nothing else
      // writes authState=false on a server-side rejection, so flip it here — the
      // login screen appears and the uploader's authState listener resumes the
      // drain on the next sign-in.
      reportDebugLog('still 401 after refresh -> marking session rejected');
      _markSessionRejected();
    }
    return second;
  }

  /// A single POST + classify. Catches the transport exceptions the policy maps
  /// to retryable, so [submit] never throws for a network blip.
  Future<UploadOutcome> _attempt(QueuedReport item, String token) async {
    final metadata = buildMetadata(item);
    final audioPath = item.audioPath != null ? _audioPathResolver(item) : null;
    try {
      final (status, body) = await _transport.send(
        uri: _endpoint,
        token: token,
        metadata: metadata,
        audioFilePath: audioPath,
        audioMime: item.audioMime,
      );
      final outcome = _classify(status, body);
      reportDebugLog('HTTP $status -> ${outcome.name}');
      return outcome;
    } on SocketException catch (e) {
      reportDebugLog('network error: ${e.message} -> retryable');
      return UploadOutcome.retryable;
    } on TimeoutException {
      reportDebugLog('request timed out -> retryable');
      return UploadOutcome.retryable;
    } on HttpException catch (e) {
      reportDebugLog('http error: ${e.message} -> retryable');
      return UploadOutcome.retryable;
    } on TlsException catch (e) {
      // Includes HandshakeException (dev CA / cert issues) — transient enough to
      // retry; the attempt cap bounds a genuinely broken config.
      reportDebugLog('tls error: ${e.message} -> retryable');
      return UploadOutcome.retryable;
    } catch (e) {
      reportDebugLog('unexpected error: $e -> retryable');
      developer.log('visit-report: unexpected upload error', error: e);
      return UploadOutcome.retryable;
    }
  }

  /// Maps the queued report to the `report` JSON part — protobuf-JSON of
  /// SubmitVisitReportRequest, camelCase, **without** the audio bytes (those go
  /// in the streamed `audio` part). Pure, so the mapping is unit-tested directly.
  @visibleForTesting
  static Map<String, dynamic> buildMetadata(QueuedReport item) {
    final meta = <String, dynamic>{
      // tenant_id is required in the body as well as the path (server rejects
      // otherwise). It's not carried in the token, so it comes from AuthConfig.
      'tenantId': int.parse(AuthConfig.tenantId),
      // Never regenerated — the queue row's key is what makes a retry idempotent.
      'idempotencyKey': item.idempotencyKey,
      'customerId': item.customerId,
    };
    // visit_session_id omitted: manual reports carry none, and empty ⇒ the
    // server opens a manual session.
    if (item.notes.isNotEmpty) meta['textBody'] = item.notes;
    if (item.leadIds.isNotEmpty) meta['leadIds'] = item.leadIds;
    if (item.latitude != null && item.longitude != null) {
      meta['reportPosition'] = {
        'latitude': item.latitude,
        'longitude': item.longitude,
      };
    }
    // Audio metadata rides alongside the byte part so the server has the mime +
    // duration without re-deriving them; the fields are absent when there's no
    // audio (a text-only report sends no `audio` part at all).
    if (item.audioPath != null) {
      if (item.audioMime != null) meta['audioMimeType'] = item.audioMime;
      if (item.audioDurationMs != null) {
        // Client stores ms; the field is int seconds (metadata only server-side).
        meta['audioDurationS'] = (item.audioDurationMs! / 1000).round();
      }
    }
    return meta;
  }

  /// The classification table (approach §3.2). Prefers the gRPC `code` in the
  /// JSON error body (several codes share one HTTP status); falls back to the
  /// HTTP status when the code is absent/unknown.
  @visibleForTesting
  static UploadOutcome classify(int status, String body) =>
      _classify(status, body);

  static UploadOutcome _classify(int status, String body) {
    if (status == 200) return UploadOutcome.success;

    switch (_grpcCode(body)) {
      case 3: // InvalidArgument — malformed/empty report; a retry can't fix it.
        return UploadOutcome.terminal;
      case 5: // NotFound — bad tenant/customer.
        return UploadOutcome.terminal;
      case 7: // PermissionDenied — RBAC/scope; retry won't fix it.
        return UploadOutcome.terminal;
      case 8: // ResourceExhausted — audio over cap; the payload won't shrink.
        // NB: this arrives as HTTP 429 (the edge maps ResourceExhausted->429,
        // shared with rate-limiting), so the code MUST win over the status — a
        // status-only classifier would call it retryable and burn every attempt.
        return UploadOutcome.terminal;
      case 16: // Unauthenticated.
        return UploadOutcome.unauthenticated;
      case 4: // DeadlineExceeded.
      case 13: // Internal — incl. the Phase-2 F4 concurrent same-key race.
      case 14: // Unavailable.
        return UploadOutcome.retryable;
    }

    // HTTP-status fallback when there was no recognizable gRPC code.
    if (status == 401) return UploadOutcome.unauthenticated;
    if (status == 400 || status == 403 || status == 404 || status == 413) {
      return UploadOutcome.terminal;
    }
    if (status == 408 || status == 429 || status >= 500) {
      return UploadOutcome.retryable;
    }
    // An unknown 4xx the edge rejected outright: a retry won't change the verdict.
    return UploadOutcome.terminal;
  }

  static int? _grpcCode(String body) {
    try {
      final j = jsonDecode(body);
      if (j is Map<String, dynamic>) return (j['code'] as num?)?.toInt();
    } catch (_) {}
    return null;
  }
}
