part of 'admin_shell.dart';

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
  String? _role;
  final _brand = TextEditingController();
  final _tagline = TextEditingController();
  bool _brandLoaded = false;

  /// Last SAVED values (from Firestore). Cancel restores these;
  /// typing only changes the draft — nothing writes until Save.
  String _savedBrand = '';
  String _savedTagline = '';

  // WhatsApp-order settings (contract §7/§9): the toggle + number
  // on storeSettings/settings. Same draft pattern as brand: nothing
  // writes until Save; Cancel restores the last-saved values.
  bool _whatsappLoaded = false;
  bool _whatsappEnabled = false;
  final _whatsappNumber = TextEditingController();
  bool _savedWhatsappEnabled = false;
  String _savedWhatsappNumber = Backend.defaultWhatsAppNumber;

  // Delivery fee (pricing, Technical Plan §2/§9 + decision D3):
  // one fixed fee for all orders + the admin-set free-delivery
  // threshold, both on storeSettings/settings. Same draft pattern
  // as brand/WhatsApp: nothing writes until Save; Cancel restores
  // the last-saved values. Fee-default-free (decision 2026-11-27):
  // an unset fee means delivery is free — the tab says so, with
  // no blocking language.
  bool _feeLoaded = false;
  final _fee = TextEditingController();
  final _feeThreshold = TextEditingController();
  int? _savedFee;
  int? _savedThreshold;

  @override
  void dispose() {
    _brand.dispose();
    _tagline.dispose();
    _heroTitle.dispose();
    _heroAccent.dispose();
    _heroSubtitle.dispose();
    _deliveryTitle.dispose();
    _deliverySubtitle.dispose();
    _whatsappNumber.dispose();
    _fee.dispose();
    _feeThreshold.dispose();
    super.dispose();
  }

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
  // The four storefront hero overrides (storeSettings/homepage).
  // Saved-only, no draft and no editor UI yet — the storefront
  // contract says the editor for these is a future build. They are
  // carried from load to save so an editor save round-trips them
  // instead of wiping them (Decision 27).
  String _savedHeroImageUrl = '';
  String _savedHeroTitle = '';
  String _savedHeroAccent = '';
  String _savedHeroSubtitle = '';

  // M42: the homepage hero fields ARE editable here — but only
  // while classic is live. When the pointer names a non-classic
  // template the bundle hero wins and these fields are greyed out
  // with the note "controlled by the active template". They are
  // NOT migrated or deleted: classic still renders them.
  final _heroTitle = TextEditingController();
  final _heroAccent = TextEditingController();
  final _heroSubtitle = TextEditingController();

  // Diagnostics viewer: how many entries are shown (30 at a time;
  // "show more" adds another 30). Reset when the log is cleared.
  int _diagnosticsShown = 30;

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((info) {
      if (mounted) setState(() => _version = '${info.version} (${info.buildNumber})');
    });
    Backend.instance.currentUserRole().then((r) {
      if (mounted) setState(() => _role = r);
    });
  }

  @override
  Widget build(BuildContext context) {
    final tokens = StoreGlass.of(context);
    return StaggeredScope(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, StoreTokens.navPillClearance),
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
                            ? 'زجاج سائل كامل — لمعان وحركة'
                            : 'زجاج هادي — نفس الألوان من غير حركة'),
                        trailing: widget.themeController!.variant == v
                            ? Icon(Icons.check_circle, color: tokens.accent)
                            : Icon(Icons.circle_outlined,
                                color: tokens.textMuted),
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
          child: _whatsappSection(),
        ),
        const SizedBox(height: 16),
        StaggeredItem(
          index: 5,
          child: _deliveryFeeSection(),
        ),
        const SizedBox(height: 16),
        StaggeredItem(
          index: 6,
          child: _homepageSection(),
        ),
        const SizedBox(height: 16),
        StaggeredItem(
          index: 7,
          child: _templatePointerSection(),
        ),
        const SizedBox(height: 16),
        StaggeredItem(
          index: 8,
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
          index: 9,
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
        Text(
          'التصدير بيشتغل من التطبيق مباشرة (ملف JSON) — تصدير Firestore المُدار لسلة تخزين محتاج Blaze ومش طريق v1.',
          style: TextStyle(color: tokens.textMuted, fontSize: 13),
        ),
        const SizedBox(height: 12),
        // v1.1.2: Updates row, exactly like the sibling rows.
        const StaggeredItem(index: 10, child: UpdatesSettingsRow()),
        const SizedBox(height: 16),
        // Incomplete orders (2026-11-27): governorate activation,
        // scheduled draft deletion, and the quota meter — each its
        // own section with the same draft pattern (typing only,
        // explicit save, merge-only).
        const StaggeredItem(
          index: 10,
          child: FlowSectionHeader(title: 'مناطق التوصيل (المحافظات)'),
        ),
        const StaggeredItem(index: 12, child: _GovernoratesSettings()),
        const SizedBox(height: 16),
        const StaggeredItem(
          index: 12,
          child: FlowSectionHeader(title: 'حذف الطلبات الناقصة تلقائياً'),
        ),
        const StaggeredItem(index: 14, child: _DeletionSettings()),
        const SizedBox(height: 16),
        const StaggeredItem(
          index: 14,
          child: FlowSectionHeader(title: 'استهلاك الكتابة (الحصة)'),
        ),
        const StaggeredItem(index: 16, child: _QuotaSettings()),
        const SizedBox(height: 16),
        const Divider(height: 32),
        StaggeredItem(
          index: 17,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('سجل التشخيص', style: TextStyle(fontWeight: FontWeight.bold)),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton(
                    onPressed: () async {
                      try {
                        final dir = await getTemporaryDirectory();
                        final stamp = DateTime.now()
                            .toIso8601String()
                            .replaceAll(':', '-');
                        final file =
                            File('${dir.path}/store-diagnostics-$stamp.txt');
                        await file.writeAsString(
                            Diagnostics.instance.exportText());
                        await SharePlus.instance.share(ShareParams(
                          files: [XFile(file.path)],
                          text: 'سجل تشخيص إدارة المتجر',
                        ));
                      } catch (e) {
                        if (context.mounted) {
                          _snack(context, e.toString(), error: true);
                        }
                      }
                    },
                    child: const Text('تصدير'),
                  ),
                  TextButton(
                    onPressed: () {
                      Diagnostics.instance.clear();
                      setState(() => _diagnosticsShown = 30);
                    },
                    child: const Text('مسح'),
                  ),
                ],
              ),
            ],
          ),
        ),
        ValueListenableBuilder<List<DiagnosticsEntry>>(
          valueListenable: Diagnostics.instance.entries,
          builder: (context, entries, _) {
            if (entries.isEmpty) return const Text('مفيش أحداث لسه');
            final shown = entries.take(_diagnosticsShown).toList();
            final remaining = entries.length - shown.length;
            return Column(
              children: [
                ...shown.map((e) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _FlowRow(title: Text(e.toString())),
                    )),
                if (remaining > 0)
                  TextButton(
                    onPressed: () => setState(
                        () => _diagnosticsShown += 30),
                    child: Text('عرض المزيد ($remaining متبقية)'),
                  ),
              ],
            );
          },
        ),
        const Divider(height: 32),
        if (_version.isNotEmpty)
          Text('نسخة البرنامج: $_version',
              style: TextStyle(color: tokens.textMuted)),
        const SizedBox(height: 12),
        StaggeredItem(
          index: 18,
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

  // ---------------- WhatsApp order (contract §7/§9) ----------------
  //
  // The toggle + number the storefront reads at boot
  // (storeSettings/settings). Draft pattern like brand: typing only
  // changes state, Save writes via auditedWrite, Cancel restores
  // the last-saved values.

  Widget _whatsappSection() {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: Backend.instance.brandStream(),
      builder: (context, snap) {
        if (!_whatsappLoaded && snap.hasData && snap.data!.exists) {
          final parsed =
              Backend.parseWhatsAppSettings(snap.data!.data());
          _savedWhatsappEnabled = parsed.enabled;
          _savedWhatsappNumber = parsed.number;
          _whatsappEnabled = parsed.enabled;
          _whatsappNumber.text = parsed.number;
          _whatsappLoaded = true;
        }
        if (snap.hasError) return _streamError(snap.error!);
        return FlowCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('الطلب عبر واتساب',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              SwitchListTile(
                title: const Text('تفعيل الطلب عبر واتساب'),
                subtitle: const Text(
                    'بيظهر زر واتساب في خطوة المراجعة على الموقع'),
                value: _whatsappEnabled,
                onChanged: (v) => setState(() => _whatsappEnabled = v),
              ),
              TextField(
                controller: _whatsappNumber,
                keyboardType: TextInputType.phone,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: 'رقم الواتساب (بكود الدولة)',
                  hintText: '201557887719',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      onPressed: () async {
                        try {
                          await Backend.instance.setWhatsAppOrder(
                            enabled: _whatsappEnabled,
                            number: _whatsappNumber.text,
                          );
                          if (context.mounted) {
                            setState(() {
                              _savedWhatsappEnabled = _whatsappEnabled;
                              _savedWhatsappNumber =
                                  _whatsappNumber.text.trim();
                            });
                            _snack(context, 'تم حفظ إعدادات واتساب');
                          }
                        } catch (e) {
                          if (context.mounted) {
                            _snack(context, e.toString(), error: true);
                          }
                        }
                      },
                      child: const Text('حفظ إعدادات واتساب'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton(
                    onPressed: () => setState(() {
                      _whatsappEnabled = _savedWhatsappEnabled;
                      _whatsappNumber.text = _savedWhatsappNumber;
                    }),
                    child: const Text('إلغاء'),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  // Delivery fee + free-delivery threshold (pricing, Technical
  // Plan §2/§9 + decision D3) on storeSettings/settings. Draft
  // pattern like WhatsApp: typing only changes state, Save writes
  // via Backend.setDeliveryFee, Cancel restores the last-saved
  // values. Fee-default-free (decision 2026-11-27): while no fee
  // is set the tab shows delivery as free, never as blocked.
  Widget _deliveryFeeSection() {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: Backend.instance.brandStream(),
      builder: (context, snap) {
        if (!_feeLoaded && snap.hasData && snap.data!.exists) {
          final parsed = Backend.parseDeliveryFeeSettings(
              snap.data!.data());
          _savedFee = parsed.deliveryFee;
          _savedThreshold = parsed.freeDeliveryThreshold;
          _fee.text =
              parsed.deliveryFee == null ? '' : '${parsed.deliveryFee}';
          _feeThreshold.text = parsed.freeDeliveryThreshold == null
              ? ''
              : '${parsed.freeDeliveryThreshold}';
          _feeLoaded = true;
        }
        if (snap.hasError) return _streamError(snap.error!);
        final feeUnset = _feeLoaded && _savedFee == null;
        return FlowCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('رسوم التوصيل',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              if (feeUnset)
                Container(
                  margin: const EdgeInsets.only(top: 8),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: StoreGlass.of(context)
                        .success
                        .withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text(
                    'رسوم التوصيل غير محددة — التوصيل مجاني حالياً.',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              const SizedBox(height: 12),
              TextField(
                controller: _fee,
                keyboardType: TextInputType.number,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: 'رسوم التوصيل (ج.م)',
                  hintText: 'مثال: 30 — فاضي أو صفر يعني التوصيل مجاني',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _feeThreshold,
                keyboardType: TextInputType.number,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: 'حد التوصيل المجاني (اختياري)',
                  hintText: 'فاضي = مفيش حد — فوق المبلغ ده التوصيل مجاني',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      onPressed: () async {
                        final fee = int.tryParse(_fee.text.trim());
                        if (fee == null || fee < 0) {
                          _snack(context,
                              'رسوم التوصيل لازم تكون رقم صحيح صفر أو أكتر',
                              error: true);
                          return;
                        }
                        int? threshold;
                        final thresholdRaw = _feeThreshold.text.trim();
                        if (thresholdRaw.isNotEmpty) {
                          threshold = int.tryParse(thresholdRaw);
                          if (threshold == null || threshold < 0) {
                            _snack(context,
                                'حد التوصيل المجاني لازم يكون رقم صحيح صفر أو أكتر',
                                error: true);
                            return;
                          }
                        }
                        try {
                          await Backend.instance.setDeliveryFee(
                            deliveryFee: fee,
                            freeDeliveryThreshold: threshold,
                          );
                          if (context.mounted) {
                            setState(() {
                              _savedFee = fee;
                              _savedThreshold = threshold;
                            });
                            _snack(context, 'تم حفظ رسوم التوصيل');
                          }
                        } catch (e) {
                          if (context.mounted) {
                            _snack(context, e.toString(), error: true);
                          }
                        }
                      },
                      child: const Text('حفظ رسوم التوصيل'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton(
                    onPressed: () => setState(() {
                      _fee.text =
                          _savedFee == null ? '' : '$_savedFee';
                      _feeThreshold.text = _savedThreshold == null
                          ? ''
                          : '$_savedThreshold';
                    }),
                    child: const Text('إلغاء'),
                  ),
                ],
              ),
            ],
          ),
        );
      },
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
    _savedHeroImageUrl = parsed['heroImageUrl'] as String;
    _savedHeroTitle = parsed['heroTitle'] as String;
    _savedHeroAccent = parsed['heroAccent'] as String;
    _savedHeroSubtitle = parsed['heroSubtitle'] as String;
    _heroIds = List<String>.from(_savedHeroIds);
    _banners = _savedBanners
        .map((b) => Map<String, dynamic>.from(b))
        .toList();
    _featuredId = _savedFeaturedId;
    _deliveryTitle.text = _savedDeliveryTitle;
    _deliverySubtitle.text = _savedDeliverySubtitle;
    _deliveryImage = _savedDeliveryImage;
    _heroTitle.text = _savedHeroTitle;
    _heroAccent.text = _savedHeroAccent;
    _heroSubtitle.text = _savedHeroSubtitle;
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
      _heroTitle.text = _savedHeroTitle;
      _heroAccent.text = _savedHeroAccent;
      _heroSubtitle.text = _savedHeroSubtitle;
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
        // M42: the hero fields ARE editable here while classic is
        // live (the fields are greyed out under any other template,
        // so their values cannot change then). heroImageUrl still
        // has no editor — it round-trips unchanged.
        heroImageUrl: _savedHeroImageUrl,
        heroTitle: _heroTitle.text.trim(),
        heroAccent: _heroAccent.text.trim(),
        heroSubtitle: _heroSubtitle.text.trim(),
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
          _savedHeroTitle = _heroTitle.text.trim();
          _savedHeroAccent = _heroAccent.text.trim();
          _savedHeroSubtitle = _heroSubtitle.text.trim();
        });
        _snack(context, 'تم حفظ واجهة الموقع');
      }
    } catch (e) {
      if (mounted) _snack(context, e.toString(), error: true);
    }
  }

  Widget _homepageSection() {
    // M42: the live pointer decides whether the hero fields are
    // editable — a non-classic template owns the hero, so the
    // fields grey out with the note below. Classic re-enables them.
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: TemplatesService.instance.activeTemplatePointerStream(),
      builder: (context, pointerSnap) {
        final liveId =
            (pointerSnap.data?.data()?['templateId'] as String?) ??
                'classic';
        final heroDisabled = liveId != 'classic';
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
                      Text('مفيش منتجات في الواجهة لسه',
                          style: TextStyle(color: StoreGlass.of(context).textMuted)),
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
                                child: Icon(Icons.delete_outline,
                                    color: StoreGlass.of(context).danger, size: 20),
                              ),
                            ],
                          ),
                        ),
                      ),
                    if (_heroIds.length >= maxHeroProducts)
                      Text('وصلت للحد الأقصى (4 منتجات)',
                          style: TextStyle(color: StoreGlass.of(context).textMuted, fontSize: 13))
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
                      Text('مفيش بانرات لسه',
                          style: TextStyle(color: StoreGlass.of(context).textMuted)),
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
                                child: Icon(Icons.delete_outline,
                                    color: StoreGlass.of(context).danger),
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
                            child: Icon(Icons.delete_outline,
                                color: StoreGlass.of(context).danger),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 16),
                    const Text('عنوان الواجهة (هيرو)',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                    if (heroDisabled)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          'القالب المفعّل ($liveId) بيتحكم في عنوان الواجهة — الحقول دي مقفولة لحد ما الكلاسيكي يرجع.',
                          style: TextStyle(
                              color: StoreGlass.of(context).textMuted,
                              fontSize: 13),
                        ),
                      ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _heroTitle,
                      enabled: !heroDisabled,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        labelText: 'عنوان الواجهة',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _heroAccent,
                      enabled: !heroDisabled,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        labelText: 'الكلمة المميزة في العنوان',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _heroSubtitle,
                      enabled: !heroDisabled,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        labelText: 'سطر الواجهة',
                        border: OutlineInputBorder(),
                      ),
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
      },
    );
  }

  // Entry 13 — minimal pointer action (D7, kept permanently as the
  // admin-only advanced action): activate (template id + version,
  // from the approved registry) + rollback + current pointer
  // display. Same approval-hash check + same history as the card UI
  // — it is not an unguarded back door: both go through
  // TemplatesService.activateTemplate / rollbackTemplate.
  String? _pointerSelectedId;

  Widget _templatePointerSection() {
    final isAdmin = _role == 'admin';
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: TemplatesService.instance.activeTemplatePointerStream(),
      builder: (context, pointerSnap) {
        final pointer = pointerSnap.data?.data();
        final liveId = (pointer?['templateId'] as String?) ?? 'classic';
        final liveVersion =
            (pointer?['bundleVersion'] as String?) ?? '';
        final liveHash = (pointer?['bundleHash'] as String?) ?? '';
        final history = pointer?['history'];
        final historyLength = history is List ? history.length : 0;
        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: TemplatesService.instance.templatesStream(),
          builder: (context, snap) {
            final records = (snap.data?.docs ?? [])
                .map((d) => parseTemplateDoc(d.id, d.data()))
                .where((r) =>
                    r.validationPassed &&
                    (r.status == 'approved' || r.status == 'active'))
                .toList();
            if (_pointerSelectedId != null &&
                !records.any((r) => r.id == _pointerSelectedId)) {
              _pointerSelectedId = null;
            }
            return FlowCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('القالب المفعّل (إجراء متقدم — للأدمن)',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  SelectableText(
                    'الحالي: $liveId'
                    '${liveVersion.isEmpty ? '' : ' — إصدار $liveVersion'}'
                    '${liveHash.isEmpty ? '' : ' — هاش ${liveHash.length >= 12 ? liveHash.substring(0, 12) : liveHash}'}'
                    ' — سجل التفعيل: $historyLength خطوة',
                  ),
                  const SizedBox(height: 12),
                  if (!isAdmin)
                    const Text(
                        'التفعيل والرجوع للأدمن بس — العرض هنا للاطلاع.'),
                  if (isAdmin) ...[
                    DropdownButtonFormField<String>(
                      initialValue: _pointerSelectedId,
                      items: [
                        for (final r in records)
                          DropdownMenuItem(
                            value: r.id,
                            child: Text(
                                '${r.displayNameAr} (${r.isBundle ? r.bundleVersion : 'v${r.version}'}) — ${r.status == 'approved' ? 'معتمد' : 'جاهز'}'),
                          ),
                      ],
                      onChanged: (v) =>
                          setState(() => _pointerSelectedId = v),
                      decoration: const InputDecoration(
                          labelText: 'قالب معتمد للتفعيل'),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton(
                            onPressed: _pointerSelectedId == null ||
                                    _pointerSelectedId == liveId
                                ? null
                                : () async {
                                    final id = _pointerSelectedId!;
                                    final confirm = await _confirm(
                                        context,
                                        'هتفعّل قالب "$id"؟ الموقع هيتغير شكله للزوار الجدد.');
                                    if (confirm != true) return;
                                    try {
                                      await TemplatesService.instance
                                          .activateTemplate(
                                              templateId: id);
                                      if (context.mounted) {
                                        _snack(context, 'القالب اتفعّل');
                                      }
                                    } catch (e) {
                                      if (context.mounted) {
                                        _snack(context, e.toString(),
                                            error: true);
                                      }
                                    }
                                  },
                            child: const Text('تفعيل القالب'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        OutlinedButton(
                          onPressed: historyLength < 2
                              ? null
                              : () async {
                                  final confirm = await _confirm(context,
                                      'هترجع للقالب السابق؟ التفعيل الحالي هيتلغي في خطوة واحدة.');
                                  if (confirm != true) return;
                                  try {
                                    await TemplatesService.instance
                                        .rollbackTemplate();
                                    if (context.mounted) {
                                      _snack(
                                          context, 'رجعت للقالب السابق');
                                    }
                                  } catch (e) {
                                    if (context.mounted) {
                                      _snack(context, e.toString(),
                                          error: true);
                                    }
                                  }
                                },
                          child: const Text('رجوع للقالب السابق'),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
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
    // D2: the real promo end date (ISO 8601 date-time, Africa/Cairo).
    // Empty = no end date = no countdown, never a tick toward nothing.
    final endDate =
        TextEditingController(text: (existing?['endDate'] ?? '') as String);
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
                          style: TextStyle(color: StoreGlass.of(c).danger)),
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
                  TextField(
                    controller: endDate,
                    decoration: const InputDecoration(
                      labelText: 'تاريخ انتهاء العرض (اختياري)',
                      hintText: '2026-12-01T23:59:00+02:00',
                      helperText:
                          'بتوقيت القاهرة (ISO 8601). فاضي = مفيش عد تنازلي — العد بيشتغل على موعد حقيقي بس.',
                      border: OutlineInputBorder(),
                    ),
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
                onPressed: () {
                  final endError = validatePromoEndDate(endDate.text);
                  if (endError != null) {
                    setState(() => errorText = endError);
                    return;
                  }
                  Navigator.pop(
                      c,
                      promoBannerMap(
                        imageUrl: imageUrl,
                        title: title.text.trim(),
                        subtitle: subtitle.text.trim(),
                        linkType: linkType,
                        linkId: linkId,
                        endDate: endDate.text.trim(),
                      ));
                },
                child: const Text('تم'),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ---------------- Incomplete orders settings (2026-11-27) ----------------
//
// Three sections, each with the same draft pattern as brand/fee:
// typing/toggling only changes state, Save writes (merge-only),
// Cancel restores the last-saved values.

/// Governorate activation: 27 toggles from
/// storeSettings/governorates. A missing doc resolves to all 27
/// active (the storefront fallback); saving writes the full list.
class _GovernoratesSettings extends StatefulWidget {
  const _GovernoratesSettings();

  @override
  State<_GovernoratesSettings> createState() => _GovernoratesSettingsState();
}

class _GovernoratesSettingsState extends State<_GovernoratesSettings> {
  Map<String, bool>? _draft;
  Map<String, bool>? _saved;
  bool _saving = false;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: Backend.instance.governoratesStream(),
      builder: (context, snap) {
        if (_draft == null && snap.hasData) {
          final resolved = Backend.governorateFallback(
            snap.data!.data()?['entries'] as List<dynamic>?,
          );
          final activeIds =
              resolved.entries.map((g) => g['id']).toSet();
          _draft = {
            for (final g in Backend.governorates27)
              g['id']!: activeIds.contains(g['id']),
          };
          // A missing doc falls back to all 27 active, so the saved
          // baseline is the same full-active map.
          _saved = Map.of(_draft!);
        }
        if (snap.hasError) return _streamError(snap.error!);
        final draft = _draft;
        if (draft == null) return _loading();
        final activeCount = draft.values.where((v) => v).length;
        return FlowCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'المحافظات اللي التوصيل متاح ليها: $activeCount من 27. '
                'المحافظة المقفولة مش بتظهر للعميل في صفحة الطلب.',
                style: TextStyle(
                    color: StoreGlass.of(context).textSecondary),
              ),
              const SizedBox(height: 8),
              for (final g in Backend.governorates27)
                SwitchListTile(
                  dense: true,
                  title: Text(g['name']!),
                  value: draft[g['id']] ?? false,
                  onChanged: (v) =>
                      setState(() => draft[g['id']!] = v),
                ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      onPressed: _saving
                          ? null
                          : () async {
                              setState(() => _saving = true);
                              try {
                                await Backend.instance.saveGovernorates([
                                  for (final g in Backend.governorates27)
                                    {
                                      'id': g['id']!,
                                      'name': g['name']!,
                                      'active': draft[g['id']] ?? false,
                                    },
                                ]);
                                if (context.mounted) {
                                  setState(() {
                                    _saved = Map.of(draft);
                                    _saving = false;
                                  });
                                  _snack(
                                      context, 'تم حفظ مناطق التوصيل');
                                }
                              } catch (e) {
                                if (context.mounted) {
                                  setState(() => _saving = false);
                                  _snack(context, e.toString(), error: true);
                                }
                              }
                            },
                      child: const Text('حفظ مناطق التوصيل'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton(
                    onPressed: () => setState(() {
                      if (_saved != null) _draft = Map.of(_saved!);
                    }),
                    child: const Text('إلغاء'),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Scheduled auto-delete of checkout drafts (storeSettings/deletion).
/// X days, 0 = manual only. The deletion itself runs from the PC
/// admin program on start; this tab only holds the number.
class _DeletionSettings extends StatefulWidget {
  const _DeletionSettings();

  @override
  State<_DeletionSettings> createState() => _DeletionSettingsState();
}

class _DeletionSettingsState extends State<_DeletionSettings> {
  final _days = TextEditingController();
  int _savedDays = 0;
  bool _loaded = false;
  bool _saving = false;

  @override
  void dispose() {
    _days.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: Backend.instance.deletionConfigStream(),
      builder: (context, snap) {
        if (!_loaded && snap.hasData) {
          final raw = snap.data!.data()?['autoDeleteDays'];
          _savedDays = raw is num ? raw.toInt() : 0;
          _days.text = '$_savedDays';
          _loaded = true;
        }
        if (snap.hasError) return _streamError(snap.error!);
        if (!_loaded) return _loading();
        return FlowCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'المسودات بتفضل لحد ما تمسحها يدوياً من تبويب الطلبات الناقصة، '
                'أو حدد عدد أيام للحذف التلقائي (بيتنفذ من برنامج الكمبيوتر عند التشغيل). '
                'صفر يعني يدوي بس.',
                style: TextStyle(
                    color: StoreGlass.of(context).textSecondary),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _days,
                keyboardType: TextInputType.number,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: 'حذف تلقائي بعد (أيام) — 0 = يدوي بس',
                  hintText: 'مثال: 30',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      onPressed: _saving
                          ? null
                          : () async {
                              final days =
                                  int.tryParse(_days.text.trim());
                              if (days == null || days < 0 || days > 365) {
                                _snack(
                                    context,
                                    'عدد الأيام لازم يكون رقم صحيح بين 0 و 365',
                                    error: true);
                                return;
                              }
                              setState(() => _saving = true);
                              try {
                                await Backend.instance
                                    .saveDeletionConfig(days);
                                if (context.mounted) {
                                  setState(() {
                                    _savedDays = days;
                                    _saving = false;
                                  });
                                  _snack(context,
                                      'تم حفظ إعداد الحذف التلقائي');
                                }
                              } catch (e) {
                                if (context.mounted) {
                                  setState(() => _saving = false);
                                  _snack(context, e.toString(), error: true);
                                }
                              }
                            },
                      child: const Text('حفظ إعداد الحذف'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton(
                    onPressed: () =>
                        setState(() => _days.text = '$_savedDays'),
                    child: const Text('إلغاء'),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Quota meter + manual cut-off (storeSettings/quota). The estimate
/// is computed from today's drafts + journey summaries (rough: ~2
/// writes each) — visits are GA4, never counted here. The cut-off
/// is a manual flip; order writes are never cut.
class _QuotaSettings extends StatefulWidget {
  const _QuotaSettings();

  @override
  State<_QuotaSettings> createState() => _QuotaSettingsState();
}

class _QuotaSettingsState extends State<_QuotaSettings> {
  String? _cutoff;
  String? _savedCutoff;
  bool _saving = false;

  static const Map<String, String> _cutoffLabels = {
    'none': 'مفيش إيقاف',
    'journeys': 'إيقاف كتابة الرحلات',
    'drafts': 'إيقاف مزامنة المسودات كمان',
  };

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: Backend.instance.quotaStream(),
      builder: (context, snap) {
        if (_cutoff == null && snap.hasData) {
          final raw = snap.data!.data()?['cutoffLevel'];
          _savedCutoff =
              (raw is String && _cutoffLabels.containsKey(raw))
                  ? raw
                  : 'none';
          _cutoff = _savedCutoff;
        }
        if (snap.hasError) return _streamError(snap.error!);
        final cutoff = _cutoff;
        if (cutoff == null) return _loading();
        return FutureBuilder<
            ({int draftsToday, int journeysToday, int estimatedWrites})>(
          future: Backend.instance.dailyWriteEstimate(),
          builder: (context, estSnap) {
            final est = estSnap.data;
            final estimated = est?.estimatedWrites ?? 0;
            final pct =
                (estimated / 20000 * 100).toStringAsFixed(1);
            return FlowCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                      'الكتابة المقدرة اليوم: $estimated (مسودات اليوم: ${est?.draftsToday ?? '…'}، رحلات اليوم: ${est?.journeysToday ?? '…'})'),
                  const SizedBox(height: 4),
                  Text(
                    'حد Spark اليومي: 20,000 كتابة — الاستهلاك الحالي حوالي $pct٪. '
                    'الاستهلاك المعتاد ~500/يوم (2.5٪)، و~5,000/يوم لو الزوار ×10 (25٪).',
                    style: TextStyle(
                        color: StoreGlass.of(context).textSecondary),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: cutoff,
                    items: _cutoffLabels.entries
                        .map((e) => DropdownMenuItem(
                            value: e.key, child: Text(e.value)))
                        .toList(),
                    onChanged: (v) =>
                        setState(() => _cutoff = v ?? 'none'),
                    decoration: const InputDecoration(
                        labelText: 'إيقاف الكتابة عند الضغط'),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'الإيقاف يدوي — الطلبات عمرها ما بتتوقف. إيقاف الرحلات بيوقف تسجيل رحلات الزوار؛ '
                    'إيقاف المسودات بيوقف مزامنتها للسيرفر (النسخة المحلية في متصفح العميل بتفضل شغالة).',
                    style: TextStyle(
                        color: StoreGlass.of(context).textSecondary),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton(
                          onPressed: _saving
                              ? null
                              : () async {
                                  setState(() => _saving = true);
                                  try {
                                    await Backend.instance
                                        .setQuotaCutoff(cutoff);
                                    if (context.mounted) {
                                      setState(() {
                                        _savedCutoff = cutoff;
                                        _saving = false;
                                      });
                                      _snack(context, 'تم حفظ إعداد الحصة');
                                    }
                                  } catch (e) {
                                    if (context.mounted) {
                                      setState(() => _saving = false);
                                      _snack(context, e.toString(),
                                          error: true);
                                    }
                                  }
                                },
                          child: const Text('حفظ إعداد الحصة'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      OutlinedButton(
                        onPressed: () => setState(
                            () => _cutoff = _savedCutoff ?? 'none'),
                        child: const Text('إلغاء'),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}
