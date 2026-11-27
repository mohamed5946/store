part of 'admin_shell.dart';

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
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, StoreTokens.navPillClearance),
                    itemCount: docs.length,
                    itemBuilder: (context, i) {
                      final p = ProductData.fromDoc(docs[i]);
                      final featured = (docs[i].data()['featured'] ?? false) == true;
                      // Pricing: a live discount shows the saving and
                      // the staleness signal "خصم نشط منذ X يوم" (B5).
                      final onSale = Backend.isOnSale(
                          basePrice: p.basePrice, price: p.price);
                      final pct = onSale
                          ? Backend.salePercent(
                              basePrice: p.basePrice!,
                              price: p.price.round())
                          : null;
                      final ageDays = onSale
                          ? Backend.discountAgeDays(p.discountSetAt)
                          : null;
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
                                '${p.price.toStringAsFixed(0)} ج.م${featured ? ' — مميز' : ''}'
                                '${onSale ? ' — وفّر ${(p.basePrice! - p.price).toStringAsFixed(0)} ج.م' : ''}'
                                '${onSale && pct != null ? ' (خصم $pct٪)' : ''}'
                                '${onSale ? (ageDays != null ? ' — خصم نشط منذ $ageDays يوم' : ' — خصم نشط') : ''}'),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // Featured toggle (contract §9): the
                                // storefront lists featured products
                                // first. Audited write, one tap.
                                Pressable(
                                  onTap: () async {
                                    try {
                                      await Backend.instance
                                          .setProductFeatured(p.id, !featured);
                                    } catch (e) {
                                      if (context.mounted) {
                                        _snack(context, e.toString(),
                                            error: true);
                                      }
                                    }
                                  },
                                  child: Icon(
                                    featured ? Icons.star : Icons.star_border,
                                    color: featured
                                        ? StoreGlass.of(context).accent
                                        : null,
                                  ),
                                ),
                                const SizedBox(width: 16),
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
                                  child: Icon(Icons.delete_outline,
                                      color: StoreGlass.of(context).danger),
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
    // Pricing (Model P): "السعر (ج.م)" writes price (the effective /
    // charged price); "السعر قبل الخصم" writes basePrice (optional,
    // display-only anchor). Empty = no sale.
    final basePrice = TextEditingController(
        text: existing?.basePrice?.toString() ?? '');
    final desc = TextEditingController(text: existing?.description ?? '');
    final link = TextEditingController();
    var images = List<CloudinaryImage>.from(existing?.images ?? []);
    var categoryId = existing?.categoryId ?? '';
    var busy = false;
    var uploading = false;
    var uploadProgress = 0.0;
    var errorText = '';
    // Decision D4: set only after the admin confirms a below-cost
    // price a second time, on a separate tap.
    var belowCostConfirmed = false;
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
                    controller: basePrice,
                    keyboardType: TextInputType.number,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                        labelText: 'السعر قبل الخصم (اختياري)',
                        hintText: 'فاضي = مفيش خصم'),
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
                    Text('مفيش صور لسه', style: TextStyle(color: StoreGlass.of(c).textMuted)),
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
                                decoration: BoxDecoration(
                                  color: StoreGlass.of(c).danger,
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
                      child: Text(errorText, style: TextStyle(color: StoreGlass.of(c).danger)),
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
                    basePriceText: basePrice.text.trim().isEmpty
                        ? null
                        : basePrice.text.trim(),
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
                            categoryId.isEmpty) {
                          setState(() => errorText = 'كمّل اسم المنتج والسعر والقسم');
                          return;
                        }
                        // Pricing (§9): both prices are positive
                        // integers; basePrice == null || >= price.
                        final priceInt =
                            int.tryParse(price.text.trim());
                        if (priceInt == null) {
                          setState(() => errorText =
                              'السعر لازم يكون رقم صحيح أكبر من صفر');
                          return;
                        }
                        int? baseValue;
                        final baseRaw = basePrice.text.trim();
                        if (baseRaw.isNotEmpty) {
                          baseValue = int.tryParse(baseRaw);
                          if (baseValue == null) {
                            setState(() => errorText =
                                'السعر قبل الخصم لازم يكون رقم صحيح');
                            return;
                          }
                        }
                        final priceError =
                            Backend.validateProductPrices(
                                price: priceInt, basePrice: baseValue);
                        if (priceError != null) {
                          setState(() => errorText = priceError);
                          return;
                        }
                        // basePrice == price means NO sale (cleared,
                        // never a 0% badge).
                        if (baseValue != null && baseValue == priceInt) {
                          baseValue = null;
                        }
                        setState(() => busy = true);
                        try {
                          // Decision D4: a price below the recorded
                          // cost needs a warning + an explicit second
                          // confirmation (separate tap), recorded in
                          // the audit entry. No recorded cost = no
                          // warning (unknown cost is not below cost).
                          if (existing != null && !belowCostConfirmed) {
                            final cost = await Backend.instance
                                .productCostPrice(existing.id);
                            if (cost != null && priceInt < cost) {
                              if (!c.mounted) {
                                setState(() => busy = false);
                                return;
                              }
                              final confirmed =
                                  await showDialog<bool>(
                                context: c,
                                builder: (d) => AlertDialog(
                                  title: const Text(
                                      'الخصم ده أقل من سعر التكلفة'),
                                  content: Text(
                                      'سعر البيع ($priceInt ج.م) أقل من سعر التكلفة ($cost ج.م). لو ده خصم تصفية مقصود، أكّده بخطوة تانية.'),
                                  actions: [
                                    TextButton(
                                        onPressed: () =>
                                            Navigator.pop(d, false),
                                        child: const Text('رجوع')),
                                    FilledButton(
                                        onPressed: () =>
                                            Navigator.pop(d, true),
                                        child: const Text(
                                            'تأكيد السعر أقل من التكلفة')),
                                  ],
                                ),
                              );
                              if (confirmed != true) {
                                setState(() => busy = false);
                                return;
                              }
                              setState(
                                  () => belowCostConfirmed = true);
                            }
                          }
                          await Backend.instance.saveProduct(
                            ProductData(
                              id: existing?.id ?? '',
                              name: name.text.trim(),
                              price: priceInt.toDouble(),
                              description: desc.text.trim(),
                              categoryId: categoryId,
                              images: images,
                              basePrice: baseValue,
                              discountSetAt: existing?.discountSetAt,
                            ),
                            belowCostConfirmed: belowCostConfirmed,
                          );
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

  Widget _fallback() {
    final tokens = StoreGlassTokens.liquidGloss;
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        gradient: StoreGlassTokens.brandGradient,
        borderRadius: BorderRadius.circular(8),
      ),
      alignment: Alignment.center,
      child: Text(
        product.name.isEmpty ? '؟' : product.name.characters.first,
        style: TextStyle(
            color: tokens.accentText, fontWeight: FontWeight.bold),
      ),
    );
  }
}
