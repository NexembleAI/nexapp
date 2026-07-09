import 'package:flutter/foundation.dart';

import 'models/tracking_models.dart';

/// Client-side default until snooze policy (duration/cap) is defined
/// server-side — coverage_rule has no snooze columns yet (§4.6 gap).
const Duration defaultSnoozeDuration = Duration(days: 3);

/// Lead-coverage alerts domain (backend arrives in Phase 3).
abstract class AlertsRepository {
  /// Assigned once at startup (main.dart): mock now, Nexcore-backed later.
  static late AlertsRepository instance;

  /// Notifies after any mutation that may change [openAlertsCount] or
  /// [alerts] — the tab badge and inbox listen to stay in sync.
  Listenable get changes;

  /// Count of alerts needing action — feeds the tab badge and the Home
  /// stats tile; single owner of this fact.
  Future<int> openAlertsCount();

  /// Full inbox, newest first (both needs-action and handled alerts).
  Future<List<LeadAlert>> alerts();

  /// Acknowledge: stops the manager-escalation clock; the alert stays
  /// unresolved until a lead-tagged visit report (or Won/Lost) closes it.
  Future<void> ack(String id);

  /// Defer until [until]; the workflow reopens the alert when it expires.
  Future<void> snooze(String id, DateTime until);
}
