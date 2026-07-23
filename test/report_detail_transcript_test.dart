import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:traccar_client/audio_player_bar.dart';
import 'package:traccar_client/l10n/app_localizations.dart';
import 'package:traccar_client/models/tracking_models.dart';
import 'package:traccar_client/report_detail_screen.dart';
import 'package:traccar_client/reports_repository.dart';

/// Minimal in-memory repo so ReportDetailScreen can be pumped without a backend.
/// (A no-audio report renders no AudioPlayerBar, so no just_audio platform
/// channel is touched.)
class _FakeRepo extends ChangeNotifier implements ReportsRepository {
  _FakeRepo(this._detail);
  final ReportDetail _detail;

  @override
  Listenable get changes => this;
  @override
  Future<ReportDetail> reportDetail(String id) async => _detail;
  @override
  Future<ReportStatusUpdate> reportStatus(String id) async =>
      ReportStatusUpdate(status: _detail.status, transcript: _detail.transcript);
  @override
  Future<String?> reportAudio(String id) async => null;
  @override
  Future<void> updateReport(String id,
      {required String notes, required List<String> leadIds}) async {}
  @override
  Future<List<ReportEntry>> reports() async => const [];
  @override
  Future<TodayStats> todayStats() async => const TodayStats(visits: 0, reports: 0);
  @override
  Future<List<VisitEntry>> todayVisits() async => const [];
}

ReportDetail _detail({required bool audioPresent, String? transcript}) =>
    ReportDetail(
      id: 'r1',
      customerId: 'c1',
      customerName: 'Acme',
      createdAt: DateTime(2026, 7, 23, 12, 0),
      status: ReportStatus.submitted,
      geofencePresent: false,
      transcript: transcript,
      notes: 'text-only note',
      audioPresent: audioPresent,
      leadIds: const [],
      version: 1,
    );

Future<void> _pump(WidgetTester tester, ReportDetail d) async {
  ReportsRepository.instance = _FakeRepo(d);
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: const ReportDetailScreen(reportId: 'r1'),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'a text-only (no-audio) report says "No audio recorded", never "pending"',
      (tester) async {
    await _pump(tester, _detail(audioPresent: false));

    // The fix: a report with nothing to transcribe must not claim a transcript
    // is on the way — "pending" there never resolves and misleads the user.
    expect(find.text('No audio recorded'), findsOneWidget);
    expect(find.text('Transcript pending…'), findsNothing);
    // And no audio player is shown for a report without audio.
    expect(find.byType(AudioPlayerBar), findsNothing);
  });
}
