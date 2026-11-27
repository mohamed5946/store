part of 'admin_shell.dart';

// ---------------- Orders ----------------
//
// Phase 2: the list paginates (Backend.fetchOrdersPage, 20 per page)
// instead of the fixed-limit stream; the detail dialog shows the
// unified 8-state labels, offers only the LEGAL next states from the
// current status (v1.4 Decision 23), and edits the notes + the COD
// payment status. The manual-order screen opens from the header
// button (createManualOrder — the §1 client transaction, the same
// trusted path as placeOrder).

const Map<String, String> _paymentStatusLabels = {
  'cod_pending': 'بانتظار الدفع',
  'cod_paid': 'تم الدفع',
  'cod_refused': 'مرفوض',
  'cod_failed': 'فشل الدفع',
};

class _OrdersTab extends StatefulWidget {
  const _OrdersTab({this.onOpenIncompleteOrders});

  /// Opens the Incomplete Orders tab (wired by the shell).
  final VoidCallback? onOpenIncompleteOrders;

  @override
  State<_OrdersTab> createState() => _OrdersTabState();
}

class _OrdersTabState extends State<_OrdersTab> {
  static const _pageSize = 20;
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> _docs = [];
  QueryDocumentSnapshot<Map<String, dynamic>>? _lastDoc;
  bool _hasMore = false;
  bool _isLoading = true;
  bool _loadingMore = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _loadPage(refresh: true);
  }

  Future<void> _loadPage({required bool refresh}) async {
    if (refresh) {
      // Lazy sweep (contract §5): the orders list loading is one of
      // the three sweep triggers. Fire-and-forget, best-effort.
      unawaited(Backend.instance.runLazySweep());
      setState(() {
        _isLoading = true;
        _error = null;
      });
    } else {
      setState(() => _loadingMore = true);
    }
    try {
      final page = await Backend.instance.fetchOrdersPage(
        startAfter: refresh ? null : _lastDoc,
        pageSize: _pageSize,
      );
      if (!mounted) return;
      setState(() {
        if (refresh) _docs.clear();
        _docs.addAll(page.docs);
        _lastDoc = page.lastDoc;
        _hasMore = page.lastDoc != null;
        _isLoading = false;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _isLoading = false;
        _loadingMore = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return _loading();
    if (_error != null) return _streamError(_error!);
    return Column(
      children: [
        // Incomplete drafts banner (2026-11-27): a compact card at
        // the top when new drafts exist; tapping opens the
        // Incomplete Orders tab. Hidden when there are none.
        FutureBuilder<int>(
          future: Backend.instance.newDraftsCount(),
          builder: (context, snap) {
            final count = snap.data ?? 0;
            if (count <= 0) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: _FlowRow(
                title: Text('في $count طلبات ناقصة — عملاء مكملوش طلبهم'),
                subtitle: const Text('اتصل بيهم الأول، وبعد التأكيد حوّلها لطلب'),
                trailing: TextButton(
                  onPressed: widget.onOpenIncompleteOrders,
                  child: const Text('عرض'),
                ),
                onTap: widget.onOpenIncompleteOrders,
              ),
            );
          },
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Align(
            alignment: AlignmentDirectional.centerEnd,
            child: FilledButton.icon(
              onPressed: () async {
                final created = await Navigator.push<bool>(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const ManualOrderScreen()),
                );
                if (created == true && mounted) _loadPage(refresh: true);
              },
              icon: const Icon(Icons.add),
              label: const Text('طلب يدوي'),
            ),
          ),
        ),
        Expanded(
          child: _docs.isEmpty
              ? const Center(child: Text('مفيش طلبات لسه'))
              : RefreshIndicator(
                  onRefresh: () => _loadPage(refresh: true),
                  child: StaggeredScope(
                    child: ListView.builder(
                      padding: const EdgeInsets.fromLTRB(
                          16, 16, 16, StoreTokens.navPillClearance),
                      itemCount: _docs.length + (_hasMore ? 1 : 0),
                      itemBuilder: (context, i) {
                        if (i == _docs.length) {
                          return Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Center(
                              child: _loadingMore
                                  ? const CircularProgressIndicator()
                                  : OutlinedButton(
                                      onPressed: () =>
                                          _loadPage(refresh: false),
                                      child: const Text('عرض المزيد'),
                                    ),
                            ),
                          );
                        }
                        final d = _docs[i];
                        final data = d.data();
                        final status = (data['status'] ?? 'new') as String;
                        return StaggeredItem(
                          index: i,
                          child: Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: _FlowRow(
                              title: Text((data['customerName'] ?? '') as String),
                              subtitle: Text(
                                  '${data['customerPhone'] ?? ''} — ${Backend.orderStatusLabels[status] ?? status}'),
                              // List amount is the cash due at the door
                              // (amountDue), falling back to the products
                              // total on orders that predate it (CUJ 7).
                              trailing: Text(
                                  '${(((data['amountDue'] ?? data['total']) ?? 0) as num).toStringAsFixed(0)} ج.م'),
                              onTap: () async {
                                await _showOrderDetail(context, d);
                                if (mounted) _loadPage(refresh: true);
                              },
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

/// Order detail dialog, shared by the Orders tab and the dashboard's
/// recent-orders list. Staggered entrance on entry (v1.1.2).
/// Takes a plain DocumentSnapshot so the Incomplete Orders tab can
/// open an order fetched by id (moot badge).
Future<void> _showOrderDetail(
    BuildContext context, DocumentSnapshot<Map<String, dynamic>> doc) async {
  final data = doc.data() ?? {};
  var status = (data['status'] ?? 'new') as String;
  var paymentStatus = (data['paymentStatus'] ?? 'cod_pending') as String;
  final notesCtrl = TextEditingController(text: (data['notes'] ?? '') as String);
  final items = (data['items'] as List<dynamic>? ?? []);
  // Only the current status + its legal next states are offered
  // (the state machine, v1.4 Decision 23); 'expired' is the sweep's
  // job, never a manual choice.
  final legalNext = (Backend.orderTransitions[status] ?? [])
      .where((s) => s != 'expired')
      .toList();
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
                // Dual-shape contact (incomplete orders, 2026-11-27):
                // new fields when present, old combined field always.
                if ((data['customerPhone2'] as String?)?.isNotEmpty == true)
                  StaggeredItem(index: 2, child: Text('الموبايل الاحتياطي: ${data['customerPhone2']}')),
                if ((data['governorate'] as String?)?.isNotEmpty == true)
                  StaggeredItem(index: 3, child: Text('المحافظة: ${_draftGovernorateName(data['governorate'] as String)}')),
                if ((data['detailedAddress'] as String?)?.isNotEmpty == true)
                  StaggeredItem(index: 4, child: Text('العنوان بالتفصيل: ${data['detailedAddress']}')),
                StaggeredItem(index: 5, child: Text('العنوان: ${data['customerAddress'] ?? ''}')),
                const StaggeredItem(index: 6, child: Divider()),
                for (var k = 0; k < items.length; k++)
                  StaggeredItem(
                    index: 7 + k,
                    child: Text(Backend.invoiceItemLine(
                        items[k] as Map<String, dynamic>)),
                  ),
                const Divider(),
                // Money lines (CUJ 7): products total, sale savings,
                // code discount, delivery fee, amount due — the same
                // lines as the PC invoice and the share text.
                for (final line in Backend.invoiceMoneyLines(data))
                  Text(line),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: status,
                  items: [status, ...legalNext]
                      .map((s) => DropdownMenuItem(
                          value: s,
                          child: Text(Backend.orderStatusLabels[s] ?? s)))
                      .toList(),
                  onChanged: (v) => setState(() => status = v ?? status),
                  decoration: const InputDecoration(labelText: 'حالة الطلب'),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: paymentStatus,
                  items: _paymentStatusLabels.entries
                      .map((e) => DropdownMenuItem(
                          value: e.key, child: Text(e.value)))
                      .toList(),
                  onChanged: (v) =>
                      setState(() => paymentStatus = v ?? paymentStatus),
                  decoration: const InputDecoration(labelText: 'حالة الدفع'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: notesCtrl,
                  maxLines: 2,
                  decoration:
                      const InputDecoration(labelText: 'ملاحظات (اختياري)'),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('إغلاق'),
          ),
          // Print (contract §9, trivial route): no printing plugin
          // is added — the invoice is shared as text, and the share
          // sheet offers printing. Every button here is wired.
          TextButton.icon(
            icon: const Icon(Icons.share_outlined),
            label: const Text('مشاركة الفاتورة'),
            onPressed: () async {
              final lines = <String>[
                'فاتورة طلب',
                'الاسم: ${data['customerName'] ?? ''}',
                'الموبايل: ${data['customerPhone'] ?? ''}',
                if ((data['customerPhone2'] as String?)?.isNotEmpty == true)
                  'الموبايل الاحتياطي: ${data['customerPhone2']}',
                if ((data['governorate'] as String?)?.isNotEmpty == true)
                  'المحافظة: ${_draftGovernorateName(data['governorate'] as String)}',
                'العنوان: ${data['customerAddress'] ?? ''}',
                'الحالة: ${Backend.orderStatusLabels[status] ?? status}',
                '---',
              ];
              for (final item in items) {
                lines.add(Backend.invoiceItemLine(
                    item as Map<String, dynamic>));
              }
              lines.add('---');
              // Money lines (CUJ 7) — identical to the dialog, so the
              // shared invoice never understates the cash due.
              lines.addAll(Backend.invoiceMoneyLines(data));
              await SharePlus.instance.share(
                ShareParams(text: lines.join('\n')),
              );
            },
          ),
          FilledButton(
            onPressed: () async {
              try {
                if (status != (data['status'] ?? '')) {
                  await Backend.instance.setOrderStatus(doc.id, status);
                }
                if (paymentStatus != (data['paymentStatus'] ?? 'cod_pending')) {
                  await Backend.instance
                      .setOrderPaymentStatus(doc.id, paymentStatus);
                }
                if (notesCtrl.text.trim() != ((data['notes'] ?? '') as String).trim()) {
                  await Backend.instance.setOrderNotes(doc.id, notesCtrl.text);
                }
                if (c.mounted) Navigator.pop(c);
              } catch (e) {
                if (c.mounted) _snack(c, e.toString(), error: true);
              }
            },
            child: const Text('حفظ'),
          ),
        ],
      ),
    ),
  );
}
