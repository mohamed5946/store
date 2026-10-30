// Storefront funnel analytics — pure step mapping, no Firebase.

/// Funnel steps in order. A session's "reached step" is the furthest step
/// in this order the visitor got to.
enum FunnelStep { home, category, product, cart, checkout, order }

const List<FunnelStep> funnelOrder = <FunnelStep>[
  FunnelStep.home,
  FunnelStep.category,
  FunnelStep.product,
  FunnelStep.cart,
  FunnelStep.checkout,
  FunnelStep.order,
];

String funnelStepName(FunnelStep step) {
  switch (step) {
    case FunnelStep.home:
      return 'home';
    case FunnelStep.category:
      return 'category';
    case FunnelStep.product:
      return 'product';
    case FunnelStep.cart:
      return 'cart';
    case FunnelStep.checkout:
      return 'checkout';
    case FunnelStep.order:
      return 'order';
  }
}

/// The furthest step reached given a set of recorded step names.
FunnelStep furthestStep(Iterable<String> recorded) {
  var best = FunnelStep.home;
  for (final step in funnelOrder) {
    if (recorded.contains(funnelStepName(step))) best = step;
  }
  return best;
}

/// Category delete policy — pure logic so it is testable without Firestore.
/// Deleting a category must never silently orphan its products: the caller
/// must either refuse (products exist) or reassign them first.
enum CategoryDeletePlan { allowEmpty, refuseHasProducts, reassign }

CategoryDeletePlan categoryDeletePlan({
  required int productCount,
  required bool reassignTargetChosen,
}) {
  if (productCount == 0) return CategoryDeletePlan.allowEmpty;
  if (reassignTargetChosen) return CategoryDeletePlan.reassign;
  return CategoryDeletePlan.refuseHasProducts;
}
