// Admin shell: dashboard (analytics), products, categories, orders,
// team, settings + diagnostics. Apple-level feel: weighted motion is kept
// simple and calm — animated switching, no popping, loading states first.
import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../core/analytics_steps.dart';
import '../core/diagnostics.dart';
import '../core/sample_data.dart';
import '../services/backend.dart';
import '../services/cloudinary.dart';
import '../theme/flow_theme.dart';
import '../theme/store_design.dart';

class AdminShell extends StatefulWidget {
  const AdminShell({super.key, required this.onSignedOut, this.themeController});
  final VoidCallback onSignedOut;
  final FlowThemeController? themeController;

  @override
  State<AdminShell> createState() => _AdminShellState();
}

class _AdminShellState extends State<AdminShell> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      const _DashboardTab(),
      const _ProductsTab(),
      const _CategoriesTab(),
      const _OrdersTab(),
      const _TeamTab(),
      _SettingsTab(
        onSignedOut: widget.onSignedOut,
        themeController: widget.themeController,
      ),
    ];
    final variant = FlowThemeControllerScope.maybeOf(context)?.variant ??
        FlowThemeVariant.liquidGloss;
    return FlowScaffold(
      variant: variant,
      appBar: AppBar(title: const Text('إدارة المتجر')),
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 250),
        child: KeyedSubtree(key: ValueKey<int>(_tab), child: pages[_tab]),
      ),
      bottomNavigationBar: FlowNavPill(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        icons: const [
          Icons.analytics_outlined,
          Icons.inventory_2_outlined,
          Icons.category_outlined,
          Icons.receipt_long_outlined,
          Icons.group_outlined,
          Icons.settings_outlined,
        ],
        labels: const ['الرئيسية', 'المنتجات', 'الأقسام', 'الطلبات', 'الفريق', 'الإعدادات'],
      ),
    );
  }
}

Widget _loading() => flowLoading();

Widget _streamError(Object error) => Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          'تعذر تحميل البيانات: $error',
          textAlign: TextAlign.center,
          style: const TextStyle(color: FlowPalette.danger),
        ),
      ),
    );

Future<bool> _confirm(BuildContext context, String message) async {
  final result = await showFlowDialog<bool>(
    context: context,
    title: const Text('تأكيد'),
    content: Text(message),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('إلغاء')),
      FlowButton(label: 'تأكيد', onPressed: () => Navigator.pop(context, true)),
    ],
  );
  return result ?? false;
}

void _snack(BuildContext context, String message, {bool error = false}) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(message),
      backgroundColor: error ? FlowPalette.danger : null,
    ),
  );
}

// ---------------- Dashboard / analytics ----------------

class _DashboardTab extends StatelessWidget {
  const _DashboardTab();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: Backend.instance.sessionsStream(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) return _loading();
        if (snap.hasError) return _streamError(snap.error!);
        final docs = snap.data?.docs ?? [];
        var totalMs = 0;
        final funnelCounts = <FunnelStep, int>{for (final s in funnelOrder) s: 0};
        for (final d in docs) {
          final data = d.data();
          totalMs += ((data['durationMs'] ?? 0) as num).toInt();
          final steps = (data['steps'] as List<dynamic>? ?? []).map((e) => e.toString());
          funnelCounts[furthestStep(steps)] = (funnelCounts[furthestStep(steps)] ?? 0) + 1;
        }
        final avgSeconds = docs.isEmpty ? 0 : totalMs ~/ 1000 ~/ docs.length;
        return StaggeredScope(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              StaggeredItem(
                index: 0,
                child: Row(
                  children: [
                    Expanded(child: _StatCard('الزيارات', '${docs.length}')),
                    const SizedBox(width: 12),
                    Expanded(child: _StatCard('متوسط الوقت', '$avgSeconds ث')),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const StaggeredItem(
                index: 1,
                child: FlowSectionHeader(title: 'وصل كل زائر لحد فين'),
              ),
              const SizedBox(height: 8),
            for (final step in funnelOrder)
              ListTile(
                title: Text(_funnelLabel(step)),
                trailing: Text('${funnelCounts[step]}'),
              ),
            const Divider(),
            const Text(
              'اللي بدأ طلب ومكملوش (ومعانا بياناته من خطوة مكتملة)',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
              const StaggeredItem(index: 2, child: _AbandonedList()),
            ],
          ),
        );
      },
    );
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
            return ListTile(
              title: Text((data['contactName'] ?? '') as String),
              subtitle: Text('${data['contactPhone'] ?? ''}'),
            );
          }).toList(),
        );
      },
    );
  }
}

// ---------------- Products ----------------

class _ProductsTab extends StatelessWidget {
  const _ProductsTab();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: Backend.instance.productsStream(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) return _loading();
        if (snap.hasError) return _streamError(snap.error!);
        final docs = snap.data?.docs ?? [];
        return Scaffold(
          floatingActionButton: FloatingActionButton(
            onPressed: () => _editProduct(context, null),
            child: const Icon(Icons.add),
          ),
          body: docs.isEmpty
              ? const Center(child: Text('مفيش منتجات — ضيف أول منتج'))
              : ListView.builder(
                  itemCount: docs.length,
                  itemBuilder: (context, i) {
                    final p = ProductData.fromDoc(docs[i]);
                    return ListTile(
                      leading: _ProductThumb(product: p),
                      title: Text(p.name),
                      subtitle: Text('${p.price.toStringAsFixed(0)} ج.م'),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.edit_outlined),
                            onPressed: () => _editProduct(context, p),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline, color: Colors.red),
                            onPressed: () async {
                              if (await _confirm(context, 'امسح المنتج "${p.name}"؟')) {
                                try {
                                  await Backend.instance.deleteProduct(p.id);
                                } catch (e) {
                                  if (context.mounted) _snack(context, e.toString(), error: true);
                                }
                              }
                            },
                          ),
                        ],
                      ),
                    );
                  },
                ),
        );
      },
    );
  }

  Future<void> _editProduct(BuildContext context, ProductData? existing) async {
    final name = TextEditingController(text: existing?.name ?? '');
    final price = TextEditingController(
        text: existing == null ? '' : existing.price.toStringAsFixed(0));
    final desc = TextEditingController(text: existing?.description ?? '');
    final link = TextEditingController();
    var images = List<CloudinaryImage>.from(existing?.images ?? []);
    var categoryId = existing?.categoryId ?? '';
    var busy = false;
    var uploading = false;
    var uploadProgress = 0.0;
    var errorText = '';
    await showDialog<void>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setState) {
          return AlertDialog(
            title: Text(existing == null ? 'منتج جديد' : 'تعديل منتج'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                      controller: name,
                      decoration: const InputDecoration(labelText: 'اسم المنتج')),
                  TextField(
                    controller: price,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'السعر (ج.م)'),
                  ),
                  TextField(
                      controller: desc,
                      decoration: const InputDecoration(labelText: 'الوصف')),
                  const SizedBox(height: 12),
                  const Align(
                    alignment: Alignment.centerRight,
                    child: Text('صور المنتج (الأولى هي الغلاف)',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                  const SizedBox(height: 8),
                  if (images.isEmpty)
                    const Text('مفيش صور لسه', style: TextStyle(color: Colors.grey)),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: images.map((img) {
                      return Stack(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.network(deliveryUrl(img.url), width: 72, height: 72,
                                fit: BoxFit.cover,
                                errorBuilder: (c, e, st) => const SizedBox(
                                    width: 72, height: 72, child: Icon(Icons.broken_image_outlined))),
                          ),
                          Positioned(
                            top: 0,
                            left: 0,
                            child: GestureDetector(
                              // Removing deletes the entry from the doc
                              // only — the file itself stays on Cloudinary
                              // as an orphan until cleaned from the dashboard.
                              onTap: () => setState(
                                  () => images.removeWhere((x) => x.url == img.url)),
                              child: Container(
                                decoration: const BoxDecoration(
                                  color: Colors.red,
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(Icons.close, size: 16, color: Colors.white),
                              ),
                            ),
                          ),
                        ],
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.photo_outlined),
                    label: Text(uploading ? 'جارٍ الرفع…' : 'رفع صورة من الموبايل'),
                    onPressed: uploading
                        ? null
                        : () async {
                            final picked = await ImagePicker().pickImage(
                              source: ImageSource.gallery,
                              maxWidth: 1200,
                              maxHeight: 1200,
                              imageQuality: 80,
                            );
                            if (picked == null) return;
                            setState(() {
                              uploading = true;
                              uploadProgress = 0.0;
                              errorText = '';
                            });
                            try {
                              final bytes = await picked.readAsBytes();
                              final uploaded = await uploadImageToCloudinary(
                                bytes,
                                onProgress: (p) => setState(() => uploadProgress = p),
                              );
                              setState(() => images.add(uploaded));
                            } catch (e) {
                              setState(() => errorText = e.toString());
                            } finally {
                              setState(() => uploading = false);
                            }
                          },
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: link,
                          decoration: const InputDecoration(
                            labelText: 'أو لينك صورة',
                            hintText: 'https://…',
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: () {
                          final url = link.text.trim();
                          if (url.isEmpty) return;
                          setState(() {
                            images.add(CloudinaryImage(url: url, publicId: ''));
                            link.clear();
                          });
                        },
                        child: const Text('إضافة'),
                      ),
                    ],
                  ),
                  if (uploading)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Column(
                        children: [
                          LinearProgressIndicator(value: uploadProgress),
                          const SizedBox(height: 4),
                          Text('جارٍ الرفع… ${(uploadProgress * 100).toInt()}٪'),
                        ],
                      ),
                    ),
                  if (errorText.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(errorText, style: const TextStyle(color: Colors.red)),
                    ),
                  const SizedBox(height: 8),
                  StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                    stream: Backend.instance.categoriesStream(),
                    builder: (c, snap) {
                      final cats = snap.data?.docs ?? [];
                      if (cats.isEmpty) {
                        return const Text('ضيف قسم الأول من تبويب الأقسام');
                      }
                      categoryId = categoryId.isEmpty
                          ? cats.first.id
                          : (cats.any((d) => d.id == categoryId) ? categoryId : cats.first.id);
                      return DropdownButtonFormField<String>(
                        initialValue: categoryId,
                        items: cats
                            .map((d) => DropdownMenuItem(
                                  value: d.id,
                                  child: Text((d.data()['name'] ?? '') as String),
                                ))
                            .toList(),
                        onChanged: (v) => setState(() => categoryId = v ?? ''),
                        decoration: const InputDecoration(labelText: 'القسم'),
                      );
                    },
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c), child: const Text('إلغاء')),
              FilledButton(
                onPressed: busy
                    ? null
                    : () async {
                        if (name.text.trim().isEmpty ||
                            double.tryParse(price.text.trim()) == null ||
                            categoryId.isEmpty) {
                          setState(() => errorText = 'كمّل اسم المنتج والسعر والقسم');
                          return;
                        }
                        setState(() => busy = true);
                        try {
                          await Backend.instance.saveProduct(ProductData(
                            id: existing?.id ?? '',
                            name: name.text.trim(),
                            price: double.parse(price.text.trim()),
                            description: desc.text.trim(),
                            categoryId: categoryId,
                            images: images,
                          ));
                          if (c.mounted) Navigator.pop(c);
                        } catch (e) {
                          setState(() {
                            busy = false;
                            errorText = e.toString();
                          });
                        }
                      },
                child: const Text('حفظ'),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ProductThumb extends StatelessWidget {
  const _ProductThumb({required this.product});
  final ProductData product;

  @override
  Widget build(BuildContext context) {
    if (product.images.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.network(deliveryUrl(product.images.first.url), width: 48, height: 48,
            fit: BoxFit.cover, errorBuilder: (c, e, st) => _fallback()),
      );
    }
    return _fallback();
  }

  Widget _fallback() => Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          gradient: FlowPalette.brandGradient,
          borderRadius: BorderRadius.circular(8),
        ),
        alignment: Alignment.center,
        child: Text(
          product.name.isEmpty ? '؟' : product.name.characters.first,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
      );
}

// ---------------- Categories ----------------

class _CategoriesTab extends StatelessWidget {
  const _CategoriesTab();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: Backend.instance.categoriesStream(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) return _loading();
        if (snap.hasError) return _streamError(snap.error!);
        final docs = snap.data?.docs ?? [];
        return Scaffold(
          floatingActionButton: FloatingActionButton(
            onPressed: () => _editCategory(context, null),
            child: const Icon(Icons.add),
          ),
          body: docs.isEmpty
              ? const Center(child: Text('مفيش أقسام — ضيف أول قسم'))
              : ListView.builder(
                  itemCount: docs.length,
                  itemBuilder: (context, i) {
                    final d = docs[i];
                    final name = (d.data()['name'] ?? '') as String;
                    return ListTile(
                      title: Text(name),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.edit_outlined),
                            onPressed: () => _editCategory(context, d),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline, color: Colors.red),
                            onPressed: () async {
                              if (await _confirm(context, 'امسح القسم "$name"؟')) {
                                try {
                                  await Backend.instance.deleteCategory(d.id);
                                } catch (e) {
                                  if (context.mounted) _snack(context, e.toString(), error: true);
                                }
                              }
                            },
                          ),
                        ],
                      ),
                    );
                  },
                ),
        );
      },
    );
  }

  Future<void> _editCategory(
      BuildContext context, QueryDocumentSnapshot<Map<String, dynamic>>? existing) async {
    final name = TextEditingController(
        text: existing == null ? '' : (existing.data()['name'] ?? '') as String);
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(existing == null ? 'قسم جديد' : 'تعديل قسم'),
        content: TextField(
          controller: name,
          decoration: const InputDecoration(labelText: 'اسم القسم'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('إلغاء')),
          FilledButton(
            onPressed: () async {
              if (name.text.trim().isEmpty) return;
              try {
                if (existing == null) {
                  await Backend.instance.addCategory(name.text.trim());
                } else {
                  await Backend.instance.renameCategory(existing.id, name.text.trim());
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
    );
  }
}

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
        return ListView.builder(
          itemCount: docs.length,
          itemBuilder: (context, i) {
            final d = docs[i];
            final data = d.data();
            final status = (data['status'] ?? 'new') as String;
            return ListTile(
              title: Text((data['customerName'] ?? '') as String),
              subtitle: Text('${data['customerPhone'] ?? ''} — ${orderStatusLabels[status] ?? status}'),
              trailing: Text('${((data['total'] ?? 0) as num).toStringAsFixed(0)} ج.م'),
              onTap: () => _orderDetail(context, d),
            );
          },
        );
      },
    );
  }

  Future<void> _orderDetail(
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('الاسم: ${data['customerName'] ?? ''}'),
                Text('الموبايل: ${data['customerPhone'] ?? ''}'),
                Text('العنوان: ${data['customerAddress'] ?? ''}'),
                const Divider(),
                for (final it in items)
                  Text('${it['name']} × ${it['qty']} = ${((it['price'] as num) * (it['qty'] as num)).toStringAsFixed(0)} ج.م'),
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
}

// ---------------- Team ----------------

class _TeamTab extends StatelessWidget {
  const _TeamTab();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: Backend.instance.teamStream(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) return _loading();
        if (snap.hasError) return _streamError(snap.error!);
        final docs = snap.data?.docs ?? [];
        return Scaffold(
          floatingActionButton: FloatingActionButton(
            onPressed: () => _addMember(context),
            child: const Icon(Icons.person_add_outlined),
          ),
          body: docs.isEmpty
              ? const Center(child: Text('مفيش أعضاء فريق لسه'))
              : ListView.builder(
                  itemCount: docs.length,
                  itemBuilder: (context, i) {
                    final data = docs[i].data();
                    return ListTile(
                      leading: const Icon(Icons.person_outlined),
                      title: Text((data['email'] ?? '') as String),
                      subtitle: Text((data['phone'] ?? '') as String),
                    );
                  },
                ),
        );
      },
    );
  }

  Future<void> _addMember(BuildContext context) async {
    final email = TextEditingController();
    final phone = TextEditingController();
    final password = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('إضافة عضو فريق'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: email, decoration: const InputDecoration(labelText: 'الإيميل')),
              TextField(controller: phone, decoration: const InputDecoration(labelText: 'رقم الموبايل')),
              TextField(
                controller: password,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'كلمة السر'),
              ),
              const SizedBox(height: 8),
              const Text(
                'العضو هيدخل من موبايله باختيار "لدي حساب بالفعل" بالإيميل أو الرقم وكلمة السر دي.',
                style: TextStyle(color: Colors.grey, fontSize: 13),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('إلغاء')),
          FilledButton(
            onPressed: () async {
              try {
                await Backend.instance.createMemberAccount(
                  email: email.text.trim(),
                  phone: phone.text.trim(),
                  password: password.text,
                );
                if (c.mounted) {
                  Navigator.pop(c);
                  _snack(c, 'تم إضافة العضو');
                }
              } catch (e) {
                if (c.mounted) _snack(c, e.toString(), error: true);
              }
            },
            child: const Text('إضافة'),
          ),
        ],
      ),
    );
  }
}

// ---------------- Settings + diagnostics ----------------

class _SettingsTab extends StatefulWidget {
  const _SettingsTab({required this.onSignedOut, this.themeController});
  final VoidCallback onSignedOut;
  final FlowThemeController? themeController;

  @override
  State<_SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<_SettingsTab> {
  String _version = '';
  final _brand = TextEditingController();
  final _tagline = TextEditingController();
  bool _brandLoaded = false;

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((info) {
      if (mounted) setState(() => _version = '${info.version} (${info.buildNumber})');
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (widget.themeController != null) ...[
          const FlowSectionHeader(title: 'شكل البرنامج'),
          FlowCard(
            child: Column(
              children: [
                for (final v in FlowThemeVariant.values)
                  ListTile(
                    key: Key('theme-${v.prefsValue}'),
                    title: Text(v.label),
                    subtitle: Text(v == FlowThemeVariant.liquidGloss
                        ? 'لمعان سائل أعمق'
                        : 'زجاج هادي فوق تدرّج'),
                    trailing: widget.themeController!.variant == v
                        ? const Icon(Icons.check_circle, color: FlowPalette.cyan)
                        : const Icon(Icons.circle_outlined,
                            color: FlowPalette.textMuted),
                    onTap: () => widget.themeController!.setVariant(v),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],
        const Text('اسم المتجر', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: Backend.instance.brandStream(),
          builder: (context, snap) {
            if (!_brandLoaded && snap.hasData && snap.data!.exists) {
              final data = snap.data!.data() ?? {};
              _brand.text = (data['brandName'] ?? '') as String;
              _tagline.text = (data['tagline'] ?? '') as String;
              _brandLoaded = true;
            }
            if (snap.hasError) return _streamError(snap.error!);
            return Column(
              children: [
                TextField(
                  controller: _brand,
                  decoration: const InputDecoration(
                    labelText: 'اسم البراند (بيظهر على الموقع فورًا)',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _tagline,
                  decoration: const InputDecoration(
                    labelText: 'سطر تعريفي (اختياري)',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () async {
                    try {
                      await Backend.instance.setBrand(
                        brandName: _brand.text.trim(),
                        tagline: _tagline.text.trim(),
                      );
                      if (context.mounted) _snack(context, 'تم حفظ اسم المتجر');
                    } catch (e) {
                      if (context.mounted) _snack(context, e.toString(), error: true);
                    }
                  },
                  child: const Text('حفظ اسم المتجر'),
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 16),
        FilledButton.tonal(
          onPressed: () async {
            try {
              final count = await Backend.instance.seedSamplesIfEmpty(
                categories: sampleCategories
                    .map((c) => {'id': c.id, 'name': c.name})
                    .toList(),
                products: sampleProducts
                    .map((p) => {
                          'name': p.name,
                          'price': p.price,
                          'description': p.description,
                          'categoryId': p.categoryId,
                        })
                    .toList(),
              );
              if (context.mounted) {
                _snack(context,
                    count == 0 ? 'الكتالوج فيه منتجات بالفعل' : 'تمت إضافة $count منتجات تجريبية');
              }
            } catch (e) {
              if (context.mounted) _snack(context, e.toString(), error: true);
            }
          },
          child: const Text('إضافة المنتجات التجريبية (لو الكتالوج فاضي)'),
        ),
        const SizedBox(height: 12),
        FilledButton.tonalIcon(
          icon: const Icon(Icons.download_outlined),
          label: const Text('تصدير نسخة احتياطية (JSON)'),
          onPressed: () async {
            try {
              final data = await Backend.instance.exportAll();
              final dir = await getTemporaryDirectory();
              final stamp = DateTime.now().toIso8601String().replaceAll(':', '-');
              final file = File('${dir.path}/store-backup-$stamp.json');
              await file.writeAsString(
                const JsonEncoder.withIndent('  ').convert(data),
              );
              final products = (data['products'] as List).length;
              final orders = (data['orders'] as List).length;
              final customers = (data['customers'] as List).length;
              await SharePlus.instance.share(ShareParams(
                files: [XFile(file.path)],
                text: 'نسخة احتياطية للمتجر: $products منتج، $orders طلب، $customers عميل',
              ));
              if (context.mounted) {
                _snack(context, 'تم تجهيز النسخة: $products منتج، $orders طلب، $customers عميل');
              }
            } catch (e) {
              if (context.mounted) _snack(context, e.toString(), error: true);
            }
          },
        ),
        const Text(
          'التصدير بيشتغل من التطبيق مباشرة (ملف JSON) — تصدير Firestore المُدار لسلة تخزين محتاج Blaze ومش طريق v1.',
          style: TextStyle(color: Colors.grey, fontSize: 13),
        ),
        const Divider(height: 32),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('سجل التشخيص', style: TextStyle(fontWeight: FontWeight.bold)),
            TextButton(
              onPressed: () => Diagnostics.instance.clear(),
              child: const Text('مسح'),
            ),
          ],
        ),
        ValueListenableBuilder<List<DiagnosticsEntry>>(
          valueListenable: Diagnostics.instance.entries,
          builder: (context, entries, _) {
            if (entries.isEmpty) return const Text('مفيش أحداث لسه');
            return Column(
              children: entries.take(30).map((e) => ListTile(title: Text(e.toString()))).toList(),
            );
          },
        ),
        const Divider(height: 32),
        if (_version.isNotEmpty) Text('نسخة البرنامج: $_version', style: const TextStyle(color: Colors.grey)),
        const SizedBox(height: 12),
        OutlinedButton(
          onPressed: () async {
            if (await _confirm(context, 'متأكد إنك عايز تسجل الخروج؟')) {
              await Backend.instance.signOut();
              widget.onSignedOut();
            }
          },
          child: const Text('تسجيل الخروج'),
        ),
      ],
    );
  }
}
