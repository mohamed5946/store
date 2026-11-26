// No-functions backend tests (contract §1/§2/§5/§6/§9, 2026-11-26).
// Pure logic only — no Firestore, no emulator, no callables: the
// callable paths are gone, the manual order is a client transaction,
// feedback is a one-way direct write, and the sweep expiry is pure
// date math. The transaction bodies themselves call these helpers,
// so the tested shapes are the shipped shapes.
import 'package:flutter_test/flutter_test.dart';
import 'package:storeadmin/core/dashboard_stats.dart';
import 'package:storeadmin/services/backend.dart';

void main() {
  group('manual order input (contract §1 step 3)', () {
    const validItems = [
      {'productId': 'p1', 'qty': 2},
      {'productId': 'p2', 'qty': 1},
    ];

    String? validate({
      String name = 'أحمد',
      String phone = '01012345678',
      String address = 'القاهرة',
      List<Map<String, dynamic>> items = validItems,
    }) =>
        Backend.validateManualOrderInput(
          customerName: name,
          customerPhone: phone,
          customerAddress: address,
          items: items,
        );

    test('a valid manual order passes', () {
      expect(validate(), isNull);
    });

    test('empty name / address fail', () {
      expect(validate(name: '  '), isNotNull);
      expect(validate(address: ''), isNotNull);
    });

    test('phone needs at least 10 digits', () {
      expect(validate(phone: '010123'), isNotNull);
      expect(validate(phone: '+20 101 234 5678'), isNull);
      expect(validate(phone: '010-123-4567'), isNull);
    });

    test('no items fails', () {
      expect(validate(items: []), isNotNull);
    });

    test('qty must be 1..20 per line', () {
      expect(validate(items: [
        {'productId': 'p1', 'qty': 0}
      ]), isNotNull);
      expect(validate(items: [
        {'productId': 'p1', 'qty': 21}
      ]), isNotNull);
      expect(validate(items: [
        {'productId': 'p1', 'qty': 20}
      ]), isNull);
    });

    test('more than 7 distinct products fails', () {
      final items = List.generate(
          8, (i) => {'productId': 'p$i', 'qty': 1});
      expect(validate(items: items), isNotNull);
    });

    test('7 distinct products passes', () {
      final items = List.generate(
          7, (i) => {'productId': 'p$i', 'qty': 1});
      expect(validate(items: items), isNull);
    });

    test('duplicate lines are deduped before the distinct count', () {
      // 11 lines but only 2 distinct products — valid.
      final items = [
        for (var i = 0; i < 10; i++) {'productId': 'p1', 'qty': 1},
        {'productId': 'p2', 'qty': 1},
      ];
      expect(validate(items: items), isNull);
    });
  });

  group('dedupeManualItems', () {
    test('merges duplicate productIds, summing quantities', () {
      final out = Backend.dedupeManualItems([
        {'productId': 'p1', 'qty': 2},
        {'productId': 'p2', 'qty': 1},
        {'productId': 'p1', 'qty': 3},
      ]);
      expect(out, [
        {'productId': 'p1', 'qty': 5},
        {'productId': 'p2', 'qty': 1},
      ]);
    });

    test('drops lines with an empty productId', () {
      final out = Backend.dedupeManualItems([
        {'productId': '', 'qty': 2},
        {'productId': 'p1', 'qty': 1},
      ]);
      expect(out, [
        {'productId': 'p1', 'qty': 1}
      ]);
    });
  });

  group('computeOrderTotals (contract §1 step 4)', () {
    test('totals come from database prices, no discount', () {
      final t = Backend.computeOrderTotals([
        {'price': 100, 'qty': 2},
        {'price': 50, 'qty': 1},
      ], null);
      expect(t.subtotal, 250);
      expect(t.discountPercent, isNull);
      expect(t.discountAmount, 0);
      expect(t.total, 250);
    });

    test('discount rounds to the nearest pound', () {
      // 333 * 10% = 33.3 -> 33.
      final t = Backend.computeOrderTotals([
        {'price': 333, 'qty': 1},
      ], 10);
      expect(t.subtotal, 333);
      expect(t.discountAmount, 33);
      expect(t.total, 300);
    });

    test('100% discount zeroes the total', () {
      final t = Backend.computeOrderTotals([
        {'price': 100, 'qty': 1},
      ], 100);
      expect(t.discountAmount, 100);
      expect(t.total, 0);
    });
  });

  group('wholeNum (rules require price is int)', () {
    test('whole doubles become ints', () {
      expect(Backend.wholeNum(100.0), 100);
      expect(Backend.wholeNum(100.0), isA<int>());
    });

    test('fractional values and ints pass through', () {
      expect(Backend.wholeNum(99.5), 99.5);
      expect(Backend.wholeNum(100), 100);
    });
  });

  group('one-way feedback (contract §6)', () {
    String? validate({
      String name = 'أحمد',
      String email = 'a@example.com',
      String phone = '01012345678',
      String message = 'المنتج وصل متأخر جداً',
    }) =>
        Backend.validateFeedbackInput(
          name: name,
          email: email,
          phone: phone,
          message: message,
        );

    test('a valid complaint passes', () {
      expect(validate(), isNull);
    });

    test('message must be 10..2000 chars', () {
      expect(validate(message: 'قصير'), isNotNull);
      expect(validate(message: 'x' * 9), isNotNull);
      expect(validate(message: 'x' * 10), isNull);
      expect(validate(message: 'x' * 2001), isNotNull);
    });

    test('email must contain @ and be at most 100 chars', () {
      expect(validate(email: 'not-an-email'), isNotNull);
      expect(validate(email: '${'x' * 95}@e.com'), isNotNull);
    });

    test('email is optional (phone is the required contact)', () {
      expect(validate(email: ''), isNull);
      expect(validate(email: '   '), isNull);
    });

    test('name at most 100 chars', () {
      expect(validate(name: 'x' * 101), isNotNull);
    });

    test('phone must be 10..15 digits (non-digits are stripped)', () {
      expect(validate(phone: '010123456'), isNotNull); // 9 digits
      expect(validate(phone: 'abcdefghij'), isNotNull); // no digits
      expect(validate(phone: '1' * 16), isNotNull); // 16 digits
      expect(validate(phone: '0101234567'), isNull); // 10 digits
      expect(validate(phone: '01012345678'), isNull); // 11 digits
      expect(validate(phone: '1' * 15), isNull); // 15 digits
      expect(validate(phone: '0101 234-5678'), isNull); // spaces/dashes stripped
    });
  });

  group('lazy sweep expiry (contract §5)', () {
    test('a fresh order is not expired', () {
      final now = DateTime(2026, 11, 26, 13, 0);
      expect(
        Backend.isReservationExpired(
          createdAt: now.subtract(const Duration(hours: 1)),
          now: now,
        ),
        isFalse,
      );
    });

    test('an order older than 24h is expired', () {
      final now = DateTime(2026, 11, 26, 13, 0);
      expect(
        Backend.isReservationExpired(
          createdAt: now.subtract(const Duration(hours: 25)),
          now: now,
        ),
        isTrue,
      );
    });

    test('exactly 24h old is expired (boundary inclusive)', () {
      final now = DateTime(2026, 11, 26, 13, 0);
      expect(
        Backend.isReservationExpired(
          createdAt: now.subtract(const Duration(hours: 24)),
          now: now,
        ),
        isTrue,
      );
    });

    test('a missing createdAt never expires', () {
      expect(
        Backend.isReservationExpired(
          createdAt: null,
          now: DateTime(2026, 11, 26),
        ),
        isFalse,
      );
    });

    test('the TTL is 24 hours', () {
      expect(Backend.reservationTtl, const Duration(hours: 24));
    });
  });

  group('WhatsApp settings (contract §7/§9)', () {
    test('defaults are off + 201557887719', () {
      final parsed = Backend.parseWhatsAppSettings(null);
      expect(parsed.enabled, isFalse);
      expect(parsed.number, '201557887719');
      expect(Backend.defaultWhatsAppNumber, '201557887719');
    });

    test('an empty number falls back to the default', () {
      final parsed = Backend.parseWhatsAppSettings({
        'whatsappOrderEnabled': true,
        'whatsappNumber': '  ',
      });
      expect(parsed.enabled, isTrue);
      expect(parsed.number, '201557887719');
    });

    test('a saved number is kept verbatim (trimmed)', () {
      final parsed = Backend.parseWhatsAppSettings({
        'whatsappOrderEnabled': true,
        'whatsappNumber': ' 201001234567 ',
      });
      expect(parsed.enabled, isTrue);
      expect(parsed.number, '201001234567');
    });
  });

  group('low-stock flags (contract §8/§9)', () {
    test('flags stock - reserved <= minStock', () {
      final low = lowStockProducts(
        products: [
          {'id': 'p1', 'name': 'A'},
          {'id': 'p2', 'name': 'B'},
          {'id': 'p3', 'name': 'C'},
        ],
        inventory: {
          'p1': {'stock': 10, 'reserved': 5, 'minStock': 5},
          'p2': {'stock': 10, 'reserved': 2, 'minStock': 5},
          'p3': {'stock': 3, 'reserved': 0, 'minStock': 5},
        },
      );
      expect(low.map((p) => p['id']), ['p1', 'p3']);
      expect(low.first['available'], 5);
      expect(low.first['minStock'], 5);
    });

    test('minStock defaults to 5 when the inventory doc lacks it', () {
      final low = lowStockProducts(
        products: [
          {'id': 'p1', 'name': 'A'},
          {'id': 'p2', 'name': 'B'},
        ],
        inventory: {
          'p1': {'stock': 6, 'reserved': 0},
          'p2': {'stock': 5, 'reserved': 0},
        },
      );
      expect(low.map((p) => p['id']), ['p2']);
    });

    test('products with no inventory doc are skipped, not flagged', () {
      final low = lowStockProducts(
        products: [
          {'id': 'p1', 'name': 'A'},
        ],
        inventory: {},
      );
      expect(low, isEmpty);
    });
  });
}
