// Customer derivation for the JSON export — pure logic, no Firestore.
// Customers are not a separate collection in v1: a customer is someone
// who placed an order, grouped by phone number.
List<Map<String, dynamic>> deriveCustomers(List<Map<String, dynamic>> orders) {
  final byPhone = <String, Map<String, dynamic>>{};
  for (final order in orders) {
    // Old orders carry a nested `customer` block; new orders carry
    // flat customerName/Phone/Address fields. The nested block is
    // the fallback so old (incl. cancelled) orders still show
    // their customer info.
    final nested = order['customer'] as Map?;
    final phone = (order['customerPhone'] ?? nested?['phone'] ?? '') as String;
    if (phone.isEmpty) continue;
    final existing = byPhone[phone];
    final total = ((order['total'] ?? 0) as num).toDouble();
    final createdAt = (order['createdAt'] ?? '') as String;
    final name = (order['customerName'] ?? nested?['name'] ?? '') as String;
    final address =
        (order['customerAddress'] ?? nested?['address'] ?? '') as String;
    if (existing == null) {
      byPhone[phone] = {
        'name': name,
        'phone': phone,
        'address': address,
        'ordersCount': 1,
        'totalSpent': total,
        'lastOrderAt': createdAt,
      };
    } else {
      existing['ordersCount'] = (existing['ordersCount'] as int) + 1;
      existing['totalSpent'] = (existing['totalSpent'] as double) + total;
      if (createdAt.compareTo(existing['lastOrderAt'] as String) > 0) {
        existing['lastOrderAt'] = createdAt;
        existing['address'] = address.isNotEmpty ? address : existing['address'];
      }
    }
  }
  return byPhone.values.toList();
}
