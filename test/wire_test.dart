// Unit tests for the grpc-gateway JSON reader conventions (proto3 zero-omission,
// int64-as-string, RFC-3339 timestamps, camel/snake key hedge). Pure — no
// backend, no widgets.
import 'package:flutter_test/flutter_test.dart';
import 'package:traccar_client/tracking_dto.dart';

void main() {
  group('Wire', () {
    test('string: present, camelCase fallback, absent → ""', () {
      expect(Wire.string({'customer_id': 'C1'}, 'customer_id'), 'C1');
      // Gateway may emit camelCase; the reader hedges both.
      expect(Wire.string({'customerId': 'C2'}, 'customer_id'), 'C2');
      // proto3 omits a zero-value field entirely → default, never a throw.
      expect(Wire.string(const {}, 'customer_id'), '');
    });

    test('integer: num, int64-as-string, double, absent → 0, garbage → 0', () {
      expect(Wire.integer({'n': 5}, 'n'), 5);
      // int64/uint64 arrive as strings over the wire.
      expect(Wire.integer({'n': '9007199254740993'}, 'n'), 9007199254740993);
      expect(Wire.integer({'n': 3.0}, 'n'), 3);
      expect(Wire.integer(const {}, 'n'), 0);
      expect(Wire.integer({'n': 'nope'}, 'n'), 0);
    });

    test('boolean: present, absent → false', () {
      expect(Wire.boolean({'b': true}, 'b'), isTrue);
      expect(Wire.boolean(const {}, 'b'), isFalse);
    });

    test('timestamp: RFC-3339 → local DateTime, absent/empty → null', () {
      final t = Wire.timestamp({'at': '2026-07-22T08:30:00Z'}, 'at');
      expect(t, isNotNull);
      expect(t!.toUtc(), DateTime.utc(2026, 7, 22, 8, 30));
      expect(t.isUtc, isFalse); // converted to local
      expect(Wire.timestamp(const {}, 'at'), isNull);
      expect(Wire.timestamp({'at': ''}, 'at'), isNull);
    });

    test('stringList: list, stringified elements, absent → []', () {
      expect(Wire.stringList({'ids': ['a', 'b']}, 'ids'), ['a', 'b']);
      expect(Wire.stringList({'ids': [1, 2]}, 'ids'), ['1', '2']);
      expect(Wire.stringList(const {}, 'ids'), isEmpty);
    });
  });
}
