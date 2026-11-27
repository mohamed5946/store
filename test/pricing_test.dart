// Pricing tests (pricing-bundle.md, Technical Plan §8 + Verification
// Plan matrix cases A–G). Pure logic only — no Firestore, no emulator:
// the shared numeric matrix is the test oracle. A path passes only
// when it reproduces every row of the matrix exactly, with identical
// expected totals on the storefront, Flutter, and PC paths.
import 'package:flutter_test/flutter_test.dart';
import 'package:storeadmin/services/backend.dart';

void main() {
  // One line: base price -> effective (charged) price x qty.
  Map<String, dynamic> line(int? base, int price, int qty) => {
        'basePrice': base,
        'price': price,
        'qty': qty,
      };

  group('shared numeric matrix (Verification Plan cases A–G)', () {
    test('A — worked example: 500 → 300 x1, no code, fee 30', () {
      final t = Backend.computeOrderTotals(
        [line(500, 300, 1)],
        null,
        deliveryFee: 30,
      );
      expect(t.baseSubtotal, 500);
      expect(t.subtotal, 300);
      expect(t.saleSavings, 200);
      expect(t.discountAmount, 0);
      expect(t.total, 300);
      expect(t.deliveryFee, 30);
      expect(t.amountDue, 330);
    });

    test('B — fee 0: amountDue == items total', () {
      final t = Backend.computeOrderTotals(
        [line(500, 300, 1)],
        null,
        deliveryFee: 0,
      );
      expect(t.baseSubtotal, 500);
      expect(t.subtotal, 300);
      expect(t.saleSavings, 200);
      expect(t.discountAmount, 0);
      expect(t.total, 300);
      expect(t.deliveryFee, 0);
      expect(t.amountDue, 300);
    });

    test('C — code on sale: 10% on the post-sale subtotal', () {
      final t = Backend.computeOrderTotals(
        [line(500, 300, 1)],
        10,
        deliveryFee: 30,
      );
      expect(t.baseSubtotal, 500);
      expect(t.subtotal, 300);
      expect(t.saleSavings, 200);
      expect(t.discountAmount, 30);
      expect(t.total, 270);
      expect(t.deliveryFee, 30);
      expect(t.amountDue, 300);
    });

    test('D — multi-line: 500 → 300 x2 + 150 → 150 x1', () {
      final t = Backend.computeOrderTotals(
        [line(500, 300, 2), line(null, 150, 1)],
        null,
        deliveryFee: 30,
      );
      expect(t.baseSubtotal, 1150);
      expect(t.subtotal, 750);
      expect(t.saleSavings, 400);
      expect(t.discountAmount, 0);
      expect(t.total, 750);
      expect(t.deliveryFee, 30);
      expect(t.amountDue, 780);
    });

    test('E — rounding, % display: 199 → 149 saves exactly 50', () {
      final t = Backend.computeOrderTotals(
        [line(199, 149, 1)],
        null,
        deliveryFee: 30,
      );
      expect(t.baseSubtotal, 199);
      expect(t.subtotal, 149);
      expect(t.saleSavings, 50);
      expect(t.discountAmount, 0);
      expect(t.total, 149);
      expect(t.deliveryFee, 30);
      expect(t.amountDue, 179);
      // Per-line breakdown (storefront `perLine`): the saving is
      // exact, and the % badge is suppressed for this line (§8).
      expect(t.perLine.length, 1);
      expect(t.perLine[0].saving, 50);
      expect(t.perLine[0].pct, isNull);
      expect(t.savingTotal, 50);
      expect(t.insteadOf, 229);
    });

    test('F — rounding, code: round(149 x 10 / 100) = round(14.9) = 15',
        () {
      final t = Backend.computeOrderTotals(
        [line(199, 149, 1)],
        10,
        deliveryFee: 30,
      );
      expect(t.baseSubtotal, 199);
      expect(t.subtotal, 149);
      expect(t.saleSavings, 50);
      expect(t.discountAmount, 15);
      expect(t.total, 134);
      expect(t.deliveryFee, 30);
      expect(t.amountDue, 164);
    });

    test('G — code halves-up: round(305 x 10 / 100) = round(30.5) = 31',
        () {
      final t = Backend.computeOrderTotals(
        [line(null, 305, 1)],
        10,
        deliveryFee: 30,
      );
      expect(t.baseSubtotal, 305);
      expect(t.subtotal, 305);
      expect(t.saleSavings, 0);
      expect(t.discountAmount, 31);
      expect(t.total, 274);
      expect(t.deliveryFee, 30);
      expect(t.amountDue, 304);
    });
  });

  group('rounding edge cases (§8)', () {
    test('base 199 → 149 saves exactly 50; the % badge is SUPPRESSED',
        () {
      // §8 (normative, with this exact example): the computed % is
      // 25, but 25% × 199 = 49.75 ≠ 50, so the badge is suppressed
      // and only "وفّر 50" is shown. The matrix note saying case E
      // "displays 25%" is wrong — §8 governs.
      expect(
        Backend.salePercent(basePrice: 199, price: 149),
        isNull,
      );
      expect(
        Backend.lineSaleSaving(basePrice: 199, price: 149, qty: 1),
        50,
      );
    });

    test('% badge shows only when the rounded % reproduces the saving',
        () {
      // 40% × 500 = 200 exactly: the badge is exact, show it.
      expect(
        Backend.salePercent(basePrice: 500, price: 300),
        40,
      );
      // 10% × 100 = 10 exactly: shown.
      expect(
        Backend.salePercent(basePrice: 100, price: 90),
        10,
      );
      // 25% × 200 = 50 exactly: shown.
      expect(
        Backend.salePercent(basePrice: 200, price: 150),
        25,
      );
      // No sale (equal or null base): no badge.
      expect(
        Backend.salePercent(basePrice: 300, price: 300),
        isNull,
      );
    });

    test('per-line saving exactness: no rounding drift when summed', () {
      // Three lines, each saving an odd amount: the summed saving
      // must equal the sum of the exact per-line savings.
      final lines = [
        line(199, 149, 2),
        line(500, 300, 1),
        line(99, 89, 3),
      ];
      final t = Backend.computeOrderTotals(lines, null, deliveryFee: 30);
      final perLine = lines
          .map((l) => Backend.lineSaleSaving(
                basePrice: l['basePrice'] as int?,
                price: l['price'] as int,
                qty: l['qty'] as int,
              ))
          .fold<num>(0, (a, b) => a + b);
      expect(t.saleSavings, perLine);
      expect(t.saleSavings, 100 + 200 + 30);
      expect(t.baseSubtotal - t.subtotal, t.saleSavings);
    });

    test('code discount rounding is halves-up, identically for % and code',
        () {
      // round(30.5) = 31, round(14.9) = 15, round(49.75) = 50.
      final halfUp = Backend.computeOrderTotals(
        [line(null, 305, 1)],
        10,
        deliveryFee: 0,
      );
      expect(halfUp.discountAmount, 31);
      // A 0.5% saving rounds up to 1% — but 1% × 200 = 2 ≠ 1, so
      // the badge is still suppressed (§8 exactness rule).
      expect(
        Backend.salePercent(basePrice: 200, price: 199),
        isNull,
      );
      // A 1.5% saving rounds up to 2% — 2% × 200 = 4 ≠ 3, suppressed.
      expect(
        Backend.salePercent(basePrice: 200, price: 197),
        isNull,
      );
    });

    test('displayed saving equals charged saving exactly, no ±1 tolerance',
        () {
      final t = Backend.computeOrderTotals(
        [line(199, 149, 1)],
        10,
        deliveryFee: 30,
      );
      // Charged: sale 50 + code 15 = 65; baseSubtotal + fee 229
      // minus amountDue 164 = 65. No tolerance anywhere.
      expect(t.saleSavings + t.discountAmount, 65);
      expect(t.baseSubtotal + 30 - t.amountDue!, 65);
    });
  });

  group('fee cases (§2/§5, decision D3)', () {
    test('fee-0 case: amountDue == items total', () {
      final t = Backend.computeOrderTotals(
        [line(500, 300, 1)],
        null,
        deliveryFee: 0,
      );
      expect(t.amountDue, t.total);
      expect(t.amountDue, 300);
    });

    test('missing-fee state: fee and amountDue are null, caller blocks',
        () {
      final t = Backend.computeOrderTotals([line(500, 300, 1)], null);
      expect(t.deliveryFee, isNull);
      expect(t.feeUnset, isTrue);
      expect(t.feeWaived, isFalse);
      // amountDue without a fee is NOT a payable figure — null,
      // exactly like the storefront helper — and the manual-order
      // path throws before relying on it.
      expect(t.amountDue, isNull);
      expect(t.insteadOf, isNull);
    });

    test('free-delivery threshold waives the fee at the threshold', () {
      // total 300 reaches a threshold of 300: fee 0 stored.
      final waived = Backend.computeOrderTotals(
        [line(500, 300, 1)],
        null,
        deliveryFee: 30,
        freeDeliveryThreshold: 300,
      );
      expect(waived.deliveryFee, 0);
      expect(waived.amountDue, 300);
      // total 270 (after a code) is below the threshold: fee stands.
      final kept = Backend.computeOrderTotals(
        [line(500, 300, 1)],
        10,
        deliveryFee: 30,
        freeDeliveryThreshold: 300,
      );
      expect(kept.deliveryFee, 30);
      expect(kept.amountDue, 300);
      // No threshold set: the fee always applies.
      final noThreshold = Backend.computeOrderTotals(
        [line(500, 300, 1)],
        null,
        deliveryFee: 30,
      );
      expect(noThreshold.deliveryFee, 30);
      expect(noThreshold.feeWaived, isFalse);
      // Threshold 0 means no waiver (like absent/null).
      final zeroThreshold = Backend.computeOrderTotals(
        [line(500, 300, 1)],
        null,
        deliveryFee: 30,
        freeDeliveryThreshold: 0,
      );
      expect(zeroThreshold.deliveryFee, 30);
      expect(zeroThreshold.feeWaived, isFalse);
      // Waived case reports feeWaived and stores fee 0.
      expect(waived.feeWaived, isTrue);
      expect(waived.feeUnset, isFalse);
    });
  });

  group('product-form validation (§9)', () {
    test('basePrice == null || basePrice >= price, both positive', () {
      expect(
        Backend.validateProductPrices(price: 300, basePrice: 500),
        isNull,
      );
      expect(
        Backend.validateProductPrices(price: 300),
        isNull,
      );
      expect(
        Backend.validateProductPrices(price: 300, basePrice: 200),
        isNotNull,
      );
      expect(
        Backend.validateProductPrices(price: 0, basePrice: 500),
        isNotNull,
      );
      expect(
        Backend.validateProductPrices(price: 300, basePrice: 0),
        isNotNull,
      );
    });

    test('basePrice == price means NO sale (never a 0% badge)', () {
      expect(
        Backend.isOnSale(basePrice: 300, price: 300),
        isFalse,
      );
      expect(
        Backend.salePercent(basePrice: 300, price: 300),
        isNull,
      );
      expect(
        Backend.isOnSale(basePrice: 500, price: 300),
        isTrue,
      );
      expect(
        Backend.isOnSale(basePrice: null, price: 300),
        isFalse,
      );
    });
  });

  group('discountSetAt staleness signal (B5)', () {
    test('set on first discounted save, kept on re-save, cleared on remove',
        () {
      final first = DateTime(2026, 11, 20);
      expect(
        Backend.resolveDiscountSetAt(existing: null, hasDiscount: true),
        DiscountSetAtAction.setNow,
      );
      expect(
        Backend.resolveDiscountSetAt(existing: first, hasDiscount: true),
        DiscountSetAtAction.keep,
      );
      expect(
        Backend.resolveDiscountSetAt(existing: first, hasDiscount: false),
        DiscountSetAtAction.clear,
      );
      expect(
        Backend.resolveDiscountSetAt(existing: null, hasDiscount: false),
        DiscountSetAtAction.clear,
      );
    });

    test('staleness is whole days since discountSetAt', () {
      final setAt = DateTime(2026, 11, 20, 10, 0);
      final now = DateTime(2026, 11, 27, 10, 0);
      expect(Backend.discountAgeDays(setAt, now: now), 7);
      expect(Backend.discountAgeDays(null, now: now), isNull);
      // Part-days do not round up: 23 hours is 0 whole days.
      expect(
        Backend.discountAgeDays(setAt, now: DateTime(2026, 11, 21, 9, 0)),
        0,
      );
    });
  });

  group('delivery-fee settings parsing (§2/D3)', () {
    test('explicit 0 is set; missing is unset, never 0', () {
      final zero = Backend.parseDeliveryFeeSettings({'deliveryFee': 0});
      expect(zero.deliveryFee, 0);
      final missing = Backend.parseDeliveryFeeSettings({});
      expect(missing.deliveryFee, isNull);
      final set = Backend.parseDeliveryFeeSettings({
        'deliveryFee': 30,
        'freeDeliveryThreshold': 500,
      });
      expect(set.deliveryFee, 30);
      expect(set.freeDeliveryThreshold, 500);
      final noThreshold =
          Backend.parseDeliveryFeeSettings({'deliveryFee': 30});
      expect(noThreshold.freeDeliveryThreshold, isNull);
    });
  });

  group('invoice lines (CUJ 7 — same lines as the PC invoice)', () {
    // Worked example (matrix A): base 500 → 300, no code, fee 30.
    Map<String, dynamic> orderA() => {
          'total': 300,
          'saleSavings': 200,
          'discountAmount': 0,
          'deliveryFee': 30,
          'amountDue': 330,
          'items': [
            {'name': 'سماعة', 'price': 300, 'qty': 1, 'basePrice': 500},
          ],
        };

    test('sale + fee: two savings slots, fee line, amount due', () {
      expect(Backend.invoiceMoneyLines(orderA()), [
        'الإجمالي: 300 ج.م',
        'وفّرت من العرض: 200 ج.م',
        'رسوم التوصيل: 30 ج.م',
        'المبلغ المستحق: 330 ج.م',
      ]);
    });

    test('code discount gets its own line with the amount', () {
      final data = orderA()
        ..['discountCode'] = 'SAVE10'
        ..['discountPercent'] = 10
        ..['discountAmount'] = 30
        ..['total'] = 270
        ..['amountDue'] = 300;
      expect(Backend.invoiceMoneyLines(data), [
        'الإجمالي: 270 ج.م',
        'وفّرت من العرض: 200 ج.م',
        'خصم الكود SAVE10 (10٪): 30 ج.م',
        'رسوم التوصيل: 30 ج.م',
        'المبلغ المستحق: 300 ج.م',
      ]);
    });

    test('fee 0 reads "مجاني" and amount due equals the items total', () {
      final data = orderA()
        ..['deliveryFee'] = 0
        ..['amountDue'] = 300;
      final lines = Backend.invoiceMoneyLines(data);
      expect(lines, contains('رسوم التوصيل: مجاني'));
      expect(lines.last, 'المبلغ المستحق: 300 ج.م');
    });

    test('legacy order without a fee: no fee line, due falls back to total',
        () {
      final data = {
        'total': 300,
        'saleSavings': 200,
      };
      expect(Backend.invoiceMoneyLines(data), [
        'الإجمالي: 300 ج.م',
        'وفّرت من العرض: 200 ج.م',
        'المبلغ المستحق: 300 ج.م',
      ]);
    });

    test('legacy order with a code but no stored discountAmount keeps '
        'the old-style code line', () {
      final data = {
        'total': 300,
        'discountCode': 'SAVE10',
        'discountPercent': 10,
      };
      expect(Backend.invoiceMoneyLines(data), [
        'الإجمالي: 300 ج.م',
        'كود الخصم: SAVE10 (10٪)',
        'المبلغ المستحق: 300 ج.م',
      ]);
    });

    test('no sale, no code, no fee: total + amount due only', () {
      expect(Backend.invoiceMoneyLines({'total': 450}), [
        'الإجمالي: 450 ج.م',
        'المبلغ المستحق: 450 ج.م',
      ]);
    });

    test('item line shows the before-sale amount only on a real sale',
        () {
      expect(
        Backend.invoiceItemLine(
            {'name': 'سماعة', 'price': 300, 'qty': 2, 'basePrice': 500}),
        'سماعة × 2 = 600 ج.م (قبل الخصم: 1000 ج.م)',
      );
      // No sale: exactly the old format.
      expect(
        Backend.invoiceItemLine({'name': 'سماعة', 'price': 300, 'qty': 2}),
        'سماعة × 2 = 600 ج.م',
      );
      // basePrice == price is not a sale, never a 0% line.
      expect(
        Backend.invoiceItemLine(
            {'name': 'سماعة', 'price': 300, 'qty': 1, 'basePrice': 300}),
        'سماعة × 1 = 300 ج.م',
      );
    });
  });
}
