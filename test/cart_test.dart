import 'package:flutter_test/flutter_test.dart';
import 'package:storeadmin/core/cart.dart';

void main() {
  test('cart add, qty, totals', () {
    final cart = Cart();
    expect(cart.isEmpty, isTrue);
    cart.add('p1', 'منتج', 100);
    cart.add('p1', 'منتج', 100);
    cart.add('p2', 'منتج 2', 50);
    expect(cart.itemCount, 3);
    expect(cart.subtotal, 250);
    expect(cart.total, 250); // COD only: no extra fees
    cart.setQty('p1', 1);
    expect(cart.subtotal, 150);
    cart.setQty('p2', 0);
    expect(cart.lines.length, 1);
    cart.clear();
    expect(cart.isEmpty, isTrue);
  });

  test('checkout validation', () {
    expect(
      validateCheckout(name: '', phone: '01557887719', address: 'x', cartEmpty: false),
      isNotNull,
    );
    expect(
      validateCheckout(name: 'محمد', phone: '123', address: 'x', cartEmpty: false),
      isNotNull,
    );
    expect(
      validateCheckout(name: 'محمد', phone: '01557887719', address: '', cartEmpty: false),
      isNotNull,
    );
    expect(
      validateCheckout(name: 'محمد', phone: '01557887719', address: 'x', cartEmpty: true),
      isNotNull,
    );
    expect(
      validateCheckout(
          name: 'محمد', phone: '01557887719', address: 'القاهرة', cartEmpty: false),
      isNull,
    );
  });
}
