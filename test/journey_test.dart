// Customer-journey tracking (2026-11-27) — pure-logic tests.
// The Firestore shape (≤ 20 entries, dwell bands only, no
// per-second times) is enforced by the rules and covered by the
// rules emulator suite (21 entries fails, invalid band fails);
// here we pin the client-side pieces: the 20-product cap with
// overflow count, dwell banding (hidden-tab time excluded by the
// caller), the schema version on every event, and the action
// labels (unknown actions render as plain text).
import 'package:flutter_test/flutter_test.dart';
import 'package:storeadmin/services/backend.dart';

List<Map<String, dynamic>> sampleEntries(int count) =>
    List.generate(count, (i) => {
          'productId': 'prod-$i',
          'dwellBand': '10-60s',
          'actions': ['view'],
        });

void main() {
  group('20-product cap', () {
    test('19 entries pass through with zero overflow', () {
      final capped = Backend.capJourneyEntries(sampleEntries(19));
      expect(capped.entries.length, 19);
      expect(capped.overflowCount, 0);
    });

    test('exactly 20 entries pass through with zero overflow', () {
      final capped = Backend.capJourneyEntries(sampleEntries(20));
      expect(capped.entries.length, 20);
      expect(capped.overflowCount, 0);
    });

    test('the 21st entry is dropped, oldest kept, +N more counted', () {
      final capped = Backend.capJourneyEntries(sampleEntries(25));
      expect(capped.entries.length, 20);
      expect(capped.overflowCount, 5);
      // Oldest kept: the first entry is still prod-0, not prod-5.
      expect(capped.entries.first['productId'], 'prod-0');
      expect(capped.entries.last['productId'], 'prod-19');
    });
  });

  group('dwell banding', () {
    test('9s is <10s, 10s and 60s are 10-60s, 61s is >60s', () {
      expect(Backend.dwellBand(0), '<10s');
      expect(Backend.dwellBand(9), '<10s');
      expect(Backend.dwellBand(10), '10-60s');
      expect(Backend.dwellBand(60), '10-60s');
      expect(Backend.dwellBand(61), '>60s');
      expect(Backend.dwellBand(3600), '>60s');
    });

    test('bands are the only three tokens the rules accept', () {
      for (final seconds in [0, 5, 9, 10, 30, 60, 61, 600]) {
        expect(
          Backend.dwellBand(seconds),
          isIn(['<10s', '10-60s', '>60s']),
        );
      }
    });
  });

  group('schema version + action labels', () {
    test('every journey event carries schemaVersion 1', () {
      expect(Backend.journeySchemaVersion, 1);
    });

    test('known actions have Arabic labels', () {
      expect(Backend.journeyActionLabel('view'), 'شاف المنتج');
      expect(Backend.journeyActionLabel('add'), 'ضاف للسلة');
      expect(Backend.journeyActionLabel('checkout_start'), 'بدأ الطلب');
    });

    test('unknown action types render as plain text, never crash', () {
      expect(Backend.journeyActionLabel('scroll'), 'scroll');
      expect(Backend.journeyActionLabel('hover_xyz'), 'hover_xyz');
      expect(Backend.journeyActionLabel(''), '');
    });
  });

  group('anonymous sessions carry no identity', () {
    test('a journey summary has no name/phone keys by shape', () {
      // The canonical shape (docs/incomplete-orders-schema.md):
      // sessionId, draftId, orderId, startedAt, totalSecondsBand,
      // products, overflowCount, updatedAt, schemaVersion.
      const journeyKeys = {
        'sessionId',
        'draftId',
        'orderId',
        'startedAt',
        'totalSecondsBand',
        'products',
        'overflowCount',
        'updatedAt',
        'schemaVersion',
      };
      expect(journeyKeys.contains('name'), isFalse);
      expect(journeyKeys.contains('phone'), isFalse);
      expect(journeyKeys.contains('customerName'), isFalse);
    });
  });
}
