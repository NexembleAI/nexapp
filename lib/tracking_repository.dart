import 'models/tracking_models.dart';

/// Tracking/device configuration domain (tracking.device office_hours, §4.1)
/// plus position-derived display data.
abstract class TrackingRepository {
  /// Assigned once at startup (main.dart): mock now, Nexcore-backed later.
  static late TrackingRepository instance;

  Future<OfficeHours> officeHours();

  /// Activity levels (0..1) for the hero card's bar graph, oldest first.
  Future<List<double>> todayActivity();
}
