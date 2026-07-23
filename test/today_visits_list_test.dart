// Widget test for the Home "Today's visits" list: the per-row rendering the
// reviewer called out — "Ongoing" (open session), "No report yet" (no report),
// "Unnamed customer" (unresolved CRM name), and a dwell for a closed visit.
// Deterministic (fed a fixed VisitEntry list), no backend.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:traccar_client/l10n/app_localizations.dart';
import 'package:traccar_client/models/tracking_models.dart';
import 'package:traccar_client/reports_repository.dart';
import 'package:traccar_client/today_visits_list.dart';

/// Minimal ReportsRepository that only answers todayVisits() + changes (all the
/// widget touches); everything else throws via noSuchMethod.
class _FakeReports implements ReportsRepository {
  _FakeReports(this.visits);
  final List<VisitEntry> visits;
  final _changes = ChangeNotifier();

  @override
  Listenable get changes => _changes;

  @override
  Future<List<VisitEntry>> todayVisits() async => visits;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

Widget _wrap(Widget child) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: child),
    );

void main() {
  testWidgets('renders ongoing, no-report, unnamed-customer, and dwell', (tester) async {
    final at = DateTime(2026, 7, 23, 11, 20);
    ReportsRepository.instance = _FakeReports([
      // Open visit, no name resolved, no report yet.
      VisitEntry(
        customerName: '',
        enteredAt: at,
        dwell: Duration.zero,
        ongoing: true,
        status: null,
      ),
      // Closed visit with a report.
      VisitEntry(
        customerName: 'Meridian Logistics',
        enteredAt: at,
        dwell: const Duration(minutes: 24),
        status: ReportStatus.ready,
      ),
    ]);

    await tester.pumpWidget(_wrap(const TodayVisitsList()));
    await tester.pump(); // resolve the async _load
    await tester.pump();

    // Unresolved CRM name → fallback (also the avatar routes through it).
    expect(find.text('Unnamed customer'), findsOneWidget);
    // Open session → "Ongoing" instead of "· 0 min".
    expect(find.textContaining('Ongoing'), findsOneWidget);
    // No report filed → the muted chip.
    expect(find.text('No report yet'), findsOneWidget);
    // Closed visit: name, its report status chip, and a dwell.
    expect(find.text('Meridian Logistics'), findsOneWidget);
    expect(find.text('Ready'), findsOneWidget);
    expect(find.textContaining('24'), findsWidgets); // "… · 24 min"
  });

  testWidgets('empty → the no-visits message', (tester) async {
    ReportsRepository.instance = _FakeReports(const []);
    await tester.pumpWidget(_wrap(const TodayVisitsList()));
    await tester.pump();
    await tester.pump();
    expect(find.text('No visits yet today'), findsOneWidget);
  });
}
