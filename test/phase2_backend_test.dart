// Phase 2 backend tests: the unified order state machine and its
// Arabic labels (Technical Plan v1.4 Decision 23, §8.3).
// Pure logic — no Firestore, no emulator.
//
// NOTE (no-functions contract §6, 2026-11-26): the feedback state
// machine is DELETED — complaints are one-way cards now (no status,
// no priority, no replies, no tracking code). The feedback tests
// that lived here moved to test/no_functions_backend_test.dart
// (validateFeedbackInput + the one-way shape).
import 'package:flutter_test/flutter_test.dart';
import 'package:storeadmin/services/backend.dart';

void main() {
  group('order state machine (v1.4 Decision 23)', () {
    test('legal transitions are allowed', () {
      expect(Backend.isAllowedOrderTransition('new', 'accepted'), isTrue);
      expect(Backend.isAllowedOrderTransition('new', 'cancelled'), isTrue);
      expect(Backend.isAllowedOrderTransition('new', 'expired'), isTrue);
      expect(Backend.isAllowedOrderTransition('accepted', 'preparing'), isTrue);
      expect(Backend.isAllowedOrderTransition('preparing', 'ready'), isTrue);
      expect(Backend.isAllowedOrderTransition('ready', 'in_transit'), isTrue);
      expect(Backend.isAllowedOrderTransition('in_transit', 'delivered'), isTrue);
      // Reopen (2026-11-26 hotfix): a cancelled order goes back to
      // new — never straight to a later state.
      expect(Backend.isAllowedOrderTransition('cancelled', 'new'), isTrue);
    });

    test('illegal transitions are denied', () {
      expect(Backend.isAllowedOrderTransition('new', 'delivered'), isFalse);
      expect(Backend.isAllowedOrderTransition('new', 'preparing'), isFalse);
      expect(Backend.isAllowedOrderTransition('ready', 'delivered'), isFalse);
      expect(Backend.isAllowedOrderTransition('in_transit', 'ready'), isFalse);
      expect(Backend.isAllowedOrderTransition('delivered', 'cancelled'), isFalse);
      expect(Backend.isAllowedOrderTransition('cancelled', 'accepted'), isFalse);
      expect(Backend.isAllowedOrderTransition('cancelled', 'in_transit'), isFalse);
      expect(Backend.isAllowedOrderTransition('expired', 'accepted'), isFalse);
      expect(Backend.isAllowedOrderTransition('delivered', 'delivered'), isFalse);
    });

    test('every state has an Arabic label', () {
      for (final state in Backend.orderTransitions.keys) {
        expect(Backend.orderStatusLabels[state], isNotNull,
            reason: 'missing label for $state');
        expect(Backend.orderStatusLabels[state]!.isNotEmpty, isTrue);
      }
      expect(Backend.orderStatusLabels.length, 8);
    });

    test('the transition map covers all eight states', () {
      expect(
        Backend.orderTransitions.keys.toSet(),
        {'new', 'accepted', 'preparing', 'ready', 'in_transit', 'delivered', 'cancelled', 'expired'},
      );
    });

    test('reopen: cancelled lists only new as its next state', () {
      expect(Backend.orderTransitions['cancelled'], ['new']);
      expect(Backend.orderTransitions['expired'], []);
    });
  });
}
