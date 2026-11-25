part of 'admin_shell.dart';

// ---------------- Dashboard / analytics ----------------

class _DashboardTab extends StatelessWidget {
  const _DashboardTab();

  @override
  Widget build(BuildContext context) {
    return StaggeredScope(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const StaggeredItem(index: 0, child: _DashboardKpis()),
          const SizedBox(height: 16),
          const StaggeredItem(
            index: 1,
            child: FlowSectionHeader(title: 'وصل كل زائر لحد فين'),
          ),
          const StaggeredItem(index: 2, child: _FunnelSection()),
          const SizedBox(height: 16),
          const StaggeredItem(
            index: 3,
            child: FlowSectionHeader(title: 'الطلبات الأخيرة'),
          ),
          const StaggeredItem(index: 4, child: _RecentOrders()),
          const SizedBox(height: 16),
          const StaggeredItem(
            index: 5,
            child: Text(
              'اللي بدأ طلب ومكملوش (ومعانا بياناته من خطوة مكتملة)',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(height: 8),
          const StaggeredItem(index: 6, child: _AbandonedList()),
        ],
      ),
    );
  }
}

/// KPI grid + status breakdown, computed from EXISTING Firestore data
/// only (sessions, orders, products, categories, attempts) via the
/// pure [computeDashboardStats] helper. Each stream owns its loading
/// state; the grid appears once its inputs arrive.
class _DashboardKpis extends StatelessWidget {
  const _DashboardKpis();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: Backend.instance.sessionsStream(),
      builder: (context, sessionsSnap) {
        if (sessionsSnap.connectionState == ConnectionState.waiting) {
          return _loading();
        }
        if (sessionsSnap.hasError) return _streamError(sessionsSnap.error!);
        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: Backend.instance.ordersStream(),
          builder: (context, ordersSnap) {
            if (ordersSnap.connectionState == ConnectionState.waiting) {
              return _loading();
            }
            if (ordersSnap.hasError) return _streamError(ordersSnap.error!);
            return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: Backend.instance.productsStream(),
              builder: (context, productsSnap) {
                if (productsSnap.connectionState == ConnectionState.waiting) {
                  return _loading();
                }
                return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                  stream: Backend.instance.categoriesStream(),
                  builder: (context, categoriesSnap) {
                    if (categoriesSnap.connectionState ==
                        ConnectionState.waiting) {
                      return _loading();
                    }
                    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                      stream: Backend.instance.attemptsStream(),
                      builder: (context, attemptsSnap) {
                        if (attemptsSnap.connectionState ==
                            ConnectionState.waiting) {
                          return _loading();
                        }
                        final sessions =
                            (sessionsSnap.data?.docs ?? []).map((d) {
                          final data = d.data();
                          final startedAt = data['startedAt'];
                          return <String, dynamic>{
                            'durationMs': data['durationMs'] ?? 0,
                            'startedAt': startedAt is Timestamp
                                ? startedAt.toDate()
                                : null,
                            'steps': data['steps'] ?? [],
                          };
                        }).toList();
                        final orders = (ordersSnap.data?.docs ?? [])
                            .map((d) => d.data())
                            .toList();
                        final stats = computeDashboardStats(
                          sessions: sessions,
                          orders: orders,
                          productsCount: productsSnap.data?.docs.length ?? 0,
                          categoriesCount:
                              categoriesSnap.data?.docs.length ?? 0,
                          attempts: (attemptsSnap.data?.docs ?? [])
                              .map((d) => d.data())
                              .toList(),
                          now: DateTime.now(),
                        );
                        return Column(
                          children: [
                            Row(
                              children: [
                                Expanded(
                                    child: _StatCard(
                                        'الطلبات', '${stats.ordersCount}')),
                                const SizedBox(width: 12),
                                Expanded(
                                    child: _StatCard('الإيرادات',
                                        '${stats.revenue.toStringAsFixed(0)} ج.م')),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                Expanded(
                                    child: _StatCard('الزيارات',
                                        '${stats.visitsTotal}')),
                                const SizedBox(width: 12),
                                Expanded(
                                    child: _StatCard(
                                        'زيارات اليوم', '${stats.visitsToday}')),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                Expanded(
                                    child: _StatCard('متوسط الوقت',
                                        '${stats.avgVisitSeconds} ث')),
                                const SizedBox(width: 12),
                                Expanded(
                                    child: _StatCard('طلبات متروكة',
                                        '${stats.abandonedCount}')),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                Expanded(
                                    child: _StatCard('المنتجات',
                                        '${stats.productsCount}')),
                                const SizedBox(width: 12),
                                Expanded(
                                    child: _StatCard('الأقسام',
                                        '${stats.categoriesCount}')),
                              ],
                            ),
                            const SizedBox(height: 16),
                            const FlowSectionHeader(
                                title: 'حالات الطلبات'),
                            const SizedBox(height: 8),
                            for (final entry
                                in orderStatusLabels.entries)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: _FlowRow(
                                  title: Text(entry.value),
                                  trailing: Text(
                                      '${stats.statusCounts[entry.key] ?? 0}'),
                                ),
                              ),
                          ],
                        );
                      },
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }
}

class _FunnelSection extends StatelessWidget {
  const _FunnelSection();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: Backend.instance.sessionsStream(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) return _loading();
        if (snap.hasError) return _streamError(snap.error!);
        final docs = snap.data?.docs ?? [];
        final funnelCounts = <FunnelStep, int>{for (final s in funnelOrder) s: 0};
        for (final d in docs) {
          final data = d.data();
          final steps = (data['steps'] as List<dynamic>? ?? []).map((e) => e.toString());
          funnelCounts[furthestStep(steps)] = (funnelCounts[furthestStep(steps)] ?? 0) + 1;
        }
        return Column(
          children: [
            for (final step in funnelOrder)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _FlowRow(
                  title: Text(_funnelLabel(step)),
                  trailing: Text('${funnelCounts[step]}'),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _RecentOrders extends StatelessWidget {
  const _RecentOrders();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: Backend.instance.ordersStream(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) return _loading();
        if (snap.hasError) return _streamError(snap.error!);
        final docs = snap.data?.docs ?? [];
        if (docs.isEmpty) return const Text('مفيش طلبات لسه');
        final recent = docs.take(5).toList();
        return Column(
          children: [
            for (var i = 0; i < recent.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _RecentOrderRow(doc: recent[i]),
              ),
          ],
        );
      },
    );
  }
}

class _RecentOrderRow extends StatelessWidget {
  const _RecentOrderRow({required this.doc});
  final QueryDocumentSnapshot<Map<String, dynamic>> doc;

  @override
  Widget build(BuildContext context) {
    final data = doc.data();
    final status = (data['status'] ?? 'new') as String;
    return _FlowRow(
      title: Text((data['customerName'] ?? '') as String),
      subtitle: Text(
          '${data['customerPhone'] ?? ''} — ${orderStatusLabels[status] ?? status}'),
      trailing: Text('${((data['total'] ?? 0) as num).toStringAsFixed(0)} ج.م'),
      onTap: () => _showOrderDetail(context, doc),
    );
  }
}

String _funnelLabel(FunnelStep step) {
  switch (step) {
    case FunnelStep.home:
      return 'الرئيسية بس';
    case FunnelStep.category:
      return 'قسم';
    case FunnelStep.product:
      return 'منتج';
    case FunnelStep.cart:
      return 'السلة';
    case FunnelStep.checkout:
      return 'صفحة الطلب';
    case FunnelStep.order:
      return 'طلب مكتمل';
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return FlowCard(
      child: Column(
        children: [
          Text(value, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(label, style: const TextStyle(color: FlowPalette.textSecondary)),
        ],
      ),
    );
  }
}

class _AbandonedList extends StatelessWidget {
  const _AbandonedList();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: Backend.instance.attemptsStream(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) return _loading();
        if (snap.hasError) return _streamError(snap.error!);
        final abandoned = (snap.data?.docs ?? []).where((d) {
          final data = d.data();
          return data['ordered'] != true && ((data['contactName'] ?? '') as String).isNotEmpty;
        }).toList();
        if (abandoned.isEmpty) return const Text('مفيش حالات متابعة دلوقتي');
        return Column(
          children: abandoned.map((d) {
            final data = d.data();
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _FlowRow(
                title: Text((data['contactName'] ?? '') as String),
                subtitle: Text('${data['contactPhone'] ?? ''}'),
              ),
            );
          }).toList(),
        );
      },
    );
  }
}
