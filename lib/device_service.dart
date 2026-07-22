import 'models/tracking_models.dart';
import 'preferences.dart';
import 'tracking_api_client.dart';
import 'tracking_dto.dart';

/// Read-only device queries for the rep's own phone (own-scoped by the backend).
class DeviceService {
  DeviceService._();

  /// This phone's office-hours window, derived from its ACTIVE device row
  /// (ListDevices). Always returns a concrete value:
  ///   • today's window if the schedule has one,
  ///   • [OfficeHours.closedToday] if today is a configured non-working day,
  ///   • [OfficeHours.defaultHours] (9:00–17:30) when there's no schedule at all,
  ///     or the device isn't found, or the call fails.
  /// The phone is matched by unique_id (== Preferences.id, the RegisterDevice id).
  static Future<OfficeHours> fetchOfficeHours() async {
    try {
      final myId = Preferences.instance.getString(Preferences.id);
      final raw = await TrackingApiClient.instance.get('device');
      final j = (raw is Map) ? raw.cast<String, dynamic>() : const {};
      final list = j['devices'];
      if (list is! List) return OfficeHours.defaultHours;

      // ListDevices is own-scoped, so every row belongs to this user. Prefer an
      // exact unique_id match; otherwise fall back to the (single) ACTIVE device
      // — robust to Preferences.id being momentarily unavailable at startup.
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
      return OfficeHours.tryFromDeviceJson(
              match == null ? null : Wire.string(match, 'office_hours')) ??
          OfficeHours.defaultHours;
    } on ApiException {
      return OfficeHours.defaultHours; // neutral badge; don't fail the card load
    }
  }
}
