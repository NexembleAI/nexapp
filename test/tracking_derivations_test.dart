// Unit tests for the client-side derivations: the needs-action alert rule
// (with the client snooze-expiry re-open) and the 7-day activity bucketing.
// Both take an injected `now`, so they're deterministic and backend-free.
import 'package:flutter_test/flutter_test.dart';
import 'package:traccar_client/home_controller.dart';
import 'package:traccar_client/models/tracking_models.dart';

void main() {
  group('alertNeedsAction / effectiveAlertStatus', () {
    final now = DateTime(2026, 7, 23, 12);

    test('open and escalated need action', () {
      expect(alertNeedsAction(AlertStatus.open, null, now), isTrue);
      expect(alertNeedsAction(AlertStatus.escalated, null, now), isTrue);
    });

    test('ack and resolved do not', () {
      expect(alertNeedsAction(AlertStatus.ack, null, now), isFalse);
      expect(alertNeedsAction(AlertStatus.resolved, null, now), isFalse);
    });

    test('snoozed needs action only once snooze_until has passed', () {
      final future = now.add(const Duration(hours: 1));
      final past = now.subtract(const Duration(hours: 1));
      expect(alertNeedsAction(AlertStatus.snoozed, future, now), isFalse);
      expect(alertNeedsAction(AlertStatus.snoozed, past, now), isTrue);
      expect(alertNeedsAction(AlertStatus.snoozed, null, now), isFalse);
    });

    test('effectiveStatus: an expired snooze reads as open (backend never reopens)', () {
      expect(
          effectiveAlertStatus(
              AlertStatus.snoozed, now.subtract(const Duration(minutes: 1)), now),
          AlertStatus.open);
      expect(
          effectiveAlertStatus(
              AlertStatus.snoozed, now.add(const Duration(minutes: 1)), now),
          AlertStatus.snoozed);
    });

    test('boundary: snooze_until == now counts as expired (>= now)', () {
      expect(effectiveAlertStatus(AlertStatus.snoozed, now, now),
          AlertStatus.open);
      expect(alertNeedsAction(AlertStatus.snoozed, now, now), isTrue);
    });
  });

  group('HomeController.weeklyBuckets', () {
    final now = DateTime(2026, 7, 23, 15); // today = 07-23
    DateTime day(int d) => DateTime(2026, 7, d, 10);

    test('empty → 7 flat zeros', () {
      expect(HomeController.weeklyBuckets(const [], now), List.filled(7, 0.0));
    });

    test('buckets by local day, normalized to the rolling max, last = today', () {
      final entered = <DateTime>[
        day(23), day(23), day(23), // today: 3 (the max)
        day(22), // -1 day: 1
        day(20), day(20), // -3 days: 2
        day(17), // -6 days (oldest in window): 1
        day(16), // 7 days ago → OUTSIDE the 7-day window (dropped)
      ];
      final b = HomeController.weeklyBuckets(entered, now);
      expect(b.length, 7);
      expect(b[6], 1.0); // today (3/3)
      expect(b[5], closeTo(1 / 3, 1e-9)); // -1 (1/3)
      expect(b[4], 0.0); // -2 (empty)
      expect(b[3], closeTo(2 / 3, 1e-9)); // -3 (2/3)
      expect(b[0], closeTo(1 / 3, 1e-9)); // -6 (1/3)
    });

    test('null entered_at is ignored', () {
      expect(HomeController.weeklyBuckets([null, day(23)], now),
          [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0]);
    });
  });
}
