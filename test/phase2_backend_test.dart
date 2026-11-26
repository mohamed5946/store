// Phase 2 backend tests: the unified order + feedback state machines
// and their Arabic labels (Technical Plan v1.4 Decision 23, §8.3).
// Pure logic — no Firestore, no emulator.
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
    });

    test('illegal transitions are denied', () {
      expect(Backend.isAllowedOrderTransition('new', 'delivered'), isFalse);
      expect(Backend.isAllowedOrderTransition('new', 'preparing'), isFalse);
      expect(Backend.isAllowedOrderTransition('ready', 'delivered'), isFalse);
      expect(Backend.isAllowedOrderTransition('in_transit', 'ready'), isFalse);
      expect(Backend.isAllowedOrderTransition('delivered', 'cancelled'), isFalse);
      expect(Backend.isAllowedOrderTransition('cancelled', 'accepted'), isFalse);
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
  });

  group('feedback state machine (v1.4 §8.3)', () {
    test('legal transitions are allowed', () {
      expect(Backend.isAllowedFeedbackTransition('new', 'in_review'), isTrue);
      expect(Backend.isAllowedFeedbackTransition('new', 'rejected'), isTrue);
      expect(Backend.isAllowedFeedbackTransition('new', 'spam'), isTrue);
      expect(Backend.isAllowedFeedbackTransition('in_review', 'awaiting_customer'), isTrue);
      expect(Backend.isAllowedFeedbackTransition('in_review', 'resolved'), isTrue);
      expect(Backend.isAllowedFeedbackTransition('awaiting_customer', 'resolved'), isTrue);
      expect(Backend.isAllowedFeedbackTransition('awaiting_customer', 'in_review'), isTrue);
      expect(Backend.isAllowedFeedbackTransition('resolved', 'closed'), isTrue);
    });

    test('illegal transitions are denied', () {
      expect(Backend.isAllowedFeedbackTransition('new', 'resolved'), isFalse);
      expect(Backend.isAllowedFeedbackTransition('new', 'closed'), isFalse);
      expect(Backend.isAllowedFeedbackTransition('awaiting_customer', 'spam'), isFalse);
      expect(Backend.isAllowedFeedbackTransition('resolved', 'in_review'), isFalse);
      expect(Backend.isAllowedFeedbackTransition('closed', 'in_review'), isFalse);
      expect(Backend.isAllowedFeedbackTransition('spam', 'new'), isFalse);
      expect(Backend.isAllowedFeedbackTransition('rejected', 'new'), isFalse);
    });

    test('every state and priority has an Arabic label', () {
      for (final state in Backend.feedbackTransitions.keys) {
        expect(Backend.feedbackStatusLabels[state], isNotNull,
            reason: 'missing label for $state');
      }
      expect(Backend.feedbackStatusLabels.length, 7);
      expect(Backend.feedbackPriorityLabels.keys.toSet(),
          {'low', 'medium', 'high', 'urgent'});
    });
  });
}
