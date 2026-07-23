// Unit tests for the uploader's retry backoff — exponential growth, the
// [_maxBackoff] cap, and the equal-jitter band ([base/2, base]) that
// decorrelates a fleet of clients after a shared outage.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:traccar_client/upload_uploader.dart';

void main() {
  // Base (un-jittered) delay for an attempt: 2^(attempt-1), capped at 300s.
  int baseSeconds(int attempt) => min(1 << (attempt - 1), 300);

  group('UploadUploader.backoff', () {
    test('every delay lands in the equal-jitter band [base/2, base]', () {
      final rng = Random(1); // seeded → deterministic across runs
      const maxAttempts = 11; // UploadQueue.maxAttempts
      for (var attempt = 1; attempt <= maxAttempts; attempt++) {
        final base = baseSeconds(attempt);
        for (var i = 0; i < 200; i++) {
          final ms = UploadUploader.backoff(attempt, rng: rng).inMilliseconds;
          expect(ms, greaterThanOrEqualTo((base * 1000) ~/ 2),
              reason: 'attempt $attempt below base/2');
          expect(ms, lessThanOrEqualTo(base * 1000),
              reason: 'attempt $attempt above base');
        }
      }
    });

    test('base doubles each attempt until the 300s cap', () {
      expect(baseSeconds(1), 1);
      expect(baseSeconds(9), 256);
      expect(baseSeconds(10), 300); // 512 capped
      expect(baseSeconds(11), 300);
      // Lower bound (base/2) grows accordingly: attempt 1 ≥ 0.5s, attempt 9 ≥ 128s.
      final rng = Random(7);
      expect(UploadUploader.backoff(1, rng: rng).inMilliseconds,
          greaterThanOrEqualTo(500));
      expect(UploadUploader.backoff(9, rng: rng).inMilliseconds,
          greaterThanOrEqualTo(128000));
    });

    test('the cap holds — no delay exceeds _maxBackoff (300s)', () {
      final rng = Random(3);
      for (var i = 0; i < 500; i++) {
        expect(UploadUploader.backoff(20, rng: rng).inMilliseconds,
            lessThanOrEqualTo(300000));
      }
    });

    test('jitter actually spreads — samples for one attempt are not all equal', () {
      final rng = Random(99);
      final samples = {
        for (var i = 0; i < 50; i++)
          UploadUploader.backoff(6, rng: rng).inMilliseconds,
      };
      expect(samples.length, greaterThan(1),
          reason: 'a fixed attempt should yield varied (jittered) delays');
    });
  });
}
