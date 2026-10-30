import 'package:flutter_test/flutter_test.dart';
import 'package:storeadmin/core/analytics_steps.dart';

void main() {
  test('furthest funnel step', () {
    expect(furthestStep(['home']), FunnelStep.home);
    expect(furthestStep(['home', 'product', 'cart']), FunnelStep.cart);
    expect(furthestStep(['home', 'order']), FunnelStep.order);
    expect(furthestStep([]), FunnelStep.home);
    expect(funnelStepName(FunnelStep.checkout), 'checkout');
  });

  test('category delete never orphans products', () {
    expect(
      categoryDeletePlan(productCount: 0, reassignTargetChosen: false),
      CategoryDeletePlan.allowEmpty,
    );
    expect(
      categoryDeletePlan(productCount: 3, reassignTargetChosen: false),
      CategoryDeletePlan.refuseHasProducts,
    );
    expect(
      categoryDeletePlan(productCount: 3, reassignTargetChosen: true),
      CategoryDeletePlan.reassign,
    );
  });
}


