import 'dart:developer' as developer;

import 'models/tracking_models.dart';
import 'preferences.dart';
import 'tracking_api_client.dart';
import 'tracking_dto.dart';

/// Read-only device queries for the rep's own phone (own-scoped by the backend).
class DeviceService {
  DeviceService._();

  // Cache the raw office_hours SCHEDULE (not the parsed window). Today's window
  // is re-derived per read (tryFromDeviceJson keys off DateTime.now()), so it
  // stays correct across a day boundary — e.g. the app resumed the next morning
  // shows Monday's window, not Sunday's "Closed today" — WITHOUT a re-fetch.
  // Concurrent startup fetches (card + Settings) coalesce into one /device GET;
  // a failed fetch isn't cached, so it retries.
  static String? _cachedRaw; // the device's office_hours JSON; null == none
  static bool _hasRaw = false; // distinguishes "no schedule" from "not fetched"
  static Future<String?>? _inflight;
  static int _generation = 0;

  /// Drops the cached schedule on sign-out (a different user = a different
  /// device row / hours). Bumping [_generation] stops an in-flight fetch from
  /// caching the previous user's schedule.
  static void clearCache() {
    _generation++;
    _cachedRaw = null;
    _hasRaw = false;
    _inflight = null;
  }

  /// This phone's office-hours window for TODAY, derived from its ACTIVE device
  /// row (ListDevices). Always returns a concrete value:
  ///   • today's window if the schedule has one,
  ///   • [OfficeHours.closedToday] if today is a configured non-working day,
  ///   • [OfficeHours.defaultHours] (9:00–17:30) when there's no schedule at all,
  ///     or the device isn't found, or the call fails.
  /// The phone is matched by unique_id (== Preferences.id, the RegisterDevice id).
  /// Re-call it (e.g. on app resume) to pick up a day change — it re-parses the
  /// cached schedule without hitting the network.
  static Future<OfficeHours> fetchOfficeHours() async {
    final raw = _hasRaw
        ? _cachedRaw
        : await (_inflight ??=
            _fetchRawSchedule().whenComplete(() => _inflight = null));
    return OfficeHours.tryFromDeviceJson(raw) ?? OfficeHours.defaultHours;
  }

  /// GETs ListDevices and returns this phone's raw `office_hours` string (or null
  /// when there's no match/schedule). Caches it on a clean fetch; a network
  /// failure returns null WITHOUT caching so it retries.
  static Future<String?> _fetchRawSchedule() async {
    final gen = _generation;
    try {
      final myId = Preferences.instance.getString(Preferences.id);
      final resp = await TrackingApiClient.instance.get('device');
      final j = (resp is Map) ? resp.cast<String, dynamic>() : const {};
      final list = j['devices'];

      String? officeHours;
      if (list is List) {
        // ListDevices is own-scoped, so every row belongs to this user. Prefer
        // an exact unique_id match; otherwise fall back to the (single) ACTIVE
        // device — robust to Preferences.id being momentarily unavailable.
        Map<String, dynamic>? byId, anyActive, anyDevice;
        for (final d in list) {
          if (d is! Map) continue;
          final dm = d.cast<String, dynamic>();
          anyDevice ??= dm;
          final isActive = Wire.string(dm, 'status') == 'DEVICE_STATUS_ACTIVE';
          if (isActive) anyActive ??= dm;
          if (myId != null &&
              myId.isNotEmpty &&
              Wire.string(dm, 'unique_id') == myId) {
            byId = dm;
            if (isActive) break; // ideal: the active row for this exact phone
          }
        }
        final match = byId ?? anyActive ?? anyDevice;
        officeHours = match == null ? null : Wire.string(match, 'office_hours');
      }

      // Cache the clean fetch — unless a sign-out (clearCache) happened
      // mid-flight, else we'd re-pin the old user's schedule.
      if (gen == _generation) {
        _cachedRaw = officeHours;
        _hasRaw = true;
      }
      return officeHours;
    } catch (e) {
      // Catch-all: DeviceService must NEVER throw — the tracking card awaits it
      // unguarded (_loadRepositoryData), so a bare ApiException *or* a shape
      // surprise (e.g. a non-string office_hours → a cast error in Wire.string)
      // would be an unhandled async error and stick the card at '—'. Degrade to
      // the default. Don't cache — retry on the next call.
      developer.log('DeviceService: office hours fetch failed ($e)');
      return null;
    }
  }
}
