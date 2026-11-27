part of 'admin_shell.dart';

// ---------------- Incomplete orders (2026-11-27) ----------------
//
// Checkout drafts are LEADS, not orders: the storefront autosaves
// them while the visitor types (local first, server after 10s idle),
// and the admin converts one only after the customer confirms
// verbally on the phone/WhatsApp. Conversion is one transaction
// (status + moot check + stock/price re-check + reserve + create +
// mark converted, doc id = draft id). Canonical schemas:
// docs/incomplete-orders-schema.md.
//
// Call/WhatsApp: this app has no url_launcher dependency, so the
// buttons copy the number / wa.me link to the clipboard (one tap
// in the dialer or WhatsApp pastes it) — never a dead button.
// True tap-to-dial needs url_launcher in pubspec.yaml (one line,
// outside this feature's file boundary — flagged for the parent).

const Map<String, String> _draftStatusLabels = {
  'new': 'جديد',
  'contacted': 'تم الاتصال',
  'no-answer': 'مردش',
  'converted': 'اتحول لطلب',
  'dead': 'مقفول',
};

String _draftGovernorateName(String? id) {
  if (id == null || id.isEmpty) return '';
  for (final g in Backend.governorates27) {
    if (g['id'] == id) return g['name']!;
  }
  return id;
}

String _draftAddress(Map<String, dynamic> d) {
  final gov = _draftGovernorateName((d['governorate'] ?? '') as String);
  final detailed = ((d['detailedAddress'] ?? '') as String).trim();
  if (gov.isNotEmpty && detailed.isNotEmpty) return '$gov — $detailed';
  if (detailed.isNotEmpty) return detailed;
  return ((d['address'] ?? '') as String).trim();
}

int _draftCompleteness(Map<String, dynamic> d) {
  final cart = (d['cart'] as List<dynamic>? ?? []);
  return Backend.draftTriageScore(
    hasName: ((d['name'] ?? '') as String).trim().isNotEmpty,
    hasPhone: Backend.isValidEgyptianMobile((d['phone'] ?? '') as String),
    hasCart: cart.isNotEmpty,
    hasAddress: _draftAddress(d).isNotEmpty,
  );
}

String _draftCartSummary(Map<String, dynamic> d) {
  final cart = (d['cart'] as List<dynamic>? ?? []);
  if (cart.isEmpty) return 'السلة فاضية';
  var total = 0;
  for (final line in cart) {
    if (line is! Map<String, dynamic>) continue;
    total += (((line['priceAtDraft'] ?? 0) as num).toInt() *
            ((line['qty'] ?? 0) as num).toInt());
  }
  return '${cart.length} منتجات — $total ج.م';
}

class _IncompleteOrdersTab extends StatefulWidget {
  const _IncompleteOrdersTab();

  @override
  State<_IncompleteOrdersTab> createState() => _IncompleteOrdersTabState();
}

class _IncompleteOrdersTabState extends State<_IncompleteOrdersTab> {
  static const _pageSize = 20;
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> _docs = [];
  QueryDocumentSnapshot<Map<String, dynamic>>? _lastDoc;
  bool _hasMore = false;
  bool _isLoading = true;
  bool _loadingMore = false;
  Object? _error;

  /// Newest real order per phone on the visible page (moot badge).
  Map<String, Map<String, dynamic>> _ordersByPhone = {};

  @override
  void initState() {
    super.initState();
    _loadPage(refresh: true);
  }

  Future<void> _loadPage({required bool refresh}) async {
    if (refresh) {
      setState(() {
        _isLoading = true;
        _error = null;
      });
    } else {
      setState(() => _loadingMore = true);
    }
    try {
      final page = await Backend.instance.fetchDraftsPage(
        startAfter: refresh ? null : _lastDoc,
        pageSize: _pageSize,
      );
      // Moot badges: one whereIn query over the visible phones.
      final phones = <String>{};
      for (final doc in page.docs) {
        final phone = (doc.data()['phone'] ?? '') as String;
        if (phone.trim().isNotEmpty) phones.add(phone.trim());
      }
      final ordersByPhone = phones.isEmpty
          ? <String, Map<String, dynamic>>{}
          : await Backend.instance.fetchOrdersByPhones(phones.toList());
      if (!mounted) return;
      setState(() {
        if (refresh) _docs.clear();
        _docs.addAll(page.docs);
        _lastDoc = page.lastDoc;
        _hasMore = page.lastDoc != null;
        _ordersByPhone = {..._ordersByPhone, ...ordersByPhone};
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

  /// The visible drafts: triage minimum first (non-empty cart +
  /// name + full valid phone — below-minimum drafts never appear),
  /// then dedup by phone (newest first wins). Status is not
  /// filtered: a `dead` draft stays visible as a closed record.
  List<QueryDocumentSnapshot<Map<String, dynamic>>> get _visible {
    final maps = _docs.map((d) => {'id': d.id, ...d.data()}).toList();
    final visible = Backend.filterVisibleDrafts(maps);
    final ids = visible.map((m) => m['id'] as String).toSet();
    return _docs.where((d) => ids.contains(d.id)).toList();
  }

  bool _isMoot(QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data();
    // mootOrderId (written by convertDraft) settles it outright.
    if (((data['mootOrderId'] ?? '') as String).trim().isNotEmpty) {
      return true;
    }
    final phone = ((data['phone'] ?? '') as String).trim();
    final order = _ordersByPhone[phone];
    if (order == null) return false;
    final draftAt = (data['createdAt'] as Timestamp?)?.toDate();
    final orderAt = (order['createdAt'] as Timestamp?)?.toDate();
    if (draftAt == null || orderAt == null) return false;
    return !orderAt.isBefore(draftAt);
  }

  /// Open the moot order for this draft (badge tap): the draft's
  /// own mootOrderId when present, else the phone lookup.
  Future<void> _openMootOrder(
      BuildContext context, Map<String, dynamic> data) async {
    final orderId = Backend.mootOrderIdFor(data, _ordersByPhone);
    if (orderId == null) return;
    await openMootOrder(context, orderId);
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return _loading();
    if (_error != null) return _streamError(_error!);
    final docs = _visible;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Text(
            'مسودات الطلبات اللي مكملتش — العميل مكملش الطلب على الموقع. اتصل بيه الأول، وحوّلها لطلب بس بعد ما يأكد بالتلفون.',
            style: TextStyle(color: StoreGlass.of(context).textSecondary),
          ),
        ),
        Expanded(
          child: docs.isEmpty
              ? const Center(child: Text('مفيش طلبات ناقصة لسه'))
              : RefreshIndicator(
                  onRefresh: () => _loadPage(refresh: true),
                  child: StaggeredScope(
                    child: ListView.builder(
                      padding: const EdgeInsets.fromLTRB(
                          16, 16, 16, StoreTokens.navPillClearance),
                      itemCount: docs.length + (_hasMore ? 1 : 0),
                      itemBuilder: (context, i) {
                        if (i == docs.length) {
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
                        final d = docs[i];
                        final data = d.data();
                        final status = (data['status'] ?? 'new') as String;
                        final name = ((data['name'] ?? '') as String).trim();
                        final phone = ((data['phone'] ?? '') as String).trim();
                        final moot = _isMoot(d);
                        return StaggeredItem(
                          index: i,
                          child: Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: _FlowRow(
                              title: Text(
                                  '${name.isEmpty ? 'لا اسم' : name} — اكتمال ${_draftCompleteness(data)}٪'),
                              // The moot badge is a real link, not text:
                              // it opens the existing order (mootOrderId
                              // when set, else the phone lookup). The
                              // button's own tap wins the gesture arena
                              // over the row's Pressable, so tapping it
                              // opens the order, not the draft detail.
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                      '${phone.isEmpty ? 'بدون رقم' : phone} • ${_draftCartSummary(data)}\nآخر مزامنة: ${_feedbackDate(data['lastSyncAt'] as Timestamp?)}'),
                                  if (moot)
                                    TextButton(
                                      onPressed: () =>
                                          _openMootOrder(context, data),
                                      style: TextButton.styleFrom(
                                        padding: EdgeInsets.zero,
                                        minimumSize: Size.zero,
                                        tapTargetSize:
                                            MaterialTapTargetSize.shrinkWrap,
                                      ),
                                      child: const Text(
                                          'طلب قبل كده — شوف الطلب'),
                                    ),
                                ],
                              ),
                              trailing: Text(
                                  _draftStatusLabels[status] ?? status),
                              onTap: () async {
                                await _showDraftDetail(context, d);
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

/// Open one order by id in the shared order-detail dialog (the
/// moot badge's target). A missing order shows a snack, never a
/// blank dialog.
Future<void> openMootOrder(BuildContext context, String orderId) async {
  final snap = await Backend.instance.fetchOrder(orderId);
  if (!context.mounted) return;
  if (!snap.exists) {
    _snack(context, 'الطلب مش موجود');
    return;
  }
  await _showOrderDetail(context, snap);
}

/// Draft detail: contact data (both phones, governorate + detailed
/// address with the old combined field as fallback), cart lines
/// with live availability (red line under an out-of-stock line),
/// journey drill-down, call/WhatsApp (copy), status actions, manual
/// delete, and conversion behind a verbal-confirmation dialog.
Future<void> _showDraftDetail(
  BuildContext context,
  QueryDocumentSnapshot<Map<String, dynamic>> doc,
) async {
  final data = doc.data();
  final nameCtrl = TextEditingController(text: (data['name'] ?? '') as String);
  final phoneCtrl =
      TextEditingController(text: (data['phone'] ?? '') as String);
  final phone2Ctrl =
      TextEditingController(text: (data['phone2'] ?? '') as String);
  final addressCtrl =
      TextEditingController(text: (data['detailedAddress'] ?? '') as String);
  var governorate = (data['governorate'] ?? '') as String;
  var errorText = '';
  var busy = false;
  var converted = false;

  Future<void> copyNumber(
      BuildContext c, String phone, String label) async {
    final digits = phone.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: digits));
    if (c.mounted) _snack(c, 'تم نسخ $label: $digits');
  }

  Future<void> copyWhatsAppLink(BuildContext c, String phone) async {
    final normalized = normalizeEgyptPhone(phone);
    final digits = normalized ??
        phone.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) return;
    await Clipboard.setData(
        ClipboardData(text: 'https://wa.me/$digits'));
    if (c.mounted) _snack(c, 'تم نسخ رابط واتساب — الصقه في المتصفح أو واتساب');
  }

  await showDialog<void>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, setState) => AlertDialog(
        title: Text(
            'مسودة — ${((data['name'] ?? '') as String).trim().isEmpty ? 'لا اسم' : data['name']}'),
        content: SingleChildScrollView(
          child: StaggeredScope(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                StaggeredItem(
                  index: 0,
                  child: Text(
                      'الحالة: ${_draftStatusLabels[(data['status'] ?? 'new') as String] ?? data['status']} • اكتمال ${_draftCompleteness(data)}٪'),
                ),
                StaggeredItem(
                  index: 1,
                  child: Text(
                      'آخر مزامنة: ${_feedbackDate(data['lastSyncAt'] as Timestamp?)}'),
                ),
                const StaggeredItem(index: 2, child: Divider()),
                StaggeredItem(
                  index: 3,
                  child: TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(labelText: 'الاسم'),
                  ),
                ),
                StaggeredItem(
                  index: 4,
                  child: TextField(
                    controller: phoneCtrl,
                    keyboardType: TextInputType.phone,
                    decoration:
                        const InputDecoration(labelText: 'رقم الموبايل'),
                  ),
                ),
                StaggeredItem(
                  index: 5,
                  child: TextField(
                    controller: phone2Ctrl,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(
                        labelText: 'رقم موبايل احتياطي (اختياري)'),
                  ),
                ),
                StaggeredItem(
                  index: 6,
                  child: StreamBuilder<
                      DocumentSnapshot<Map<String, dynamic>>>(
                    stream: Backend.instance.governoratesStream(),
                    builder: (context, snap) {
                      final entries = Backend.governorateFallback(
                        snap.data?.data()?['entries'] as List<dynamic>?,
                      ).entries;
                      final value = governorate.isEmpty ? null : governorate;
                      return DropdownButtonFormField<String>(
                        initialValue: value,
                        items: [
                          const DropdownMenuItem(
                              value: null, child: Text('اختار المحافظة')),
                          for (final g in entries)
                            DropdownMenuItem(
                                value: g['id'], child: Text(g['name']!)),
                        ],
                        onChanged: (v) =>
                            setState(() => governorate = v ?? ''),
                        decoration:
                            const InputDecoration(labelText: 'المحافظة'),
                      );
                    },
                  ),
                ),
                StaggeredItem(
                  index: 7,
                  child: TextField(
                    controller: addressCtrl,
                    maxLines: 2,
                    decoration: const InputDecoration(
                        labelText: 'العنوان بالتفصيل'),
                  ),
                ),
                if (((data['address'] ?? '') as String).trim().isNotEmpty)
                  StaggeredItem(
                    index: 8,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                          'العنوان القديم: ${data['address']}',
                          style: TextStyle(
                              color: StoreGlass.of(c).textSecondary)),
                    ),
                  ),
                const StaggeredItem(index: 9, child: Divider()),
                StaggeredItem(
                  index: 10,
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.call_outlined),
                          label: const Text('اتصال'),
                          onPressed: () =>
                              copyNumber(c, phoneCtrl.text, 'الرقم'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.chat_outlined),
                          label: const Text('واتساب'),
                          onPressed: () =>
                              copyWhatsAppLink(c, phoneCtrl.text),
                        ),
                      ),
                    ],
                  ),
                ),
                StaggeredItem(
                  index: 11,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            icon: const Icon(Icons.call_outlined),
                            label: const Text('اتصال (احتياطي)'),
                            onPressed: () => copyNumber(
                                c, phone2Ctrl.text, 'الرقم الاحتياطي'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            icon: const Icon(Icons.chat_outlined),
                            label: const Text('واتساب (احتياطي)'),
                            onPressed: () =>
                                copyWhatsAppLink(c, phone2Ctrl.text),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const StaggeredItem(index: 12, child: Divider()),
                StaggeredItem(
                  index: 13,
                  child: _DraftCartLines(docId: doc.id, cart: data['cart']),
                ),
                const SizedBox(height: 8),
                StaggeredItem(
                  index: 14,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.route_outlined),
                    label: const Text('عرض رحلة العميل في المتجر'),
                    onPressed: () => _showJourneyDialog(c, doc.id),
                  ),
                ),
                // Moot badge as a link (same target as the list badge):
                // the draft's mootOrderId opens the existing order.
                if (((data['mootOrderId'] ?? '') as String)
                        .trim()
                        .isNotEmpty)
                  StaggeredItem(
                    index: 15,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.receipt_long_outlined),
                        label: const Text('طلب قبل كده — شوف الطلب'),
                        onPressed: () => openMootOrder(
                            c,
                            ((data['mootOrderId'] ?? '') as String)
                                .trim()),
                      ),
                    ),
                  ),
                if (errorText.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(errorText,
                        style: TextStyle(color: StoreGlass.of(c).danger)),
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
          TextButton(
            onPressed: busy
                ? null
                : () async {
                    if (!await _confirm(
                        c, 'امسح المسودة دي؟ (بتتمسح نهائي)')) {
                      return;
                    }
                    setState(() => busy = true);
                    try {
                      await Backend.instance.deleteDraft(doc.id);
                      if (c.mounted) Navigator.pop(c);
                    } catch (e) {
                      setState(() {
                        busy = false;
                        errorText = e.toString();
                      });
                    }
                  },
            child: Text('مسح',
                style: TextStyle(color: StoreGlass.of(c).danger)),
          ),
          TextButton(
            onPressed: busy
                ? null
                : () async {
                    setState(() => busy = true);
                    try {
                      await Backend.instance.updateDraftStatus(
                          doc.id, 'no-answer');
                      if (c.mounted) Navigator.pop(c);
                    } catch (e) {
                      setState(() {
                        busy = false;
                        errorText = e.toString();
                      });
                    }
                  },
            child: const Text('مردش'),
          ),
          TextButton(
            onPressed: busy
                ? null
                : () async {
                    setState(() => busy = true);
                    try {
                      await Backend.instance.updateDraftStatus(
                          doc.id, 'contacted');
                      if (c.mounted) Navigator.pop(c);
                    } catch (e) {
                      setState(() {
                        busy = false;
                        errorText = e.toString();
                      });
                    }
                  },
            child: const Text('تم الاتصال'),
          ),
          // Mark dead ("not ordered", CUJ 2): the draft closes but
          // STAYS as a visible closed record — unlike مسح, which
          // removes it. updateDraftStatus already allows dead from
          // new / contacted / no-answer; terminal, so it confirms.
          TextButton(
            onPressed: busy
                ? null
                : () async {
                    if (!await _confirm(c,
                        'تقفل المسودة دي كـ "لم يطلب"؟ هتفضل ظاهرة في القايمة كمقفولة.')) {
                      return;
                    }
                    setState(() => busy = true);
                    try {
                      await Backend.instance.updateDraftStatus(
                          doc.id, 'dead');
                      if (c.mounted) Navigator.pop(c);
                    } catch (e) {
                      setState(() {
                        busy = false;
                        errorText = e.toString();
                      });
                    }
                  },
            child: const Text('مغلق — لم يطلب'),
          ),
          FilledButton(
            onPressed: busy
                ? null
                : () async {
                    // Conversion only after VERBAL confirmation: the
                    // draft is a lead, not an order.
                    final confirmed = await _confirm(c,
                        'العميل أكد الطلب بالتلفون؟\nالتحويل هيعمل طلب حقيقي ويحجز المخزون — مينفعش يتلغي من هنا.');
                    if (!confirmed) return;
                    setState(() {
                      busy = true;
                      errorText = '';
                    });
                    try {
                      final address = _draftAddress({
                        'governorate': governorate,
                        'detailedAddress': addressCtrl.text.trim(),
                        'address': (data['address'] ?? '') as String,
                      });
                      final result =
                          await Backend.instance.convertDraft(
                        draftId: doc.id,
                        customerName: nameCtrl.text.trim(),
                        customerPhone: phoneCtrl.text.trim(),
                        customerPhone2: phone2Ctrl.text.trim().isEmpty
                            ? null
                            : phone2Ctrl.text.trim(),
                        governorate:
                            governorate.isEmpty ? null : governorate,
                        detailedAddress: addressCtrl.text.trim().isEmpty
                            ? null
                            : addressCtrl.text.trim(),
                        customerAddress: address,
                      );
                      final outcome = result['result'] as String?;
                      if (outcome == 'ok' ||
                          outcome == 'ALREADY_CONVERTED') {
                        converted = true;
                        if (c.mounted) Navigator.pop(c);
                        return;
                      }
                      if (outcome == 'MOOT') {
                        setState(() {
                          busy = false;
                          errorText =
                              'الرقم ده طلب قبل كده بالفعل — المسودة دي مش محتاجة مكالمة.';
                        });
                        return;
                      }
                      if (outcome == 'PRICE_CHANGED') {
                        setState(() {
                          busy = false;
                          errorText =
                              'اتغير سعر "${result['productName']}" من ${result['oldPrice']} لـ ${result['newPrice']} ج.م — راجع السعر مع العميل الأول.';
                        });
                        return;
                      }
                      if (outcome == 'INSUFFICIENT_STOCK') {
                        final avail = result['availableQty'] ?? 0;
                        setState(() {
                          busy = false;
                          errorText = avail == 0
                              ? 'منتج "${result['productName']}" خلص من المخزون.'
                              : 'المتاح من "${result['productName']}" هو $avail بس — قلل الكمية أو اتفق مع العميل.';
                        });
                        return;
                      }
                      setState(() {
                        busy = false;
                        errorText = 'تعذر التحويل — حاول تاني.';
                      });
                    } catch (e) {
                      setState(() {
                        busy = false;
                        errorText = e.toString();
                      });
                    }
                  },
            child: const Text('تحويل لطلب'),
          ),
        ],
      ),
    ),
  );
  if (converted && context.mounted) {
    _snack(context, 'تم إنشاء الطلب من المسودة');
  }
}

/// Cart lines with live availability, refreshed from inventory when
/// the detail opens. An unorderable line carries the red
/// out-of-stock line, exactly like the storefront cart.
class _DraftCartLines extends StatelessWidget {
  const _DraftCartLines({required this.docId, required this.cart});
  final String docId;
  final dynamic cart;

  @override
  Widget build(BuildContext context) {
    final lines = (cart as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .toList();
    if (lines.isEmpty) return const Text('السلة فاضية — مفيش منتجات');
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: Backend.instance.productsStream(),
      builder: (context, prodSnap) {
        final names = <String, String>{};
        for (final d in prodSnap.data?.docs ?? []) {
          names[d.id] = (d.data()['name'] ?? d.id) as String;
        }
        return FutureBuilder<Map<String, Map<String, dynamic>>>(
          future: Backend.instance.inventoryMap(),
          builder: (context, invSnap) {
            if (invSnap.connectionState == ConnectionState.waiting) {
              return _loading();
            }
            if (invSnap.hasError) return _streamError(invSnap.error!);
            final inv = invSnap.data ?? {};
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final line in lines)
                  Builder(
                    builder: (context) {
                      final productId = (line['productId'] ?? '') as String;
                      final qty = ((line['qty'] ?? 0) as num).toInt();
                      final priceAtDraft =
                          ((line['priceAtDraft'] ?? 0) as num).toInt();
                      final stored =
                          (line['availability'] ?? 'ok') as String;
                      final invDoc = inv[productId];
                      final available = invDoc == null
                          ? null
                          : (((invDoc['stock'] ?? 0) as num).toInt() -
                              ((invDoc['reserved'] ?? 0) as num).toInt());
                      final live = available == null
                          ? stored
                          : Backend.lineAvailability(
                                  availableQty: available, qty: qty)
                              .state;
                      final oosNote = live == 'ok'
                          ? null
                          : live == 'out'
                              ? 'المنتج خلص من المخزون'
                              : 'المتاح من المنتج ده ${available ?? 0} بس — قلل الكمية';
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                                '${names[productId] ?? productId} × $qty = ${priceAtDraft * qty} ج.م'),
                            if (oosNote != null)
                              Text(oosNote,
                                  style: TextStyle(
                                      color:
                                          StoreGlass.of(context).danger)),
                          ],
                        ),
                      );
                    },
                  ),
              ],
            );
          },
        );
      },
    );
  }
}

/// Journey drill-down: the visitor's capped product list with dwell
/// bands and actions (unknown action types render as plain text),
/// plus the overflow count when more than 20 products were viewed.
Future<void> _showJourneyDialog(BuildContext context, String sessionId) async {
  final journey = await Backend.instance.journeySummaryFor(sessionId);
  if (!context.mounted) return;
  if (journey == null) {
    _snack(context, 'مفيش رحلة مسجلة للزائر ده لسه');
    return;
  }
  await showDialog<void>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('رحلة العميل في المتجر'),
      content: SingleChildScrollView(
        child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: Backend.instance.productsStream(),
          builder: (context, snap) {
            final names = <String, String>{};
            for (final d in snap.data?.docs ?? []) {
              names[d.id] = (d.data()['name'] ?? d.id) as String;
            }
            final products =
                (journey['products'] as List<dynamic>? ?? []);
            final overflow = (journey['overflowCount'] ?? 0) as int;
            final band = (journey['totalSecondsBand'] ?? '') as String;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (band.isNotEmpty) Text('إجمالي الوقت في المتجر: $band'),
                const SizedBox(height: 8),
                if (products.isEmpty)
                  const Text('مفيش منتجات متسجلة في الرحلة دي'),
                for (final entry in products)
                  if (entry is Map<String, dynamic>)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                          '${names[(entry['productId'] ?? '') as String] ?? entry['productId']} — ${entry['dwellBand'] ?? ''}\n${((entry['actions'] as List<dynamic>? ?? []).map((a) => _journeyActionLabel(a.toString())).join('، '))}'),
                    ),
                if (overflow > 0)
                  Text('+$overflow منتجات تانية اتشافت (فوق حد الـ 20)'),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(c), child: const Text('إغلاق')),
      ],
    ),
  );
}

String _journeyActionLabel(String action) =>
    Backend.journeyActionLabel(action);
