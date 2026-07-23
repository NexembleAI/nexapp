import 'package:flutter/material.dart';

import '../alerts_repository.dart';
import '../customers_repository.dart';
import '../models/tracking_models.dart';
import '../reports_repository.dart';
import '../tracking_repository.dart';

/// Canned data matching the design mockups (doc/design/04-home-*.png).
/// This whole folder is deleted once the real backends land; main.dart holds
/// the only imports of it.
///
/// Every method waits [_latency] so loading states are actually exercised.
const _latency = Duration(milliseconds: 400);

/// ChangeNotifier with a public notify — notifyListeners is protected.
class _MockChanges extends ChangeNotifier {
  void bump() => notifyListeners();
}

// Shared mock CRM data (single source for customers/leads/alerts/reports).
// Lead-to-customer mapping follows the alert mocks; note the design mocks
// are internally inconsistent here (screen 05 shows Q3 Fleet Renewal under
// Meridian, screens 09/10 under Apex) — the alerts win.
const _mockCustomers = [
  Customer(id: 'c1', name: 'Meridian Logistics', address: '3400 Industrial Pkwy'),
  Customer(id: 'c2', name: 'Apex Manufacturing', address: '78 Foundry Road'),
  Customer(id: 'c3', name: 'Coastal Retail Group', address: '12 Harbourfront Ave'),
  Customer(id: 'c4', name: 'Vanguard Pharma', address: '5 Science Park Drive'),
  Customer(id: 'c5', name: 'Northwind Traders', address: '220 Market Street'),
  Customer(id: 'c6', name: 'Trident Foods', address: '41 Cold Store Lane'),
  Customer(id: 'c7', name: 'Harbor & Co.', address: '9 Quayside Walk'),
  Customer(id: 'c8', name: 'Solstice Hospitality', address: '17 Grand Esplanade'),
  Customer(id: 'c9', name: 'Brightwell Foods', address: '88 Cold Storage Way'),
];

const _mockLeads = [
  Lead(id: 'l1', title: 'Q3 Fleet Renewal', customerId: 'c2'), // alert a1
  Lead(id: 'l2', title: 'Annual Supply Contract', customerId: 'c3'), // a2
  Lead(id: 'l3', title: 'POS Rollout', customerId: 'c7'), // a3
  Lead(id: 'l4', title: 'Lead going stale', customerId: 'c8'), // a4
  Lead(id: 'l5', title: 'Warehouse Expansion', customerId: 'c6'), // a5
  Lead(id: 'l6', title: 'Telematics Add-on', customerId: 'c1'),
  Lead(id: 'l7', title: 'Depot Automation Pilot', customerId: 'c1'),
  Lead(id: 'l8', title: 'Cold-chain Monitoring', customerId: 'c4'),
  Lead(id: 'l9', title: 'Cold-chain Upgrade', customerId: 'c9'), // report r2
  Lead(id: 'l10', title: 'Refrigeration Retrofit', customerId: 'c9'),
  // c5 Northwind deliberately has none — exercises the no-leads case.
];

class MockCustomersRepository implements CustomersRepository {
  @override
  Future<List<Customer>> myCustomers() async {
    await Future.delayed(_latency);
    return _mockCustomers;
  }

  @override
  Future<List<Lead>> leadsForCustomer(String customerId) async {
    await Future.delayed(_latency);
    return _mockLeads.where((l) => l.customerId == customerId).toList();
  }
}

class MockReportsRepository implements ReportsRepository {
  final TodayStats _todayStats = const TodayStats(visits: 4, reports: 3);

  /// Called by the uploader on success (mock-only): the uploaded report
  /// becomes a server-side `submitted` report in history.
  void addSubmitted(QueuedReport item) {
    _records.insert(
      0,
      ReportDetail(
        id: item.idempotencyKey,
        customerId: item.customerId,
        customerName: item.customerName,
        createdAt: DateTime.now(),
        status: ReportStatus.submitted,
        geofencePresent: false, // manual, no geofence session (§3.3)
        notes: item.notes,
        audioPresent: item.hasAudio,
        audioDurationS: item.audioDurationMs == null
            ? null
            : (item.audioDurationMs! / 1000).round(),
        audioMime: item.audioMime,
        leadIds: item.leadIds,
        version: 1,
      ),
    );
    _changes.bump();
  }

  @override
  Future<TodayStats> todayStats() async {
    await Future.delayed(_latency);
    return _todayStats;
  }

  @override
  Future<List<VisitEntry>> todayVisits() async {
    await Future.delayed(_latency);
    final today = DateTime.now();
    DateTime at(int h, int m) =>
        DateTime(today.year, today.month, today.day, h, m);
    return [
      VisitEntry(
        customerName: 'Cedar & Co.',
        enteredAt: at(14, 5),
        dwell: Duration.zero,
        ongoing: true, // still at the customer -> "Ongoing"
        status: null, // no report filed yet -> "No report yet"
      ),
      VisitEntry(
        customerName: 'Meridian Logistics',
        enteredAt: at(11, 20),
        dwell: const Duration(minutes: 24),
        status: ReportStatus.ready,
      ),
      VisitEntry(
        customerName: 'Brightwell Foods',
        enteredAt: at(9, 45),
        dwell: const Duration(minutes: 18),
        status: ReportStatus.transcribing,
      ),
    ];
  }

  final _MockChanges _changes = _MockChanges();

  @override
  Listenable get changes => _changes;

  late final List<ReportDetail> _records = _seedRecords();

  @override
  Future<List<ReportEntry>> reports() async {
    await Future.delayed(_latency);
    return _records.map(_entry).toList();
  }

  ReportEntry _entry(ReportDetail d) => ReportEntry(
        id: d.id,
        customerName: d.customerName,
        createdAt: d.createdAt,
        dwell: d.dwell,
        status: d.status,
        hasAudio: d.audioPresent,
        hasNotes: d.notes.isNotEmpty,
        geofencePresent: d.geofencePresent,
      );

  @override
  Future<ReportDetail> reportDetail(String id) async {
    await Future.delayed(_latency);
    return _records.firstWhere((r) => r.id == id);
  }

  @override
  Future<ReportStatusUpdate> reportStatus(String id) async {
    final r = await reportDetail(id);
    return ReportStatusUpdate(status: r.status, transcript: r.transcript);
  }

  @override
  Future<String?> reportAudio(String id) async => null;

  @override
  Future<void> updateReport(
    String id, {
    required String notes,
    required List<String> leadIds,
  }) async {
    await Future.delayed(_latency);
    final i = _records.indexWhere((r) => r.id == id);
    if (i < 0) return;
    final r = _records[i];
    final edits = [...r.edits];
    var version = r.version;
    final now = DateTime.now();
    // One audit entry per changed field, each bumping the version (§4.4.2).
    if (notes != r.notes) {
      version += 1;
      edits.add(ReportEdit(
        version: version,
        field: ReportEditField.textBody,
        editedAt: now,
      ));
    }
    if (!_sameLeads(leadIds, r.leadIds)) {
      version += 1;
      edits.add(ReportEdit(
        version: version,
        field: ReportEditField.leadTags,
        editedAt: now,
      ));
    }
    _records[i] = r.copyWith(
      notes: notes,
      leadIds: leadIds,
      version: version,
      edits: edits,
    );
    _changes.bump();
  }

  static bool _sameLeads(List<String> a, List<String> b) =>
      a.toSet().length == b.toSet().length &&
      a.toSet().containsAll(b.toSet());

  static List<ReportDetail> _seedRecords() {
    final now = DateTime.now();
    DateTime daysAgo(int d, int h, int m) {
      final day = now.subtract(Duration(days: d));
      return DateTime(day.year, day.month, day.day, h, m);
    }

    return [
      ReportDetail(
        id: 'r1',
        customerId: 'c1',
        customerName: 'Meridian Logistics',
        createdAt: daysAgo(0, 12, 4),
        dwell: const Duration(minutes: 24),
        status: ReportStatus.ready,
        geofencePresent: true,
        transcript: 'Walked the depot with the ops lead. They want to expand '
            'the fleet pilot to two more routes next quarter.',
        notes: 'Follow up on the telematics add-on pricing.',
        audioPresent: true,
        audioDurationS: 142,
        audioMime: 'audio/ogg; codecs=opus',
        leadIds: const ['l6'],
        version: 1,
      ),
      // The design-mock report (screen 08): edited twice, v3.
      ReportDetail(
        id: 'r2',
        customerId: 'c9',
        customerName: 'Brightwell Foods',
        createdAt: daysAgo(0, 9, 45),
        dwell: const Duration(minutes: 18),
        status: ReportStatus.ready,
        geofencePresent: true,
        transcript: 'Met with the procurement lead at Brightwell. They '
            'confirmed the cold-chain upgrade budget is approved for Q3 and '
            'want a revised quote covering two additional sites by Friday…',
        notes: 'Send revised quote covering the Riverside + Eastgate sites '
            'before Friday. Loop in finance on the lease-vs-buy option.',
        audioPresent: true,
        audioDurationS: 168,
        audioMime: 'audio/ogg; codecs=opus',
        leadIds: const ['l9'],
        version: 3,
        edits: [
          ReportEdit(
            version: 2,
            field: ReportEditField.textBody,
            editedAt: daysAgo(0, 10, 15),
          ),
          ReportEdit(
            version: 3,
            field: ReportEditField.textBody,
            editedAt: daysAgo(0, 11, 2),
          ),
        ],
      ),
      ReportDetail(
        id: 'r3',
        customerId: 'c2',
        customerName: 'Apex Manufacturing',
        createdAt: daysAgo(1, 14, 10),
        dwell: const Duration(minutes: 31),
        status: ReportStatus.transcribing,
        geofencePresent: true,
        notes: 'Discussed the Q3 fleet renewal timeline.',
        audioPresent: true,
        audioDurationS: 205,
        audioMime: 'audio/ogg; codecs=opus',
        leadIds: const ['l1'],
        version: 1,
      ),
      ReportDetail(
        id: 'r4',
        customerId: 'c4',
        customerName: 'Vanguard Pharma',
        createdAt: daysAgo(2, 16, 30),
        status: ReportStatus.submitted,
        geofencePresent: false,
        notes: 'Ad-hoc visit — no site geofence. Reviewed cold-chain '
            'monitoring options.',
        audioPresent: false,
        leadIds: const ['l8'],
        version: 1,
      ),
      ReportDetail(
        id: 'r5',
        customerId: 'c5',
        customerName: 'Northwind Traders',
        createdAt: daysAgo(11, 11, 5),
        dwell: const Duration(minutes: 22),
        status: ReportStatus.ready,
        geofencePresent: true,
        transcript: 'Quarterly check-in. Nothing urgent; renewal on track.',
        notes: 'No action needed this cycle.',
        audioPresent: false,
        leadIds: const [],
        version: 1,
      ),
    ];
  }
}

class MockAlertsRepository implements AlertsRepository {
  final _MockChanges _changes = _MockChanges();

  // In-memory state so ack/snooze visibly move cards between sections.
  late final List<LeadAlert> _alerts = () {
    final now = DateTime.now();
    return [
      // The design-mock scenario (screen 10): open, no-visit, high priority.
      LeadAlert(
        id: 'a1',
        leadId: 'l1',
        leadTitle: 'Q3 Fleet Renewal',
        accountName: 'Apex Manufacturing',
        customerId: 'c2',
        reason: AlertReason.noVisitWindow,
        daysSinceVisit: 9,
        thresholdDays: 7,
        createdAt: now,
        status: AlertStatus.open,
        stage: 'Negotiation',
        priority: AlertPriority.high,
        lastCoveredAt: now.subtract(const Duration(days: 9)),
        escalatesAt: now.add(const Duration(days: 2)),
        history: [AlertEvent(AlertEventType.opened, now)],
      ),
      LeadAlert(
        id: 'a2',
        leadId: 'l2',
        leadTitle: 'Annual Supply Contract',
        accountName: 'Coastal Retail Group',
        customerId: 'c3',
        reason: AlertReason.nextActivityOverdue,
        closeInDays: 12,
        createdAt: now.subtract(const Duration(days: 1)),
        status: AlertStatus.open,
        stage: 'Proposal',
        priority: AlertPriority.medium,
        lastCoveredAt: now.subtract(const Duration(days: 5)),
        escalatesAt: now.add(const Duration(days: 3)),
        history: [
          AlertEvent(AlertEventType.opened, now.subtract(const Duration(days: 1))),
        ],
      ),
      LeadAlert(
        id: 'a3',
        leadId: 'l3',
        leadTitle: 'POS Rollout',
        accountName: 'Harbor & Co.',
        customerId: 'c7',
        reason: AlertReason.noVisitWindow,
        daysSinceVisit: 12,
        thresholdDays: 10,
        createdAt: now.subtract(const Duration(days: 2)),
        status: AlertStatus.ack,
        stage: 'Won — delivery',
        priority: AlertPriority.medium,
        lastCoveredAt: now.subtract(const Duration(days: 12)),
        history: [
          AlertEvent(AlertEventType.opened, now.subtract(const Duration(days: 2))),
          AlertEvent(AlertEventType.acked, now.subtract(const Duration(days: 1))),
        ],
      ),
      LeadAlert(
        id: 'a4',
        leadId: 'l4',
        leadTitle: 'Lead going stale',
        accountName: 'Solstice Hospitality',
        customerId: 'c8',
        reason: AlertReason.leadStale,
        createdAt: now.subtract(const Duration(days: 3)),
        status: AlertStatus.snoozed,
        snoozeUntil: now.add(const Duration(days: 4)),
        stage: 'Qualified',
        priority: AlertPriority.low,
        history: [
          AlertEvent(AlertEventType.opened, now.subtract(const Duration(days: 3))),
          AlertEvent(AlertEventType.snoozed, now.subtract(const Duration(days: 1)),
              until: now.add(const Duration(days: 4))),
        ],
      ),
      // Reopened after an expired snooze — exercises the full
      // snooze -> reopened -> (ack) chain from the detail screen.
      LeadAlert(
        id: 'a5',
        leadId: 'l5',
        leadTitle: 'Warehouse Expansion',
        accountName: 'Trident Foods',
        customerId: 'c6',
        reason: AlertReason.noVisitWindow,
        daysSinceVisit: 11,
        thresholdDays: 7,
        createdAt: now.subtract(const Duration(days: 6)),
        status: AlertStatus.open,
        stage: 'Qualified',
        priority: AlertPriority.low,
        lastCoveredAt: now.subtract(const Duration(days: 11)),
        escalatesAt: now.add(const Duration(days: 2)),
        history: [
          AlertEvent(AlertEventType.opened, now.subtract(const Duration(days: 6))),
          AlertEvent(AlertEventType.snoozed, now.subtract(const Duration(days: 5)),
              until: now.subtract(const Duration(days: 2))),
          AlertEvent(AlertEventType.reopened, now.subtract(const Duration(days: 2))),
        ],
      ),
    ];
  }();

  @override
  Listenable get changes => _changes;

  @override
  Future<int> openAlertsCount() async {
    await Future.delayed(_latency);
    return _alerts.where((a) => a.needsAction).length;
  }

  @override
  Future<List<LeadAlert>> alerts() async {
    await Future.delayed(_latency);
    return List.unmodifiable(_alerts);
  }

  @override
  Future<void> ack(String id) => _update(
      id,
      (a) => a.copyWith(
            status: AlertStatus.ack,
            history: [
              ...a.history,
              AlertEvent(AlertEventType.acked, DateTime.now()),
            ],
          ));

  @override
  Future<void> snooze(String id, DateTime until) => _update(
      id,
      (a) => a.copyWith(
            status: AlertStatus.snoozed,
            snoozeUntil: until,
            history: [
              ...a.history,
              AlertEvent(AlertEventType.snoozed, DateTime.now(), until: until),
            ],
          ));

  /// Mock-only: the workflow auto-resolving alerts whose lead was just
  /// covered by a filed report (§3.4). Not on the interface — wired to the
  /// reports mock in main.dart.
  void resolveForLeads(List<String> leadIds) {
    var changed = false;
    for (var i = 0; i < _alerts.length; i++) {
      final a = _alerts[i];
      if (a.status != AlertStatus.resolved && leadIds.contains(a.leadId)) {
        _alerts[i] = a.copyWith(status: AlertStatus.resolved);
        changed = true;
      }
    }
    if (changed) _changes.bump();
  }

  Future<void> _update(
      String id, LeadAlert Function(LeadAlert) transform) async {
    await Future.delayed(_latency);
    final i = _alerts.indexWhere((a) => a.id == id);
    if (i >= 0) {
      _alerts[i] = transform(_alerts[i]);
      _changes.bump();
    }
  }
}

class MockTrackingRepository implements TrackingRepository {
  @override
  Future<OfficeHours> officeHours() async {
    await Future.delayed(_latency);
    return const OfficeHours(
      start: TimeOfDay(hour: 9, minute: 0),
      end: TimeOfDay(hour: 17, minute: 30),
    );
  }

  @override
  Future<List<double>> weeklyActivity() async {
    await Future.delayed(_latency);
    // Visits-per-day over the last 7 days (oldest first; last = today).
    return const [0.4, 0.7, 0.5, 0.9, 0.6, 0.8, 0.3];
  }
}
