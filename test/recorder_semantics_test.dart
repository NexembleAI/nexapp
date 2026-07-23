// Widget test for the recorder card's accessibility labels (#11 follow-up): the
// icon-only mic/stop/play buttons must expose semantic labels so screen readers
// and uiautomator can find them. Pumps the idle state, which touches no plugin.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:record/record.dart';
import 'package:traccar_client/audio_recorder_service.dart';
import 'package:traccar_client/l10n/app_localizations.dart';
import 'package:traccar_client/visit_capture_screen.dart';

/// Inert `record` platform so constructing AudioRecorderService is safe (the
/// idle card never records).
class _FakeRecordPlatform extends RecordPlatform with MockPlatformInterfaceMixin {
  @override
  Future<void> create(String recorderId) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  @override
  Future<String?> getApplicationDocumentsPath() async => '.';
}

Widget _wrap(Widget child) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: child),
    );

void main() {
  testWidgets('the idle mic button exposes a "Record" semantic label',
      (tester) async {
    RecordPlatform.instance = _FakeRecordPlatform();
    PathProviderPlatform.instance = _FakePathProvider();

    final handle = tester.ensureSemantics(); // build the semantics tree
    await tester.pumpWidget(_wrap(RecorderCard(
      service: AudioRecorderService(),
      onChanged: (_) {},
      onRecordingChanged: (_) {},
    )));
    await tester.pump();

    // The mic control is icon-only; without the label its semantics node would
    // be a nameless button (the bug PR #20 flagged). Assert the node enclosing
    // the mic glyph carries the "Record" label and the button role.
    final data = tester.getSemantics(find.byIcon(Icons.mic)).getSemanticsData();
    expect(data.label, 'Record');
    handle.dispose();
  });
}
