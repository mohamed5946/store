// Manual order screen (design doc file 16, Technical Plan v1.4 §7).
//
// An admin creates an order on behalf of a customer (phone order).
// The form has NO price, total, or discount-percent fields — a
// discount applies only via a code. Creation goes through the
// `createManualOrder` client transaction (contract §1): the same
// trusted path as the storefront's placeOrder (same price/stock/
// discount validation, same reservation, same idempotency, same
// audit) with source 'admin_manual' and the admin's UID. The
// permission is checked client-side first (and re-checked by the
// rules from admins/{uid}); this screen checks it only to show a
// clear message instead of a bare denial.
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../core/identifier.dart';
import '../services/backend.dart';
import '../theme/flow_theme.dart';

class ManualOrderScreen extends StatefulWidget {
  const ManualOrderScreen({super.key});

  @override
  State<ManualOrderScreen> createState() => _ManualOrderScreenState();
}

class _ManualOrderScreenState extends State<ManualOrderScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _addressCtrl = TextEditingController();
  final _discountCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();

  bool _checkingPermission = true;
  bool _canCreate = false;
  bool _submitting = false;
  String? _shippingCompanyId;
  List<Map<String, dynamic>> _shippingCompanies = [];
  Map<String, Map<String, dynamic>> _inventory = {};
  final Map<String, int> _quantities = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final canCreate = await Backend.instance.hasPermission('orders_create_manual');
      final companies = await Backend.instance.fetchShippingCompanies();
      final inventory = await Backend.instance.inventoryMap();
      if (!mounted) return;
      setState(() {
        _canCreate = canCreate;
        _shippingCompanies = companies;
        _inventory = inventory;
        _checkingPermission = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _checkingPermission = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString()), backgroundColor: Colors.red),
      );
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _addressCtrl.dispose();
    _discountCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  int get _totalQty => _quantities.values.fold(0, (a, b) => a + b);

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_totalQty == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('اختار منتج واحد على الأقل')),
      );
      return;
    }
    setState(() => _submitting = true);
    try {
      final clientOrderId = FirebaseFirestore.instance.collection('orders').doc().id;
      final items = _quantities.entries
          .where((e) => e.value > 0)
          .map((e) => {'productId': e.key, 'qty': e.value})
          .toList();
      final res = await Backend.instance.createManualOrder(
        clientOrderId: clientOrderId,
        items: items,
        discountCode: _discountCtrl.text.trim().isEmpty ? null : _discountCtrl.text.trim(),
        customerName: _nameCtrl.text.trim(),
        customerPhone: _phoneCtrl.text.trim(),
        customerAddress: _addressCtrl.text.trim(),
        shippingCompanyId: _shippingCompanyId,
        notes: _notesCtrl.text.trim().isEmpty ? null : _notesCtrl.text.trim(),
      );
      if (!mounted) return;
      final order = (res['order'] as Map<String, dynamic>?) ?? {};
      final total = ((order['total'] ?? 0) as num).toStringAsFixed(0);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تم إنشاء الطلب — الإجمالي $total ج.م')),
      );
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString()), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final variant = FlowThemeControllerScope.maybeOf(context)?.variant ??
        FlowThemeVariant.liquidGloss;
    return FlowScaffold(
      variant: variant,
      appBar: AppBar(title: const Text('طلب يدوي جديد')),
      body: _checkingPermission
          ? const Center(child: CircularProgressIndicator())
          : !_canCreate
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'ماعندكش صلاحية إنشاء طلبات يدوية — اطلب من الأدمن يفعّلها ليك',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : Form(
                  key: _formKey,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                    children: [
                      TextFormField(
                        controller: _nameCtrl,
                        decoration: const InputDecoration(labelText: 'اسم العميل'),
                        validator: (v) =>
                            (v == null || v.trim().isEmpty) ? 'اكتب اسم العميل' : null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _phoneCtrl,
                        keyboardType: TextInputType.phone,
                        decoration: const InputDecoration(labelText: 'رقم الموبايل'),
                        validator: (v) => normalizeEgyptPhone(v ?? '') == null
                            ? 'رقم الموبايل مش صحيح'
                            : null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _addressCtrl,
                        decoration: const InputDecoration(labelText: 'العنوان'),
                        validator: (v) =>
                            (v == null || v.trim().isEmpty) ? 'اكتب العنوان' : null,
                      ),
                      const SizedBox(height: 20),
                      const Text('المنتجات',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                        stream: Backend.instance.productsStream(),
                        builder: (context, snap) {
                          if (snap.connectionState == ConnectionState.waiting) {
                            return const Center(child: CircularProgressIndicator());
                          }
                          if (snap.hasError) {
                            return Text('تعذر تحميل المنتجات: ${snap.error}');
                          }
                          final docs = snap.data?.docs ?? [];
                          if (docs.isEmpty) return const Text('مفيش منتجات لسه');
                          return Column(
                            children: docs.map((d) {
                              final data = d.data();
                              final qty = _quantities[d.id] ?? 0;
                              final inv = _inventory[d.id];
                              final available = inv == null
                                  ? null
                                  : (inv['available'] as int?) ?? 0;
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text((data['name'] ?? '') as String),
                                          Text(
                                            '${((data['price'] ?? 0) as num).toStringAsFixed(0)} ج.م'
                                            '${available == null ? '' : ' — المتاح: $available'}',
                                            style: Theme.of(context).textTheme.bodySmall,
                                          ),
                                        ],
                                      ),
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.remove_circle_outline),
                                      onPressed: qty == 0
                                          ? null
                                          : () => setState(
                                              () => _quantities[d.id] = qty - 1),
                                    ),
                                    Text('$qty'),
                                    IconButton(
                                      icon: const Icon(Icons.add_circle_outline),
                                      onPressed: () => setState(
                                          () => _quantities[d.id] = qty + 1),
                                    ),
                                  ],
                                ),
                              );
                            }).toList(),
                          );
                        },
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _discountCtrl,
                        decoration: const InputDecoration(
                            labelText: 'كود خصم (اختياري)'),
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        initialValue: _shippingCompanyId,
                        decoration:
                            const InputDecoration(labelText: 'شركة الشحن (اختياري)'),
                        items: _shippingCompanies
                            .map((c) => DropdownMenuItem<String>(
                                  value: (c['id'] ?? '') as String,
                                  child: Text((c['name'] ?? '') as String),
                                ))
                            .toList(),
                        onChanged: (v) => setState(() => _shippingCompanyId = v),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _notesCtrl,
                        maxLines: 2,
                        decoration:
                            const InputDecoration(labelText: 'ملاحظات (اختياري)'),
                      ),
                      const SizedBox(height: 20),
                      FilledButton(
                        onPressed: _submitting ? null : _submit,
                        child: _submitting
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : Text('إنشاء الطلب ($_totalQty منتج)'),
                      ),
                    ],
                  ),
                ),
    );
  }
}
