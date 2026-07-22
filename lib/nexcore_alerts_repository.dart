import 'package:flutter/foundation.dart';

import 'alerts_repository.dart';
import 'home_controller.dart';
import 'models/tracking_models.dart';

/// Real AlertsRepository. The Home needs-action count comes from the Home
/// coordinator; the Alerts-tab methods delegate to [_tabs] (the mock) until that
/// tab is built. `changes` merges both sources — cached in a `late final` so
/// add/removeListener target the same instance.
class NexcoreAlertsRepository implements AlertsRepository {
  final AlertsRepository _tabs;
  NexcoreAlertsRepository(this._tabs);

  @override
  late final Listenable changes =
      Listenable.merge([HomeController.instance, _tabs.changes]);

  @override
  Future<int> openAlertsCount() async {
    await HomeController.instance.ensureLoaded();
    if (HomeController.instance.hasError) throw const HomeDataException();
    return HomeController.instance.openAlertsCount;
  }

  // Alerts tab — still mock until it's built.
  @override
  Future<List<LeadAlert>> alerts() => _tabs.alerts();

  @override
  Future<void> ack(String id) => _tabs.ack(id);

  @override
  Future<void> snooze(String id, DateTime until) => _tabs.snooze(id, until);
}
