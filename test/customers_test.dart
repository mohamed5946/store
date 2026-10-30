import 'package:flutter_test/flutter_test.dart';
import 'package:storeadmin/core/customers.dart';

void main() {
  test('customers derived from orders, grouped by phone', () {
    final customers = deriveCustomers([
      {'customerName': 'محمد', 'customerPhone': '0151', 'customerAddress': 'القاهرة', 'total': 100, 'createdAt': '2026-10-01'},
      {'customerName': 'محمد', 'customerPhone': '0151', 'customerAddress': 'الجيزة', 'total': 50, 'createdAt': '2026-10-02'},
      {'customerName': 'أحمد', 'customerPhone': '0152', 'customerAddress': 'أكتوبر', 'total': 200, 'createdAt': '2026-10-01'},
    ]);
    expect(customers.length, 2);
    final first = customers.firstWhere((c) => c['phone'] == '0151');
    expect(first['ordersCount'], 2);
    expect(first['totalSpent'], 150);
    expect(first['address'], 'الجيزة'); // latest address wins
    expect(first['lastOrderAt'], '2026-10-02');
  });

  test('orders without a phone are skipped', () {
    expect(deriveCustomers([{'customerName': 'x', 'total': 10}]), isEmpty);
  });
}
