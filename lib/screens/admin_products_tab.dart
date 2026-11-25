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
