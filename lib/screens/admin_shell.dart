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
import '../core/dashboard_stats.dart';
import '../core/diagnostics.dart';
import '../core/homepage.dart';
import '../core/sample_data.dart';
import '../core/store_update.dart';
import '../core/store_update_flow.dart';
import '../services/backend.dart';
import '../services/cloudinary.dart';
import '../screens/storefront_preview.dart';
import '../screens/updates_screen.dart';
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

  // v1.1.2: the once-per-session launch update check lives in the
  // tab shell, under the MaterialApp Navigator so it can push the
  // Software Update screen. It renders nothing and runs once per
  // shell mount (see StoreUpdateLaunchCheck).
  late final StoreUpdateFlow _updateFlow =
      StoreUpdateFlow(service: StoreUpdateService());

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
      body: Stack(
        children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            child: KeyedSubtree(key: ValueKey<int>(_tab), child: pages[_tab]),
          ),
          StoreUpdateLaunchCheck(flow: _updateFlow),
        ],
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

/// v1.1.2: every list row is a raised 3D rectangle (the shared depth
/// system: multi-layer soft shadows, top-edge highlight, bottom
/// shade) — never a flat solid tile. Tappable rows sink on press via
/// Pressable; rows whose only actions are buttons keep the raised
/// look with Pressable-sink buttons.
class _FlowRow extends StatelessWidget {
  const _FlowRow({
    this.leading,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
  });

  final Widget? leading;
  final Widget title;
  final Widget? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final content = Row(
      children: [
        if (leading != null) ...[leading!, const SizedBox(width: 12)],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              title,
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                subtitle!,
              ],
            ],
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 8), trailing!],
      ],
    );
    final card = FlowCard(child: content);
    if (onTap == null) return card;
    return Pressable(onTap: onTap, child: card);
  }
}

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

// ---------------- Products ----------------

class _ProductsTab extends StatefulWidget {
  const _ProductsTab();

  @override
  State<_ProductsTab> createState() => _ProductsTabState();
}

class _ProductsTabState extends State<_ProductsTab> {
  /// v1.1.2: the id currently playing the bin-eats-label animation
  /// (set AFTER the confirmation dialog, cleared when the delete
  /// completes). Never delete on swipe alone — confirmation first,
  /// animation second, actual delete last.
  String? _deletingId;

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
              : StaggeredScope(
                  child: ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: docs.length,
                    itemBuilder: (context, i) {
                      final p = ProductData.fromDoc(docs[i]);
                      if (_deletingId == p.id) {
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Center(
                            child: BinEatingDeleteButton(
                              label: p.name,
                              autoplay: true,
                              onConfirmed: () async {
                                try {
                                  await Backend.instance.deleteProduct(p.id);
                                } catch (e) {
                                  if (context.mounted) {
                                    _snack(context, e.toString(), error: true);
                                  }
                                } finally {
                                  if (mounted) {
                                    setState(() => _deletingId = null);
                                  }
                                }
                              },
                            ),
                          ),
                        );
                      }
                      return StaggeredItem(
                        index: i,
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: _FlowRow(
                            leading: _ProductThumb(product: p),
                            title: Text(p.name),
                            subtitle: Text(
                                '${p.price.toStringAsFixed(0)} ج.م'),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Pressable(
                                  onTap: () => _editProduct(context, p),
                                  child: const Icon(Icons.edit_outlined),
                                ),
                                const SizedBox(width: 16),
                                Pressable(
                                  onTap: () async {
                                    if (await _confirm(context,
                                        'امسح المنتج "${p.name}"؟')) {
                                      if (mounted) {
                                        setState(() => _deletingId = p.id);
                                      }
                                    }
                                  },
                                  child: const Icon(Icons.delete_outline,
                                      color: Colors.red),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
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
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(labelText: 'اسم المنتج')),
                  TextField(
                    controller: price,
                    keyboardType: TextInputType.number,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(labelText: 'السعر (ج.م)'),
                  ),
                  TextField(
                      controller: desc,
                      onChanged: (_) => setState(() {}),
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
                  // v1.1.2: live storefront card preview — updates as
                  // he types, writes nothing until Save is tapped.
                  const SizedBox(height: 16),
                  const Align(
                    alignment: Alignment.centerRight,
                    child: Text('معاينة كارت المنتج على الموقع',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                  const SizedBox(height: 8),
                  StorefrontProductCardPreview(
                    name: name.text,
                    priceText: price.text.trim().isEmpty
                        ? '0'
                        : (double.tryParse(price.text.trim())
                                ?.toStringAsFixed(0) ??
                            price.text.trim()),
                    imageUrl: images.isEmpty ? null : images.first.url,
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

class _CategoriesTab extends StatefulWidget {
  const _CategoriesTab();

  @override
  State<_CategoriesTab> createState() => _CategoriesTabState();
}

class _CategoriesTabState extends State<_CategoriesTab> {
  /// v1.1.2: id playing the bin-eats-label animation (set AFTER the
  /// confirmation dialog, cleared when the delete completes).
  String? _deletingId;

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
              : StaggeredScope(
                  child: ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: docs.length,
                    itemBuilder: (context, i) {
                      final d = docs[i];
                      final name = (d.data()['name'] ?? '') as String;
                      if (_deletingId == d.id) {
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Center(
                            child: BinEatingDeleteButton(
                              label: name,
                              autoplay: true,
                              onConfirmed: () async {
                                try {
                                  await Backend.instance.deleteCategory(d.id);
                                } catch (e) {
                                  if (context.mounted) {
                                    _snack(context, e.toString(), error: true);
                                  }
                                } finally {
                                  if (mounted) {
                                    setState(() => _deletingId = null);
                                  }
                                }
                              },
                            ),
                          ),
                        );
                      }
                      return StaggeredItem(
                        index: i,
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: _FlowRow(
                            title: Text(name),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Pressable(
                                  onTap: () => _editCategory(context, d),
                                  child: const Icon(Icons.edit_outlined),
                                ),
                                const SizedBox(width: 16),
                                Pressable(
                                  onTap: () async {
                                    if (await _confirm(
                                        context, 'امسح القسم "$name"؟')) {
                                      if (mounted) {
                                        setState(() => _deletingId = d.id);
                                      }
                                    }
                                  },
                                  child: const Icon(Icons.delete_outline,
                                      color: Colors.red),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
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

// ---------------- Team ----------------

class _TeamTab extends StatefulWidget {
  const _TeamTab();

  @override
  State<_TeamTab> createState() => _TeamTabState();
}

class _TeamTabState extends State<_TeamTab> {
  /// v1.1.2: id playing the bin-eats-label animation (set AFTER the
  /// confirmation dialog, cleared when the removal completes).
  String? _deletingId;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: Backend.instance.teamStream(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) return _loading();
        if (snap.hasError) return _streamError(snap.error!);
        final docs = snap.data?.docs ?? [];
        final selfUid = Backend.instance.auth.currentUser?.uid;
        return Scaffold(
          floatingActionButton: FloatingActionButton(
            onPressed: () => _addMember(context),
            child: const Icon(Icons.person_add_outlined),
          ),
          body: docs.isEmpty
              ? const Center(child: Text('مفيش أعضاء فريق لسه'))
              : StaggeredScope(
                  child: ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: docs.length,
                    itemBuilder: (context, i) {
                      final doc = docs[i];
                      final data = doc.data();
                      final email = (data['email'] ?? '') as String;
                      if (_deletingId == doc.id) {
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Center(
                            child: BinEatingDeleteButton(
                              label: email,
                              autoplay: true,
                              onConfirmed: () async {
                                try {
                                  await Backend.instance
                                      .removeTeamMember(doc.id);
                                  if (context.mounted) {
                                    _snack(context, 'تم إزالة العضو من الفريق');
                                  }
                                } catch (e) {
                                  if (context.mounted) {
                                    _snack(context, e.toString(), error: true);
                                  }
                                } finally {
                                  if (mounted) {
                                    setState(() => _deletingId = null);
                                  }
                                }
                              },
                            ),
                          ),
                        );
                      }
                      return StaggeredItem(
                        index: i,
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: _FlowRow(
                            leading: const Icon(Icons.person_outlined),
                            title: Text(email),
                            subtitle: Text((data['phone'] ?? '') as String),
                            trailing: doc.id == selfUid
                                ? null
                                : Pressable(
                                    onTap: () async {
                                      if (await _confirm(context,
                                          'تشيل "$email" من الفريق؟')) {
                                        if (mounted) {
                                          setState(
                                              () => _deletingId = doc.id);
                                        }
                                      }
                                    },
                                    child: const Icon(Icons.delete_outline,
                                        color: Colors.red),
                                  ),
                          ),
                        ),
                      );
                    },
                  ),
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

  /// Last SAVED values (from Firestore). Cancel restores these;
  /// typing only changes the draft — nothing writes until Save.
  String _savedBrand = '';
  String _savedTagline = '';

  // v1.1.2 scope #8: homepage editor draft (storeSettings/homepage).
  // Same pattern as brand: the draft lives only in state, the
  // preview renders it live, Save writes the full doc, Cancel
  // restores the last-saved values. Nothing writes before Save.
  bool _homepageLoaded = false;
  List<String> _heroIds = [];
  List<Map<String, dynamic>> _banners = [];
  String _featuredId = '';
  final _deliveryTitle = TextEditingController();
  final _deliverySubtitle = TextEditingController();
  String _deliveryImage = '';
  bool _deliveryUploading = false;
  double _deliveryProgress = 0.0;
  String _savedFeaturedId = '';
  List<String> _savedHeroIds = [];
  List<Map<String, dynamic>> _savedBanners = [];
  String _savedDeliveryTitle = '';
  String _savedDeliverySubtitle = '';
  String _savedDeliveryImage = '';

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((info) {
      if (mounted) setState(() => _version = '${info.version} (${info.buildNumber})');
    });
  }

  @override
  Widget build(BuildContext context) {
    return StaggeredScope(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (widget.themeController != null) ...[
            const StaggeredItem(
              index: 0,
              child: FlowSectionHeader(title: 'شكل البرنامج'),
            ),
            StaggeredItem(
              index: 1,
              child: FlowCard(
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
            ),
            const SizedBox(height: 16),
          ],
          const StaggeredItem(
            index: 2,
            child: Text('اسم المتجر', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          const SizedBox(height: 8),
        StaggeredItem(
          index: 3,
          child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
            stream: Backend.instance.brandStream(),
            builder: (context, snap) {
              if (!_brandLoaded && snap.hasData && snap.data!.exists) {
                final data = snap.data!.data() ?? {};
                _savedBrand = (data['brandName'] ?? '') as String;
                _savedTagline = (data['tagline'] ?? '') as String;
                _brand.text = _savedBrand;
                _tagline.text = _savedTagline;
                _brandLoaded = true;
              }
              if (snap.hasError) return _streamError(snap.error!);
              return Column(
                children: [
                  TextField(
                    controller: _brand,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      labelText: 'اسم البراند (بيظهر على الموقع فورًا)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _tagline,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      labelText: 'سطر تعريفي (اختياري)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // v1.1.2: live storefront header preview — updates
                  // as he types, writes nothing until Save is tapped.
                  StorefrontHeaderPreview(
                    brandName: _brand.text,
                    tagline: _tagline.text,
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton(
                          onPressed: () async {
                            try {
                              await Backend.instance.setBrand(
                                brandName: _brand.text.trim(),
                                tagline: _tagline.text.trim(),
                              );
                              if (context.mounted) {
                                setState(() {
                                  _savedBrand = _brand.text.trim();
                                  _savedTagline = _tagline.text.trim();
                                });
                                _snack(context, 'تم حفظ اسم المتجر');
                              }
                            } catch (e) {
                              if (context.mounted) {
                                _snack(context, e.toString(), error: true);
                              }
                            }
                          },
                          child: const Text('حفظ اسم المتجر'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      OutlinedButton(
                        onPressed: () => setState(() {
                          _brand.text = _savedBrand;
                          _tagline.text = _savedTagline;
                        }),
                        child: const Text('إلغاء'),
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
        const SizedBox(height: 16),
        StaggeredItem(
          index: 4,
          child: _homepageSection(),
        ),
        const SizedBox(height: 16),
        StaggeredItem(
          index: 5,
          child: FilledButton.tonal(
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
        ),
        const SizedBox(height: 12),
        StaggeredItem(
          index: 6,
          child: FilledButton.tonalIcon(
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
        ),
        const Text(
          'التصدير بيشتغل من التطبيق مباشرة (ملف JSON) — تصدير Firestore المُدار لسلة تخزين محتاج Blaze ومش طريق v1.',
          style: TextStyle(color: Colors.grey, fontSize: 13),
        ),
        const SizedBox(height: 12),
        // v1.1.2: Updates row, exactly like the sibling rows.
        const StaggeredItem(index: 7, child: UpdatesSettingsRow()),
        const Divider(height: 32),
        StaggeredItem(
          index: 8,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('سجل التشخيص', style: TextStyle(fontWeight: FontWeight.bold)),
              TextButton(
                onPressed: () => Diagnostics.instance.clear(),
                child: const Text('مسح'),
              ),
            ],
          ),
        ),
        ValueListenableBuilder<List<DiagnosticsEntry>>(
          valueListenable: Diagnostics.instance.entries,
          builder: (context, entries, _) {
            if (entries.isEmpty) return const Text('مفيش أحداث لسه');
            return Column(
              children: entries.take(30).map((e) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _FlowRow(title: Text(e.toString())),
                  )).toList(),
            );
          },
        ),
        const Divider(height: 32),
        if (_version.isNotEmpty) Text('نسخة البرنامج: $_version', style: const TextStyle(color: Colors.grey)),
        const SizedBox(height: 12),
        StaggeredItem(
          index: 9,
          child: OutlinedButton(
            onPressed: () async {
              if (await _confirm(context, 'متأكد إنك عايز تسجل الخروج؟')) {
                await Backend.instance.signOut();
                widget.onSignedOut();
              }
            },
            child: const Text('تسجيل الخروج'),
          ),
        ),
      ],
      ),
    );
  }

  // ---------------- v1.1.2 scope #8: homepage editor ----------------
  //
  // Edits storeSettings/homepage (the website builder's contract doc).
  // The draft lives only in this state: the preview renders it live,
  // Save writes the full doc via buildHomepageDoc, Cancel restores
  // the last-saved values. Nothing writes before Save.

  void _loadHomepage(Map<String, dynamic>? data) {
    final parsed = parseHomepageDoc(data);
    _savedHeroIds =
        List<String>.from(parsed['heroProductIds'] as List<dynamic>);
    _savedBanners = (parsed['promoBanners'] as List<dynamic>)
        .map((b) => Map<String, dynamic>.from(b as Map<String, dynamic>))
        .toList();
    _savedFeaturedId = parsed['featuredProductId'] as String;
    final delivery = parsed['deliveryBanner'] as Map<String, dynamic>;
    _savedDeliveryTitle = delivery['title'] as String;
    _savedDeliverySubtitle = delivery['subtitle'] as String;
    _savedDeliveryImage = delivery['imageUrl'] as String;
    _heroIds = List<String>.from(_savedHeroIds);
    _banners = _savedBanners
        .map((b) => Map<String, dynamic>.from(b))
        .toList();
    _featuredId = _savedFeaturedId;
    _deliveryTitle.text = _savedDeliveryTitle;
    _deliverySubtitle.text = _savedDeliverySubtitle;
    _deliveryImage = _savedDeliveryImage;
    _homepageLoaded = true;
  }

  void _cancelHomepage() {
    setState(() {
      _heroIds = List<String>.from(_savedHeroIds);
      _banners =
          _savedBanners.map((b) => Map<String, dynamic>.from(b)).toList();
      _featuredId = _savedFeaturedId;
      _deliveryTitle.text = _savedDeliveryTitle;
      _deliverySubtitle.text = _savedDeliverySubtitle;
      _deliveryImage = _savedDeliveryImage;
    });
  }

  Future<void> _saveHomepage() async {
    try {
      final doc = buildHomepageDoc(
        heroProductIds: _heroIds,
        promoBanners: _banners,
        featuredProductId: _featuredId,
        deliveryBanner: <String, dynamic>{
          'title': _deliveryTitle.text.trim(),
          'subtitle': _deliverySubtitle.text.trim(),
          'imageUrl': _deliveryImage,
        },
      );
      await Backend.instance.setHomepage(doc);
      if (mounted) {
        setState(() {
          _savedHeroIds = List<String>.from(_heroIds);
          _savedBanners =
              _banners.map((b) => Map<String, dynamic>.from(b)).toList();
          _savedFeaturedId = _featuredId;
          _savedDeliveryTitle = _deliveryTitle.text.trim();
          _savedDeliverySubtitle = _deliverySubtitle.text.trim();
          _savedDeliveryImage = _deliveryImage;
        });
        _snack(context, 'تم حفظ واجهة الموقع');
      }
    } catch (e) {
      if (mounted) _snack(context, e.toString(), error: true);
    }
  }

  Widget _homepageSection() {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: Backend.instance.homepageStream(),
      builder: (context, snap) {
        if (!_homepageLoaded && snap.hasData) {
          _loadHomepage(snap.data!.data());
        }
        if (snap.hasError) return _streamError(snap.error!);
        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: Backend.instance.productsStream(),
          builder: (context, productsSnap) {
            final products = (productsSnap.data?.docs ?? [])
                .map(ProductData.fromDoc)
                .toList();
            final byId = {for (final p in products) p.id: p};
            return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: Backend.instance.categoriesStream(),
              builder: (context, catsSnap) {
                final categories = (catsSnap.data?.docs ?? [])
                    .map((d) => <String, String>{
                          'id': d.id,
                          'name': (d.data()['name'] ?? '') as String,
                        })
                    .toList();
                String productName(String id) => byId[id]?.name ?? id;
                String productImage(String id) =>
                    byId[id]?.images.isNotEmpty == true
                        ? byId[id]!.images.first.url
                        : '';
                String linkLabel(Map<String, dynamic> b) {
                  final type = b['linkType'] as String;
                  final linkId = b['linkId'] as String;
                  if (type == 'category') {
                    final cat = categories.firstWhere(
                      (c) => c['id'] == linkId,
                      orElse: () => {'name': linkId},
                    );
                    return 'قسم: ${cat['name']}';
                  }
                  if (type == 'product') return 'منتج: ${productName(linkId)}';
                  return 'من غير رابط';
                }

                final heroDisplay = _heroIds
                    .map((id) => <String, String>{
                          'name': productName(id),
                          'imageUrl': productImage(id),
                        })
                    .toList();
                final featuredDisplay = _featuredId.isEmpty
                    ? null
                    : <String, String>{
                        'name': productName(_featuredId),
                        'imageUrl': productImage(_featuredId),
                      };
                var addHeroId = '';
                final addable = products
                    .where((p) => !_heroIds.contains(p.id))
                    .toList();
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('واجهة الموقع',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    const Text(
                      'منتجات الواجهة (لحد 4، بالترتيب)',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    if (_heroIds.isEmpty)
                      const Text('مفيش منتجات في الواجهة لسه',
                          style: TextStyle(color: Colors.grey)),
                    for (var k = 0; k < _heroIds.length; k++)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _FlowRow(
                          title: Text('${k + 1}. ${productName(_heroIds[k])}'),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Pressable(
                                onTap: k == 0
                                    ? null
                                    : () => setState(() {
                                          final id = _heroIds.removeAt(k);
                                          _heroIds.insert(k - 1, id);
                                        }),
                                child: const Icon(Icons.arrow_upward, size: 20),
                              ),
                              const SizedBox(width: 12),
                              Pressable(
                                onTap: k == _heroIds.length - 1
                                    ? null
                                    : () => setState(() {
                                          final id = _heroIds.removeAt(k);
                                          _heroIds.insert(k + 1, id);
                                        }),
                                child:
                                    const Icon(Icons.arrow_downward, size: 20),
                              ),
                              const SizedBox(width: 12),
                              Pressable(
                                onTap: () => setState(
                                    () => _heroIds.removeAt(k)),
                                child: const Icon(Icons.delete_outline,
                                    color: Colors.red, size: 20),
                              ),
                            ],
                          ),
                        ),
                      ),
                    if (_heroIds.length >= maxHeroProducts)
                      const Text('وصلت للحد الأقصى (4 منتجات)',
                          style: TextStyle(color: Colors.grey, fontSize: 13))
                    else if (addable.isNotEmpty)
                      Row(
                        children: [
                          Expanded(
                            child: DropdownButtonFormField<String>(
                              initialValue: null,
                              items: addable
                                  .map((p) => DropdownMenuItem(
                                        value: p.id,
                                        child: Text(p.name),
                                      ))
                                  .toList(),
                              onChanged: (v) => addHeroId = v ?? '',
                              decoration: const InputDecoration(
                                  labelText: 'ضيف منتج للواجهة'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(
                            onPressed: () {
                              if (addHeroId.isEmpty) return;
                              setState(() => _heroIds.add(addHeroId));
                            },
                            child: const Text('إضافة'),
                          ),
                        ],
                      ),
                    const SizedBox(height: 16),
                    const Text('المنتج المميز',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      initialValue: _featuredId,
                      items: [
                        const DropdownMenuItem(
                            value: '', child: Text('مفيش منتج مميز')),
                        for (final p in products)
                          DropdownMenuItem(value: p.id, child: Text(p.name)),
                      ],
                      onChanged: (v) =>
                          setState(() => _featuredId = v ?? ''),
                      decoration:
                          const InputDecoration(labelText: 'المنتج المميز'),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('بانرات ترويجية',
                            style: TextStyle(fontWeight: FontWeight.bold)),
                        TextButton.icon(
                          icon: const Icon(Icons.add),
                          label: const Text('بانر جديد'),
                          onPressed: () async {
                            final created = await _editBanner(
                              context,
                              null,
                              products,
                              categories,
                            );
                            if (created != null) {
                              setState(() => _banners.add(created));
                            }
                          },
                        ),
                      ],
                    ),
                    if (_banners.isEmpty)
                      const Text('مفيش بانرات لسه',
                          style: TextStyle(color: Colors.grey)),
                    for (var k = 0; k < _banners.length; k++)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _FlowRow(
                          leading: (_banners[k]['imageUrl'] as String).isEmpty
                              ? null
                              : ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: Image.network(
                                    deliveryUrl(
                                        _banners[k]['imageUrl'] as String),
                                    width: 48,
                                    height: 48,
                                    fit: BoxFit.cover,
                                    errorBuilder: (c, e, st) => const SizedBox(
                                        width: 48,
                                        height: 48,
                                        child: Icon(
                                            Icons.broken_image_outlined)),
                                  ),
                                ),
                          title: Text((_banners[k]['title'] as String).isEmpty
                              ? 'بانر من غير عنوان'
                              : _banners[k]['title'] as String),
                          subtitle: Text(linkLabel(_banners[k])),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Pressable(
                                onTap: () async {
                                  final updated = await _editBanner(
                                    context,
                                    _banners[k],
                                    products,
                                    categories,
                                  );
                                  if (updated != null) {
                                    setState(() => _banners[k] = updated);
                                  }
                                },
                                child: const Icon(Icons.edit_outlined),
                              ),
                              const SizedBox(width: 16),
                              Pressable(
                                onTap: () async {
                                  if (await _confirm(
                                      context, 'امسح البانر ده؟')) {
                                    setState(() => _banners.removeAt(k));
                                  }
                                },
                                child: const Icon(Icons.delete_outline,
                                    color: Colors.red),
                              ),
                            ],
                          ),
                        ),
                      ),
                    const SizedBox(height: 16),
                    const Text('بانر التوصيل',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _deliveryTitle,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        labelText: 'عنوان بانر التوصيل',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _deliverySubtitle,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        labelText: 'سطر بانر التوصيل',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        if (_deliveryImage.isNotEmpty)
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.network(
                              deliveryUrl(_deliveryImage),
                              width: 72,
                              height: 72,
                              fit: BoxFit.cover,
                              errorBuilder: (c, e, st) => const SizedBox(
                                  width: 72,
                                  height: 72,
                                  child: Icon(Icons.broken_image_outlined)),
                            ),
                          ),
                        if (_deliveryImage.isNotEmpty)
                          const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            icon: const Icon(Icons.photo_outlined),
                            label: Text(_deliveryUploading
                                ? 'جارٍ الرفع… ${(_deliveryProgress * 100).toInt()}٪'
                                : 'رفع صورة بانر التوصيل'),
                            onPressed: _deliveryUploading
                                ? null
                                : () async {
                                    final picked =
                                        await ImagePicker().pickImage(
                                      source: ImageSource.gallery,
                                      maxWidth: 1200,
                                      maxHeight: 1200,
                                      imageQuality: 80,
                                    );
                                    if (picked == null) return;
                                    setState(() {
                                      _deliveryUploading = true;
                                      _deliveryProgress = 0.0;
                                    });
                                    try {
                                      final bytes =
                                          await picked.readAsBytes();
                                      final uploaded =
                                          await uploadImageToCloudinary(
                                        bytes,
                                        onProgress: (p) => setState(
                                            () => _deliveryProgress = p),
                                      );
                                      setState(() =>
                                          _deliveryImage = uploaded.url);
                                    } catch (e) {
                                      if (context.mounted) {
                                        _snack(context, e.toString(),
                                            error: true);
                                      }
                                    } finally {
                                      if (mounted) {
                                        setState(() =>
                                            _deliveryUploading = false);
                                      }
                                    }
                                  },
                          ),
                        ),
                        if (_deliveryImage.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          Pressable(
                            onTap: () =>
                                setState(() => _deliveryImage = ''),
                            child: const Icon(Icons.delete_outline,
                                color: Colors.red),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 16),
                    HomepagePreview(
                      heroProducts: heroDisplay,
                      featuredProduct: featuredDisplay,
                      promoBanners: _banners,
                      deliveryBanner: <String, String>{
                        'title': _deliveryTitle.text,
                        'subtitle': _deliverySubtitle.text,
                        'imageUrl': _deliveryImage,
                      },
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton(
                            onPressed: _saveHomepage,
                            child: const Text('حفظ واجهة الموقع'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        OutlinedButton(
                          onPressed: _cancelHomepage,
                          child: const Text('إلغاء'),
                        ),
                      ],
                    ),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }

  /// Promo banner editor dialog. Returns the banner map, or null when
  /// cancelled. Image upload reuses the product editor's Cloudinary
  /// path (on-device compression, unsigned preset, no secrets).
  Future<Map<String, dynamic>?> _editBanner(
    BuildContext context,
    Map<String, dynamic>? existing,
    List<ProductData> products,
    List<Map<String, String>> categories,
  ) async {
    final title = TextEditingController(text: (existing?['title'] ?? '') as String);
    final subtitle =
        TextEditingController(text: (existing?['subtitle'] ?? '') as String);
    final link = TextEditingController();
    var imageUrl = (existing?['imageUrl'] ?? '') as String;
    var linkType = (existing?['linkType'] ?? 'none') as String;
    var linkId = (existing?['linkId'] ?? '') as String;
    var uploading = false;
    var uploadProgress = 0.0;
    var errorText = '';
    return showDialog<Map<String, dynamic>>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setState) {
          final targetItems = linkType == 'category'
              ? categories
                  .map((cat) => DropdownMenuItem(
                        value: cat['id']!,
                        child: Text(cat['name']!),
                      ))
                  .toList()
              : products
                  .map((p) => DropdownMenuItem(
                        value: p.id,
                        child: Text(p.name),
                      ))
                  .toList();
          return AlertDialog(
            title: Text(existing == null ? 'بانر جديد' : 'تعديل بانر'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (imageUrl.isNotEmpty)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.network(
                        deliveryUrl(imageUrl),
                        height: 120,
                        fit: BoxFit.cover,
                        errorBuilder: (c, e, st) => const SizedBox(
                            height: 120,
                            child: Icon(Icons.broken_image_outlined)),
                      ),
                    ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.photo_outlined),
                    label: Text(
                        uploading ? 'جارٍ الرفع…' : 'رفع صورة من الموبايل'),
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
                                onProgress: (p) =>
                                    setState(() => uploadProgress = p),
                              );
                              setState(() => imageUrl = uploaded.url);
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
                            imageUrl = url;
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
                      child: Text(errorText,
                          style: const TextStyle(color: Colors.red)),
                    ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: title,
                    decoration:
                        const InputDecoration(labelText: 'عنوان البانر'),
                  ),
                  TextField(
                    controller: subtitle,
                    decoration:
                        const InputDecoration(labelText: 'سطر البانر'),
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    initialValue: linkType,
                    items: const [
                      DropdownMenuItem(
                          value: 'none', child: Text('من غير رابط')),
                      DropdownMenuItem(
                          value: 'category', child: Text('قسم')),
                      DropdownMenuItem(
                          value: 'product', child: Text('منتج')),
                    ],
                    onChanged: (v) => setState(() {
                      linkType = v ?? 'none';
                      linkId = '';
                    }),
                    decoration: const InputDecoration(labelText: 'نوع الرابط'),
                  ),
                  if (linkType != 'none') ...[
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      initialValue:
                          targetItems.any((i) => i.value == linkId)
                              ? linkId
                              : null,
                      items: targetItems,
                      onChanged: (v) => setState(() => linkId = v ?? ''),
                      decoration:
                          const InputDecoration(labelText: 'الوجهة'),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(c),
                  child: const Text('إلغاء')),
              FilledButton(
                onPressed: () => Navigator.pop(
                    c,
                    promoBannerMap(
                      imageUrl: imageUrl,
                      title: title.text.trim(),
                      subtitle: subtitle.text.trim(),
                      linkType: linkType,
                      linkId: linkId,
                    )),
                child: const Text('تم'),
              ),
            ],
          );
        },
      ),
    );
  }
}
