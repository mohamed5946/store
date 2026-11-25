part of 'admin_shell.dart';

// ---------------- Orders ----------------

const Map<String, String> orderStatusLabels = {
  'new': 'جديد',
  'preparing': 'بيتجهز',
  'delivered': 'تم التوصيل',
  'cancelled': 'ملغي',
};

class _OrdersTab extends StatelessWidget {
  const _OrdersTab();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: Backend.instance.ordersStream(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) return _loading();
        if (snap.hasError) return _streamError(snap.error!);
        final docs = snap.data?.docs ?? [];
        if (docs.isEmpty) return const Center(child: Text('مفيش طلبات لسه'));
        return StaggeredScope(
          child: ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: docs.length,
            itemBuilder: (context, i) {
              final d = docs[i];
              final data = d.data();
              final status = (data['status'] ?? 'new') as String;
              return StaggeredItem(
                index: i,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _FlowRow(
                    title: Text((data['customerName'] ?? '') as String),
                    subtitle: Text(
                        '${data['customerPhone'] ?? ''} — ${orderStatusLabels[status] ?? status}'),
                    trailing: Text(
                        '${((data['total'] ?? 0) as num).toStringAsFixed(0)} ج.م'),
                    onTap: () => _showOrderDetail(context, d),
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

/// Order detail dialog, shared by the Orders tab and the dashboard's
/// recent-orders list. Staggered entrance on entry (v1.1.2).
Future<void> _showOrderDetail(
    BuildContext context, QueryDocumentSnapshot<Map<String, dynamic>> doc) async {
  final data = doc.data();
  var status = (data['status'] ?? 'new') as String;
  final items = (data['items'] as List<dynamic>? ?? []);
  await showDialog<void>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, setState) => AlertDialog(
        title: const Text('تفاصيل الطلب'),
        content: SingleChildScrollView(
          child: StaggeredScope(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                StaggeredItem(index: 0, child: Text('الاسم: ${data['customerName'] ?? ''}')),
                StaggeredItem(index: 1, child: Text('الموبايل: ${data['customerPhone'] ?? ''}')),
                StaggeredItem(index: 2, child: Text('العنوان: ${data['customerAddress'] ?? ''}')),
                const StaggeredItem(index: 3, child: Divider()),
                for (var k = 0; k < items.length; k++)
                  StaggeredItem(
                    index: 4 + k,
                    child: Text(
                        '${items[k]['name']} × ${items[k]['qty']} = ${((items[k]['price'] as num) * (items[k]['qty'] as num)).toStringAsFixed(0)} ج.م'),
                  ),
                const Divider(),
                Text('الإجمالي: ${((data['total'] ?? 0) as num).toStringAsFixed(0)} ج.م'),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: status,
                  items: orderStatusLabels.entries
                      .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
                      .toList(),
                  onChanged: (v) => setState(() => status = v ?? status),
                  decoration: const InputDecoration(labelText: 'حالة الطلب'),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('إغلاق')),
          FilledButton(
            onPressed: () async {
              try {
                await Backend.instance.setOrderStatus(doc.id, status);
                if (c.mounted) Navigator.pop(c);
              } catch (e) {
                if (c.mounted) _snack(c, e.toString(), error: true);
              }
            },
            child: const Text('حفظ الحالة'),
          ),
        ],
      ),
    ),
  );
}
