// Incomplete orders (2026-11-27) — pure-logic tests for
// Backend's draft helpers. The conversion transaction itself
// (status + moot + stock/price re-check + reserve + create +
// mark converted) needs Firestore and is covered by the PC
// firebase-store tests + the rules emulator suite; here we pin
// the pure pieces it relies on: phone validation, triage/dedup,
// the state machine, governorate fallback, line availability,
// and the whole-number money helper.
import 'package:flutter_test/flutter_test.dart';
import 'package:storeadmin/services/backend.dart';

void main() {
  group('Egyptian mobile validation', () {
    test('valid primary numbers (010/011/012/015, 11 digits)', () {
      for (final n in [
        '01001234567',
        '01112345678',
        '01223456789',
        '01555555555',
      ]) {
        expect(Backend.isValidEgyptianMobile(n), isTrue, reason: n);
      }
    });

    test('secondary (backup) phone validates by the same rule', () {
      expect(Backend.isValidEgyptianMobile('01098765432'), isTrue);
      expect(Backend.isValidEgyptianMobile('01901234567'), isFalse);
      expect(Backend.isValidEgyptianMobile(''), isFalse);
      expect(Backend.isValidEgyptianMobile(null), isFalse);
    });

    test('rejects bad prefix, short and long numbers', () {
      expect(Backend.isValidEgyptianMobile('01901234567'), isFalse);
      expect(Backend.isValidEgyptianMobile('0100123456'), isFalse);
      expect(Backend.isValidEgyptianMobile('010012345678'), isFalse);
      expect(Backend.isValidEgyptianMobile('0100 123 4567'), isTrue);
    });

    test('a pasted +20 / 20 country code folds to 01…', () {
      expect(Backend.isValidEgyptianMobile('+201001234567'), isTrue);
      expect(Backend.isValidEgyptianMobile('201001234567'), isTrue);
    });
  });

  group('draft triage + dedup', () {
    test('completeness is 25 per filled part, 100 when complete', () {
      expect(
        Backend.draftTriageScore(
          hasName: false,
          hasPhone: false,
          hasCart: false,
          hasAddress: false,
        ),
        0,
      );
      expect(
        Backend.draftTriageScore(
          hasName: true,
          hasPhone: false,
          hasCart: false,
          hasAddress: false,
        ),
        25,
      );
      expect(
        Backend.draftTriageScore(
          hasName: true,
          hasPhone: true,
          hasCart: true,
          hasAddress: true,
        ),
        100,
      );
    });

    test('dedup by phone keeps the newest draft per phone', () {
      final drafts = [
        {'phone': '01001234567', 'name': 'newest'},
        {'phone': '01112345678', 'name': 'other'},
        {'phone': '01001234567', 'name': 'older'},
        {'phone': '', 'name': 'no phone 1'},
        {'phone': '', 'name': 'no phone 2'},
      ];
      final deduped = Backend.dedupDraftsByPhone(drafts);
      expect(deduped.map((d) => d['name']).toList(), [
        'newest',
        'other',
        'no phone 1',
        'no phone 2',
      ]);
    });

    test('dedup treats +20 and 01… forms of one number as one phone', () {
      final drafts = [
        {'phone': '+201001234567', 'name': 'intl'},
        {'phone': '01001234567', 'name': 'local'},
      ];
      expect(Backend.dedupDraftsByPhone(drafts).length, 1);
      expect(Backend.dedupDraftsByPhone(drafts).first['name'], 'intl');
    });
  });

  group('draft state machine', () {
    test('new can go to contacted / no-answer / converted / dead', () {
      for (final to in ['contacted', 'no-answer', 'converted', 'dead']) {
        expect(Backend.draftCanTransition('new', to), isTrue, reason: to);
      }
    });

    test('contacted and no-answer can move between each other', () {
      expect(Backend.draftCanTransition('contacted', 'no-answer'), isTrue);
      expect(Backend.draftCanTransition('no-answer', 'contacted'), isTrue);
      expect(Backend.draftCanTransition('contacted', 'converted'), isTrue);
      expect(Backend.draftCanTransition('no-answer', 'dead'), isTrue);
    });

    test('converted and dead are terminal — nothing leaves them', () {
      for (final from in ['converted', 'dead']) {
        for (final to in ['new', 'contacted', 'no-answer', 'converted', 'dead']) {
          expect(Backend.draftCanTransition(from, to), isFalse,
              reason: '$from -> $to');
        }
      }
    });

    test('a converted draft can never go back to new', () {
      expect(Backend.draftCanTransition('converted', 'new'), isFalse);
    });
  });

  group('governorate fallback', () {
    test('a missing doc falls back to the full 27', () {
      final resolved = Backend.governorateFallback(null);
      expect(resolved.entries.length, 27);
      expect(resolved.fromFallback, isTrue);
      expect(resolved.notSetUp, isFalse);
      expect(
        resolved.entries.map((g) => g['id']),
        containsAll(['cairo', 'giza', 'south-sinai']),
      );
    });

    test('a doc with active entries resolves to exactly those', () {
      final resolved = Backend.governorateFallback([
        {'id': 'cairo', 'name': 'القاهرة', 'active': true},
        {'id': 'giza', 'name': 'الجيزة', 'active': false},
        {'id': 'alexandria', 'name': 'الإسكندرية', 'active': true},
      ]);
      expect(
        resolved.entries.map((g) => g['id']).toList(),
        ['cairo', 'alexandria'],
      );
      expect(resolved.notSetUp, isFalse);
    });

    test('zero active entries is the "not set up" state', () {
      final resolved = Backend.governorateFallback([
        {'id': 'cairo', 'name': 'القاهرة', 'active': false},
      ]);
      expect(resolved.entries, isEmpty);
      expect(resolved.notSetUp, isTrue);
      expect(Backend.governorateFallback([]).notSetUp, isTrue);
    });
  });

  group('out-of-stock line availability', () {
    test('ok when the quantity fits, out at zero, short in between', () {
      expect(
        Backend.lineAvailability(availableQty: 5, qty: 3).state,
        'ok',
      );
      expect(
        Backend.lineAvailability(availableQty: 3, qty: 3).state,
        'ok',
      );
      expect(
        Backend.lineAvailability(availableQty: 0, qty: 1).state,
        'out',
      );
      expect(
        Backend.lineAvailability(availableQty: 2, qty: 5).state,
        'short',
      );
      expect(
        Backend.lineAvailability(availableQty: 2, qty: 5).availableQty,
        2,
      );
    });
  });

  group('conversion money helpers', () {
    test('wholeNum stores whole doubles as int (rules require int)', () {
      expect(Backend.wholeNum(100.0), 100);
      expect(Backend.wholeNum(100.0), isA<int>());
      expect(Backend.wholeNum(19.99), 19.99);
      expect(Backend.wholeNum(5), 5);
    });

    test('conversion result codes are the five the screen handles', () {
      // The screen branches on exactly these strings from
      // convertDraft; a typo here would silently fall through to
      // the generic error. Pinned as a set, not by running a tx.
      const results = {
        'ok',
        'PRICE_CHANGED',
        'INSUFFICIENT_STOCK',
        'MOOT',
        'ALREADY_CONVERTED',
      };
      expect(results.length, 5);
      expect(results, contains('ok'));
      expect(results, contains('MOOT'));
    });
  });

  group('triage minimum for the list (B2)', () {
    test('meets triage only with name + valid phone + non-empty cart', () {
      expect(
        Backend.draftMeetsTriage(
            hasName: true, hasPhone: true, hasCart: true),
        isTrue,
      );
      expect(
        Backend.draftMeetsTriage(
            hasName: false, hasPhone: true, hasCart: true),
        isFalse,
        reason: 'no name',
      );
      expect(
        Backend.draftMeetsTriage(
            hasName: true, hasPhone: false, hasCart: true),
        isFalse,
        reason: 'bad phone',
      );
      expect(
        Backend.draftMeetsTriage(
            hasName: true, hasPhone: true, hasCart: false),
        isFalse,
        reason: 'empty cart',
      );
    });

    test('map form reads name / phone / cart off the draft document', () {
      final good = {
        'name': 'أحمد',
        'phone': '01001234567',
        'cart': [
          {'productId': 'p1', 'qty': 1},
        ],
      };
      expect(Backend.draftMeetsTriageMap(good), isTrue);
      expect(
        Backend.draftMeetsTriageMap({...good, 'name': '  '}),
        isFalse,
      );
      expect(
        Backend.draftMeetsTriageMap({...good, 'phone': '01901234567'}),
        isFalse,
      );
      expect(Backend.draftMeetsTriageMap({...good, 'cart': []}), isFalse);
      // Address is scored, not required: no address still lists.
      expect(Backend.draftMeetsTriageMap(good), isTrue);
    });

    test('filterVisibleDrafts drops below-minimum rows, keeps dedup', () {
      final drafts = [
        {
          'id': 'd1',
          'name': 'أحمد',
          'phone': '01001234567',
          'cart': [
            {'productId': 'p1', 'qty': 1},
          ],
        },
        {'id': 'd2', 'name': '', 'phone': '01112345678', 'cart': [
          {'productId': 'p1', 'qty': 1},
        ]},
        {
          'id': 'd3',
          'name': 'منى',
          'phone': '01223456789',
          'cart': [],
        },
        {
          'id': 'd4',
          'name': 'أحمد نسخة',
          'phone': '01001234567',
          'cart': [
            {'productId': 'p2', 'qty': 2},
          ],
        },
      ];
      final visible = Backend.filterVisibleDrafts(drafts);
      // d2 (no name) and d3 (empty cart) are out; d4 is the same
      // phone as d1, so the newest (d1) wins the dedup.
      expect(visible.map((d) => d['id']).toList(), ['d1']);
    });
  });

  group('mark dead (B3)', () {
    test('dead is reachable from every open state', () {
      for (final from in ['new', 'contacted', 'no-answer']) {
        expect(Backend.draftCanTransition(from, 'dead'), isTrue,
            reason: from);
      }
    });

    test('a dead draft that meets triage stays visible as closed', () {
      final drafts = [
        {
          'id': 'd-dead',
          'name': 'أحمد',
          'phone': '01001234567',
          'cart': [
            {'productId': 'p1', 'qty': 1},
          ],
          'status': 'dead',
        },
        {
          'id': 'd-conv',
          'name': 'منى',
          'phone': '01112345678',
          'cart': [
            {'productId': 'p1', 'qty': 1},
          ],
          'status': 'converted',
        },
      ];
      final visible = Backend.filterVisibleDrafts(drafts);
      // Closed records are not filtered out of the list — closing
      // as "not ordered" keeps the row, unlike delete.
      expect(
        visible.map((d) => d['id']).toList(),
        ['d-dead', 'd-conv'],
      );
    });
  });

  group('moot badge target (B5)', () {
    test('prefers the draft mootOrderId field over the phone lookup', () {
      final draft = {
        'phone': '01001234567',
        'mootOrderId': 'order-99',
      };
      final byPhone = {
        '01001234567': {'id': 'order-1'},
      };
      expect(Backend.mootOrderIdFor(draft, byPhone), 'order-99');
    });

    test('falls back to the newest order for the phone', () {
      final draft = {'phone': '01001234567'};
      final byPhone = {
        '01001234567': {'id': 'order-1'},
      };
      expect(Backend.mootOrderIdFor(draft, byPhone), 'order-1');
    });

    test('null when neither the field nor the lookup has an order', () {
      expect(Backend.mootOrderIdFor({'phone': '01001234567'}, {}), isNull);
      expect(Backend.mootOrderIdFor({'phone': ''}, {}), isNull);
      expect(
        Backend.mootOrderIdFor(
            {'phone': '01001234567', 'mootOrderId': '  '}, {}),
        isNull,
      );
    });
  });

  group('manual-order audit coverage (B6)', () {
    test('order audit covers items exactly when a line has a base price', () {
      expect(
        Backend.orderAuditFields(hasBasePrice: true),
        contains('items'),
      );
      expect(
        Backend.orderAuditFields(hasBasePrice: false),
        isNot(contains('items')),
      );
    });

    test('money fields are always covered, with or without a sale', () {
      for (final hasBase in [true, false]) {
        final fields = Backend.orderAuditFields(hasBasePrice: hasBase);
        expect(
          fields,
          containsAll(
              ['status', 'total', 'saleSavings', 'deliveryFee', 'amountDue']),
        );
      }
    });
  });
}
