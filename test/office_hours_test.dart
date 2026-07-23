// Unit tests for OfficeHours.tryFromDeviceJson — the today's-window parse of a
// device's office_hours schedule (3-state: null / closedToday / a window; tz
// ignored; multi-window collapse). `now` is injected for determinism.
import 'dart:convert';

import 'package:flutter/material.dart' show TimeOfDay;
import 'package:flutter_test/flutter_test.dart';
import 'package:traccar_client/models/tracking_models.dart';

void main() {
  const keys = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
  // Arbitrary fixed instant; keys are derived from its weekday, so the tests
  // don't depend on which day it actually is.
  final now = DateTime(2026, 3, 18, 12);
  final todayKey = keys[now.weekday - 1];
  final tomorrowKey = keys[now.weekday % 7];

  String sched(Map<String, dynamic> weekly, {String tz = 'Asia/Kolkata'}) =>
      jsonEncode({'tz': tz, 'weekly_schedule': weekly});

  group('OfficeHours.tryFromDeviceJson', () {
    test('no schedule → null (caller substitutes the default)', () {
      expect(OfficeHours.tryFromDeviceJson(null, now: now), isNull);
      expect(OfficeHours.tryFromDeviceJson('', now: now), isNull);
      expect(OfficeHours.tryFromDeviceJson('{}', now: now), isNull);
      expect(OfficeHours.tryFromDeviceJson('not json', now: now), isNull);
      expect(OfficeHours.tryFromDeviceJson(sched(const {}), now: now), isNull);
    });

    test("today's window", () {
      final oh = OfficeHours.tryFromDeviceJson(
          sched({todayKey: [['10:00', '19:00']]}), now: now);
      expect(oh, isNotNull);
      expect(oh!.closed, isFalse);
      expect(oh.start, const TimeOfDay(hour: 10, minute: 0));
      expect(oh.end, const TimeOfDay(hour: 19, minute: 0));
    });

    test('multi-window day collapses to earliest start / latest end', () {
      final oh = OfficeHours.tryFromDeviceJson(
          sched({todayKey: [['09:00', '13:00'], ['14:00', '18:00']]}),
          now: now)!;
      expect(oh.start, const TimeOfDay(hour: 9, minute: 0));
      expect(oh.end, const TimeOfDay(hour: 18, minute: 0));
    });

    test('today empty [] → closedToday (a configured non-working day)', () {
      final oh = OfficeHours.tryFromDeviceJson(
          sched({todayKey: const [], tomorrowKey: [['10:00', '18:00']]}),
          now: now)!;
      expect(oh.closed, isTrue);
    });

    test('today unlisted (schedule exists) → closedToday', () {
      final oh = OfficeHours.tryFromDeviceJson(
          sched({tomorrowKey: [['10:00', '18:00']]}), now: now)!;
      expect(oh.closed, isTrue);
    });

    test('per-day: same JSON, different window on a different day', () {
      final j = sched({
        todayKey: [['10:00', '19:00']],
        tomorrowKey: [['09:00', '16:00']],
      });
      final tomorrow = now.add(const Duration(days: 1));
      expect(OfficeHours.tryFromDeviceJson(j, now: now)!.end,
          const TimeOfDay(hour: 19, minute: 0));
      expect(OfficeHours.tryFromDeviceJson(j, now: tomorrow)!.end,
          const TimeOfDay(hour: 16, minute: 0));
    });

    test('timezone is ignored — HH:MM shown as device-local wall clock', () {
      final oh = OfficeHours.tryFromDeviceJson(
          sched({todayKey: [['10:00', '19:00']]}, tz: 'America/Los_Angeles'),
          now: now)!;
      expect(oh.start, const TimeOfDay(hour: 10, minute: 0)); // not converted
    });
  });
}
