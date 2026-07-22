import 'device_service.dart';
import 'home_controller.dart';
import 'models/tracking_models.dart';
import 'tracking_repository.dart';

/// Real TrackingRepository: office hours from the device row, weekly activity
/// from the Home coordinator's sessions. Both are Home/Settings surfaces.
class NexcoreTrackingRepository implements TrackingRepository {
  @override
  Future<OfficeHours> officeHours() => DeviceService.fetchOfficeHours();

  @override
  Future<List<double>> weeklyActivity() async {
    await HomeController.instance.ensureLoaded();
    // 7 zeros when unloaded/failed — renders a flat graph, no throw.
    return HomeController.instance.weeklyActivity;
  }
}
