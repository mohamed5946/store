// Template cards (design doc file 18, Technical Plan v1.4 §7;
// bundle model: spec store-templates.md entries 11–12).
//
// Tab index 4 in the admin shell (label 'القوالب') — the D7 "7th
// tab" decision predates the tonight batch's tab additions, and
// this tab already occupies the surface, so the card UI is built
// INTO this existing tab in place. No tab moves: incomplete orders
// stays index 7, Settings stays index 8.
//
// One card per template + classic, showing preview.png, Arabic name
// + English gloss + one-sentence identity, status, version, bundle
// hash, and activation history; draft → validate (readable report)
// → preview (?preview= link) → approve (D1 checklist) → confirm →
// apply; one-tap rollback. Brand constants (name, logo, tagline,
// WhatsApp number, COD message) are shown as non-negotiable on
// every card — a template never edits them.
//
// Templates are declarative data only and come from the
// owner/designer — the phone app never creates one; it lists,
// previews, activates, and rolls back. A template that fails the
// validation gateway never becomes a card.
//
// Launch ships one template — 'classic', the current live site.
// Until its registry document is seeded, the built-in classic
// definition stands in as the live card. The classic v1 definition
// (Templates.classic) is KEPT until the classic bundle (entry 7,
// shell child's work) passes its screenshot-diff gate.
part of 'admin_shell.dart';

const Map<String, String> _templateStateLabels = {
  'live': 'مفعّل',
  'ready': 'جاهز',
  'draft': 'مسودة',
  'preview': 'معاينة',
  'approved': 'معتمد',
  'archived': 'مؤرشف',
  'retired': 'متقاعد',
};

/// D1 approval checklist (spec §3 — Mohamed judges, pass/fail; any
/// single failure = reject; max 2 rounds per template).
const List<String> _d1Checklist = [
  'مختلف بوضوح عن الكلاسيكي وعن كل قالب معتمد تاني (ألوان وترتيب وحركة)',
  'الدفع زي ما هو — طلب واحد، نفس الأسعار، نفس خطوتي الدفع عند الاستلام',
  'مفيش ادعاء مخترع — مفيش عد تنازلي من غير موعد حقيقي، ولا سعر قديم من غير سعر حقيقي، ولا تقييم من غير مراجعات',
  'بيحمل وبيتحرك بسلاسة على الموبايل الضعيف من غير تهنيج',
  'السلة ونافذة المنتج والشكاوى وزر واتساب بيفتحوا وبيشتغلوا',
];

class _TemplatesTab extends StatefulWidget {
  const _TemplatesTab();

  @override
  State<_TemplatesTab> createState() => _TemplatesTabState();
}

class _TemplatesTabState extends State<_TemplatesTab> {
  String? _role;

  @override
  void initState() {
    super.initState();
    Backend.instance.currentUserRole().then((r) {
      if (mounted) setState(() => _role = r);
    });
  }

  @override
  Widget build(BuildContext context) {
    final isAdmin = _role == 'admin';
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: TemplatesService.instance.activeTemplatePointerStream(),
      builder: (context, pointerSnap) {
        final pointer = pointerSnap.data?.data();
        final liveId = (pointer?['templateId'] as String?) ?? 'classic';
        final history = pointer?['history'];
        final historyList = history is List ? history : <dynamic>[];
        // Rollback restores the SECOND-LAST history entry — never
        // previousTemplateId (display convenience only, B5 fix).
        final rollbackTarget = rollbackTargetEntry(historyList);
        final rollbackTargetId =
            (rollbackTarget?['templateId'] as String?) ?? '';
        final canRollback =
            rollbackTarget != null && rollbackTargetId != liveId;
        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: TemplatesService.instance.templatesStream(),
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return _loading();
            }
            if (snap.hasError) return _streamError(snap.error!);
            final docs = snap.data?.docs ?? [];
            final records = docs
                .map((d) => parseTemplateDoc(d.id, d.data()))
                .where((r) => r.validationPassed)
                .toList();
            final hiddenInvalid = docs.length - records.length;
            // Launch state: no registry documents yet — the built-in
            // classic stands in as the live card.
            final cards =
                records.isEmpty ? [Templates.classic] : records;
            // Brand constants (non-negotiable — read once for the
            // whole tab, shown on every card).
            return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
              stream: Backend.instance.brandStream(),
              builder: (context, brandSnap) {
                final brandData = brandSnap.data?.data() ?? {};
                final brandName =
                    (brandData['brandName'] as String?) ?? 'المتجر';
                final tagline =
                    (brandData['tagline'] as String?) ?? '';
                final whatsapp =
                    Backend.parseWhatsAppSettings(brandData).number;
                return StaggeredScope(
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(
                        16, 16, 16, StoreTokens.navPillClearance),
                    itemCount: cards.length + (hiddenInvalid > 0 ? 1 : 0),
                    itemBuilder: (context, i) {
                      if (i == cards.length) {
                        return Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            'في $hiddenInvalid قالب اترفض لأنه مش صالح للعرض',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                color: StoreGlass.of(context).danger),
                          ),
                        );
                      }
                      final record = cards[i];
                      final isLive = record.id == liveId;
                      final state = isLive
                          ? 'live'
                          : (record.status == 'active'
                              ? 'ready'
                              : record.status);
                      return StaggeredItem(
                        index: i,
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: _TemplateCard(
                            record: record,
                            isLive: isLive,
                            stateLabel:
                                _templateStateLabels[state] ?? state,
                            brandName: brandName,
                            tagline: tagline,
                            whatsappNumber: whatsapp,
                            onTap: () => _showTemplateDetail(
                              context,
                              record,
                              isLive: isLive,
                              canRollback: canRollback,
                              rollbackTargetId: rollbackTargetId,
                              isAdmin: isAdmin,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                );
              },
            );
          },
        );
      },
    );
  }
}

/// One template card: preview.png, Arabic name + English gloss +
/// one-sentence identity, status, version, bundle hash, and the
/// non-negotiable brand constants.
class _TemplateCard extends StatelessWidget {
  const _TemplateCard({
    required this.record,
    required this.isLive,
    required this.stateLabel,
    required this.brandName,
    required this.tagline,
    required this.whatsappNumber,
    required this.onTap,
  });

  final TemplateRecord record;
  final bool isLive;
  final String stateLabel;
  final String brandName;
  final String tagline;
  final String whatsappNumber;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = StoreGlass.of(context);
    final accent =
        PreviewTokens.fromTemplate(record.tokens).accent;
    final thumb = record.previewImageUrl.isNotEmpty
        ? record.previewImageUrl
        : (record.thumbnailUrl.isNotEmpty ? record.thumbnailUrl : '');
    final versionLabel =
        record.isBundle ? record.bundleVersion : 'v${record.version}';
    return Pressable(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: tokens.cardTop,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: tokens.cardBorder),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // preview.png — outside the hashed bundle, so a
            // re-capture after approval never voids the approval.
            if (thumb.isNotEmpty)
              Image.network(
                thumb,
                height: 140,
                fit: BoxFit.cover,
                errorBuilder: (c, e, st) => _TemplateThumbFallback(
                  record: record,
                  accent: accent,
                ),
              )
            else
              _TemplateThumbFallback(record: record, accent: accent),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${record.displayNameAr} — ${record.displayNameEn}',
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 16,
                          ),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: isLive
                              ? accent
                              : tokens.accentSoft,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          stateLabel,
                          style: TextStyle(
                            color: isLive
                                ? Colors.white
                                : tokens.accent,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    record.identityLine,
                    style: TextStyle(color: tokens.textMuted),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'إصدار $versionLabel'
                    '${record.isBundle ? ' — هاش ${record.shortHash}' : ''}'
                    '${record.fromRegistry ? '' : ' — افتراضي'}',
                    style: const TextStyle(fontSize: 13),
                  ),
                  const SizedBox(height: 8),
                  // Brand constants — non-negotiable on every card:
                  // a template never edits them.
                  Text(
                    'البراند: $brandName'
                    '${tagline.isEmpty ? '' : ' — $tagline'}'
                    ' • واتساب: $whatsappNumber • الدفع عند الاستلام',
                    style: TextStyle(
                      fontSize: 12,
                      color: tokens.textMuted,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TemplateThumbFallback extends StatelessWidget {
  const _TemplateThumbFallback({required this.record, required this.accent});

  final TemplateRecord record;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 120,
      color: accent,
      alignment: Alignment.center,
      child: Text(
        record.displayNameAr.isEmpty
            ? '؟'
            : record.displayNameAr.characters.first,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w800,
          fontSize: 42,
        ),
      ),
    );
  }
}

/// Shows a readable validation report: pass, or every failure named.
Future<void> _showValidationReport(
  BuildContext context,
  String title,
  BundleValidationReport report,
) async {
  await showDialog<void>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              report.passed
                  ? 'ناجح — القالب صالح للمعاينة والاعتماد.'
                  : 'فاشل — القالب مش هيتفعّل لحد ما الأخطاء دي تتصلح:',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            if (report.failedChecks.isNotEmpty) ...[
              const SizedBox(height: 8),
              for (final check in report.failedChecks)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text('• $check'),
                ),
            ],
            if (report.warnings.isNotEmpty) ...[
              const SizedBox(height: 8),
              const Text('تحذيرات (مش بتمنع التفعيل):',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              for (final warning in report.warnings)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text('• $warning'),
                ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(c),
          child: const Text('إغلاق'),
        ),
      ],
    ),
  );
}

/// D1 approval checklist dialog — Mohamed judges, pass/fail; any
/// single failure = reject. Returns true only when every item is
/// checked.
Future<bool?> _showApprovalChecklist(BuildContext context) async {
  final checked = List<bool>.filled(_d1Checklist.length, false);
  return showDialog<bool>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, setState) => AlertDialog(
        title: const Text('قائمة الاعتماد (D1)'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'الاعتماد بيجمّد الهاش وإصدار الشيل — أي تغيير في القالب بعد كده محتاج إعادة اعتماد.',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 8),
              for (var i = 0; i < _d1Checklist.length; i++)
                CheckboxListTile(
                  value: checked[i],
                  title: Text(_d1Checklist[i]),
                  onChanged: (v) =>
                      setState(() => checked[i] = v ?? false),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('رفض'),
          ),
          FilledButton(
            onPressed: checked.every((v) => v)
                ? () => Navigator.pop(c, true)
                : null,
            child: const Text('اعتماد'),
          ),
        ],
      ),
    ),
  );
}

/// Template detail dialog: identity, version, bundle hash, approval
/// record, activation history, and the lifecycle actions —
/// validate → preview → approve → confirm → apply, one-tap rollback.
/// The hand-built mock preview is GONE (entry 15): the preview
/// section shows the real ?preview= link instead.
Future<void> _showTemplateDetail(
  BuildContext context,
  TemplateRecord record, {
  required bool isLive,
  required bool canRollback,
  required String rollbackTargetId,
  required bool isAdmin,
}) async {
  // Grid editor state (A2, 2026-11-26): the detail dialog is where
  // the grid summary already lives, so the edit UI lives here too —
  // admin-only, registry templates only. The built-in classic has
  // no registry document yet, so it keeps the note below instead
  // of an editor (it gets one automatically once it is seeded).
  var gridColumns = record.gridColumns;
  var gridRows = record.gridRows;
  // Preview link state (issued per tap — a fresh unguessable slug).
  String? previewUrl;
  var previewBusy = false;
  await showDialog<void>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, setState) => AlertDialog(
        title: Text(
            '${record.displayNameAr} — ${record.displayNameEn}'),
        content: SingleChildScrollView(
          child: StaggeredScope(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                StaggeredItem(
                    index: 0, child: Text(record.identityLine)),
                StaggeredItem(
                    index: 1,
                    child: Text(
                        'الحالة: ${_templateStateLabels[isLive ? 'live' : (record.status == 'active' ? 'ready' : record.status)] ?? record.status} — إصدار ${record.isBundle ? record.bundleVersion : 'v${record.version}'}')),
                if (record.isBundle)
                  StaggeredItem(
                    index: 2,
                    child: SelectableText(
                        'الهاش: ${record.bundleHash}'),
                  ),
                StaggeredItem(
                    index: 3,
                    child: Text('مسار الحزمة: ${record.bodyPath}')),
                if (record.isBundle) ...[
                  StaggeredItem(
                    index: 4,
                    child: Text(
                        'الاعتماد: ${record.approvalApprover.isEmpty ? 'لسه معتمدش' : 'اعتمده ${record.approvalApprover} — شيل ${record.approvalShellVersion} — الهاش ${record.approvalStillValid ? 'مطابق' : 'اتغير، لازم إعادة اعتماد'}'}'),
                  ),
                ],
                StaggeredItem(
                    index: 5, child: Text('الشبكة: ${record.gridSummary}')),
                if (isAdmin && record.fromRegistry) ...[
                  const SizedBox(height: 12),
                  StaggeredItem(
                    index: 6,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('شبكة المنتجات',
                            style: TextStyle(fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
                        DropdownButtonFormField<int?>(
                          initialValue: gridColumns,
                          items: [
                            const DropdownMenuItem(
                                value: null,
                                child: Text('تلقائي (حسب عرض الشاشة)')),
                            for (var col = 1; col <= 12; col++)
                              DropdownMenuItem(
                                  value: col, child: Text('$col في الصف')),
                          ],
                          onChanged: (v) =>
                              setState(() => gridColumns = v),
                          decoration: const InputDecoration(
                              labelText: 'المنتجات في الصف (الأعمدة)'),
                        ),
                        const SizedBox(height: 8),
                        DropdownButtonFormField<int?>(
                          initialValue: gridRows,
                          items: [
                            const DropdownMenuItem(
                                value: null, child: Text('الكل')),
                            for (var r = 1; r <= 20; r++)
                              DropdownMenuItem(
                                  value: r, child: Text('$r صفوف')),
                          ],
                          onChanged: (v) => setState(() => gridRows = v),
                          decoration: const InputDecoration(
                              labelText: 'الصفوف قبل "عرض المزيد"'),
                        ),
                        const SizedBox(height: 8),
                        Align(
                          alignment: AlignmentDirectional.centerEnd,
                          child: OutlinedButton(
                            onPressed: (gridColumns == record.gridColumns &&
                                    gridRows == record.gridRows)
                                ? null
                                : () async {
                                    try {
                                      await TemplatesService.instance
                                          .updateTemplateGrid(
                                        id: record.id,
                                        columns: gridColumns,
                                        rows: gridRows,
                                      );
                                      if (c.mounted) {
                                        Navigator.pop(c);
                                        _snack(c, 'الشبكة اتحفظت');
                                      }
                                    } catch (e) {
                                      if (c.mounted) {
                                        _snack(c, e.toString(), error: true);
                                      }
                                    }
                                  },
                            child: const Text('حفظ الشبكة'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const StaggeredItem(index: 7, child: Divider()),
                // Lifecycle: validate → preview → approve.
                if (isAdmin && record.isBundle) ...[
                  const StaggeredItem(
                      index: 8,
                      child: Text('دورة القالب',
                          style: TextStyle(fontWeight: FontWeight.bold))),
                  const SizedBox(height: 8),
                  StaggeredItem(
                    index: 9,
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(
                          icon: const Icon(Icons.fact_check_outlined,
                              size: 18),
                          label: const Text('تحقق من القالب'),
                          onPressed: () async {
                            setState(() => previewBusy = true);
                            try {
                              final report = await TemplatesService
                                  .instance
                                  .runValidation(record.id);
                              if (c.mounted) {
                                await _showValidationReport(
                                    c, 'نتيجة التحقق', report);
                              }
                            } catch (e) {
                              if (c.mounted) {
                                _snack(c, e.toString(), error: true);
                              }
                            } finally {
                              if (c.mounted) {
                                setState(() => previewBusy = false);
                              }
                            }
                          },
                        ),
                        OutlinedButton.icon(
                          icon: const Icon(Icons.verified_outlined,
                              size: 18),
                          label: const Text('تحقق من الملفات الحية'),
                          onPressed: () async {
                            setState(() => previewBusy = true);
                            try {
                              final report = await TemplatesService
                                  .instance
                                  .validateLiveBundle(record.id);
                              if (c.mounted) {
                                await _showValidationReport(
                                    c, 'نتيجة تحقق الملفات الحية', report);
                              }
                            } catch (e) {
                              if (c.mounted) {
                                _snack(c, e.toString(), error: true);
                              }
                            } finally {
                              if (c.mounted) {
                                setState(() => previewBusy = false);
                              }
                            }
                          },
                        ),
                        OutlinedButton.icon(
                          icon: const Icon(Icons.visibility_outlined,
                              size: 18),
                          label: Text(previewBusy
                              ? 'جارٍ…'
                              : 'إصدار رابط معاينة'),
                          onPressed: previewBusy
                              ? null
                              : () async {
                                  setState(() => previewBusy = true);
                                  try {
                                    final url = await TemplatesService
                                        .instance
                                        .issuePreviewSlug(
                                      templateId: record.id,
                                      version: record.bundleVersion,
                                    );
                                    if (c.mounted) {
                                      setState(() => previewUrl = url);
                                    }
                                  } catch (e) {
                                    if (c.mounted) {
                                      _snack(c, e.toString(), error: true);
                                    }
                                  } finally {
                                    if (c.mounted) {
                                      setState(() => previewBusy = false);
                                    }
                                  }
                                },
                        ),
                      ],
                    ),
                  ),
                  if (previewUrl != null) ...[
                    const SizedBox(height: 8),
                    StaggeredItem(
                      index: 10,
                      child: RealTemplatePreviewLink(
                        previewUrl: previewUrl!,
                        templateName: record.displayNameAr,
                        onCopy: () => _snack(c, 'رابط المعاينة اتنسخ'),
                      ),
                    ),
                  ],
                  if (record.status == 'preview') ...[
                    const SizedBox(height: 8),
                    StaggeredItem(
                      index: 11,
                      child: FilledButton.tonalIcon(
                        icon: const Icon(Icons.check_circle_outlined),
                        label: const Text('اعتماد (قائمة D1)'),
                        onPressed: () async {
                          final approved =
                              await _showApprovalChecklist(c);
                          if (approved != true) return;
                          try {
                            await TemplatesService.instance
                                .approveTemplate(id: record.id);
                            if (c.mounted) {
                              Navigator.pop(c);
                              _snack(c, 'القالب اتعتمد');
                            }
                          } catch (e) {
                            if (c.mounted) {
                              _snack(c, e.toString(), error: true);
                            }
                          }
                        },
                      ),
                    ),
                  ],
                ],
                const StaggeredItem(index: 12, child: Divider()),
                // Activation history (subcollection, newest first).
                const StaggeredItem(
                    index: 13,
                    child: Text('سجل التفعيل',
                        style: TextStyle(fontWeight: FontWeight.bold))),
                const SizedBox(height: 4),
                StaggeredItem(
                  index: 14,
                  child: StreamBuilder<
                      QuerySnapshot<Map<String, dynamic>>>(
                    stream: TemplatesService.instance
                        .templateActivationsStream(record.id),
                    builder: (context, snap) {
                      if (snap.connectionState ==
                          ConnectionState.waiting) {
                        return const Text('جارٍ تحميل السجل…');
                      }
                      final entries = snap.data?.docs ?? [];
                      if (entries.isEmpty) {
                        return const Text('مفيش تفعيلات مسجلة لسه');
                      }
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final e in entries)
                            Padding(
                              padding:
                                  const EdgeInsets.only(bottom: 4),
                              child: Text(
                                '${(e.data()['action'] as String?) == 'rollback' ? 'رجوع' : 'تفعيل'} — إصدار ${(e.data()['bundleVersion'] as String?) ?? ''} — ${(e.data()['approver'] as String?) ?? ''}',
                                style: const TextStyle(fontSize: 13),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ),
                if (!record.fromRegistry) ...[
                  const SizedBox(height: 8),
                  const StaggeredItem(
                      index: 15,
                      child: Text(
                          'القالب ده افتراضي — لسه متسجلش في السجل. أول تفعيل لقالب تاني هيسجّله تلقائياً.')),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('إغلاق')),
          if (isAdmin && !isLive) ...[
            if (record.status == 'archived' || record.status == 'retired')
              TextButton(
                onPressed: () async {
                  try {
                    await TemplatesService.instance.setTemplateStatus(
                        id: record.id, status: 'draft');
                    if (c.mounted) {
                      Navigator.pop(c);
                      _snack(c, 'القالب رجع مسودة');
                    }
                  } catch (e) {
                    if (c.mounted) _snack(c, e.toString(), error: true);
                  }
                },
                child: const Text('رجّع مسودة'),
              )
            else
              TextButton(
                onPressed: () async {
                  try {
                    await TemplatesService.instance.setTemplateStatus(
                        id: record.id, status: 'archived');
                    if (c.mounted) {
                      Navigator.pop(c);
                      _snack(c, 'القالب اتأرشف');
                    }
                  } catch (e) {
                    if (c.mounted) _snack(c, e.toString(), error: true);
                  }
                },
                child: const Text('أرشفة'),
              ),
            FilledButton(
              onPressed: () async {
                final confirm = await _confirm(c,
                    'هتفعّل قالب "${record.displayNameAr}"؟ الموقع هيتغير شكله للزوار الجدد، والقالب الحالي هيفضل محفوظ للرجوع ليه.');
                if (confirm != true) return;
                try {
                  await TemplatesService.instance
                      .activateTemplate(templateId: record.id);
                  if (c.mounted) {
                    Navigator.pop(c);
                    _snack(c, 'القالب اتفعّل');
                  }
                } catch (e) {
                  if (c.mounted) _snack(c, e.toString(), error: true);
                }
              },
              child: const Text('تفعيل القالب'),
            ),
          ],
          if (isAdmin && isLive && canRollback)
            FilledButton(
              onPressed: () async {
                final confirm = await _confirm(
                    c, 'هترجع للقالب السابق ($rollbackTargetId)؟ التفعيل الحالي هيتلغي في خطوة واحدة.');
                if (confirm != true) return;
                try {
                  await TemplatesService.instance.rollbackTemplate();
                  if (c.mounted) {
                    Navigator.pop(c);
                    _snack(c, 'رجعت للقالب السابق');
                  }
                } catch (e) {
                  if (c.mounted) _snack(c, e.toString(), error: true);
                }
              },
              child: const Text('رجوع للقالب السابق'),
            ),
        ],
      ),
    ),
  );
}
