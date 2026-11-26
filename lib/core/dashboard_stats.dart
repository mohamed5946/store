// Rich home-dashboard computation — pure, no Firebase, so it is
// unit-testable without Firestore. Callers convert Firestore
// Timestamps to DateTime before passing sessions in; orders carry
// their raw 'total' + 'status' fields. Revenue counts every order
// EXCEPT cancelled ones (a cancelled order is not money earned).

import 'analytics_steps.dart';

class DashboardStats {
  const DashboardStats({
    required this.visitsTotal,
    required this.visitsToday,
    required this.avgVisitSeconds,
    required this.funnelCounts,
    required this.ordersCount,
    required this.revenue,
    required this.statusCounts,
    required this.productsCount,
    required this.categoriesCount,
    required this.abandonedCount,
  });

  final int visitsTotal;
  final int visitsToday;
  final int avgVisitSeconds;
  final Map<FunnelStep, int> funnelCounts;
  final int ordersCount;
  final double revenue;
  final Map<String, int> statusCounts;
  final int productsCount;
  final int categoriesCount;
  final int abandonedCount;

  static bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}

/// Low-stock flags (contract §8/§9): products where
/// stock - reserved <= minStock (minStock default 5, the per-product
/// inventory field). Each returned map is the product map plus
/// 'available' and 'minStock'. Products with no inventory doc are
/// skipped (unknown, not low).
List<Map<String, dynamic>> lowStockProducts({
  required List<Map<String, dynamic>> products,
  required Map<String, Map<String, dynamic>> inventory,
}) {
  final low = <Map<String, dynamic>>[];
  for (final p in products) {
    final id = (p['id'] ?? '') as String;
    final inv = inventory[id];
    if (inv == null) continue;
    final stock = ((inv['stock'] ?? 0) as num).toInt();
    final reserved = ((inv['reserved'] ?? 0) as num).toInt();
    final minStock = ((inv['minStock'] ?? 5) as num).toInt();
    final available = stock - reserved;
    if (available <= minStock) {
      low.add({...p, 'available': available, 'minStock': minStock});
    }
  }
  return low;
}

DashboardStats computeDashboardStats({
  required List<Map<String, dynamic>> sessions,
  required List<Map<String, dynamic>> orders,
  required int productsCount,
  required int categoriesCount,
  required List<Map<String, dynamic>> attempts,
  required DateTime now,
}) {
  var totalMs = 0;
  var today = 0;
  final funnelCounts = <FunnelStep, int>{for (final s in funnelOrder) s: 0};
  for (final s in sessions) {
    totalMs += ((s['durationMs'] ?? 0) as num).toInt();
    final startedAt = s['startedAt'] as DateTime?;
    if (startedAt != null && DashboardStats._isSameDay(startedAt, now)) {
      today++;
    }
    final steps = (s['steps'] as List<dynamic>? ?? []).map((e) => e.toString());
    final furthest = furthestStep(steps);
    funnelCounts[furthest] = (funnelCounts[furthest] ?? 0) + 1;
  }
  final avgSeconds =
      sessions.isEmpty ? 0 : totalMs ~/ 1000 ~/ sessions.length;

  var revenue = 0.0;
  final statusCounts = <String, int>{};
  for (final o in orders) {
    final status = (o['status'] ?? 'new') as String;
    statusCounts[status] = (statusCounts[status] ?? 0) + 1;
    if (status != 'cancelled') {
      revenue += ((o['total'] ?? 0) as num).toDouble();
    }
  }

  final abandoned = attempts.where((a) {
    final data = a;
    return data['ordered'] != true &&
        ((data['contactName'] ?? '') as String).isNotEmpty;
  }).length;

  return DashboardStats(
    visitsTotal: sessions.length,
    visitsToday: today,
    avgVisitSeconds: avgSeconds,
    funnelCounts: funnelCounts,
    ordersCount: orders.length,
    revenue: revenue,
    statusCounts: statusCounts,
    productsCount: productsCount,
    categoriesCount: categoriesCount,
    abandonedCount: abandoned,
  );
}
