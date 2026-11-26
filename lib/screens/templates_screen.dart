// Template cards (design doc file 18, Technical Plan v1.4 §7).
//
// A tab in the admin shell: the template cards stacked under each
// other (staggered entrance, both directions), each showing the
// template's name and state (live / ready / draft / archived), with
// draft → preview → confirm → apply and one-tap rollback to the
// previous template. Templates are declarative data only and come
// from the owner/designer — the phone app never creates one; it
// lists, previews, activates, and rolls back. A template that fails
// the validation gateway never becomes a card.
//
// Launch ships one template — 'classic', the current live site.
// Until its registry document is seeded, the built-in classic
// definition stands in as the live card.
part of 'admin_shell.dart';

const Map<String, String> _templateStateLabels = {
  'live': 'مفعّل',
  'ready': 'جاهز',
  'draft': 'مسودة',
  'archived': 'مؤرشف',
};

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
        final previousId =
            (pointer?['previousTemplateId'] as String?) ?? '';
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
                  final accent =
                      PreviewTokens.fromTemplate(record.tokens).accent;
                  return StaggeredItem(
                    index: i,
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _FlowRow(
                        leading: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: accent,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            record.name.isEmpty
                                ? '؟'
                                : record.name.characters.first,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                              fontSize: 18,
                            ),
                          ),
                        ),
                        title: Text(record.name),
                        subtitle: Text(
                            '${_templateStateLabels[state] ?? state} — إصدار ${record.version} — شبكة ${record.gridSummary}${record.fromRegistry ? '' : ' — افتراضي'}'),
                        trailing: isLive
                            ? Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: accent,
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: const Text(
                                  'مفعّل',
                                  style: TextStyle(
                                      color: Colors.white, fontSize: 12),
                                ),
                              )
                            : null,
                        onTap: () => _showTemplateDetail(
                          context,
                          record,
                          isLive: isLive,
                          previousId: previousId,
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
  }
}

/// Template detail dialog: the template's info, a preview rendered
/// in the template's own tokens, and the activation actions.
/// Activation is confirm-first (draft → preview → confirm → apply);
/// rollback returns the pointer to the previous template in one tap.
Future<void> _showTemplateDetail(
  BuildContext context,
  TemplateRecord record, {
  required bool isLive,
  required String previousId,
  required bool isAdmin,
}) async {
  final tokens = PreviewTokens.fromTemplate(record.tokens);
  await showDialog<void>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, setState) => AlertDialog(
        title: Text(record.name),
        content: SingleChildScrollView(
          child: StaggeredScope(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                StaggeredItem(
                    index: 0,
                    child: Text(record.description.isEmpty
                        ? 'مفيش وصف'
                        : record.description)),
                StaggeredItem(
                    index: 1,
                    child: Text(
                        'الحالة: ${_templateStateLabels[isLive ? 'live' : (record.status == 'active' ? 'ready' : record.status)] ?? record.status} — إصدار ${record.version}')),
                StaggeredItem(
                    index: 2,
                    child: Text('الشبكة: ${record.gridSummary}')),
                const StaggeredItem(index: 3, child: Divider()),
                const StaggeredItem(
                    index: 4,
                    child: Text('معاينة بالقالب ده',
                        style: TextStyle(fontWeight: FontWeight.bold))),
                const SizedBox(height: 8),
                StaggeredItem(
                  index: 5,
                  child: StorefrontHeaderPreview(
                    brandName: 'المتجر',
                    tagline: 'كل اللي تحتاجه، في مكان واحد',
                    tokens: tokens,
                  ),
                ),
                const SizedBox(height: 8),
                StaggeredItem(
                  index: 6,
                  child: StorefrontProductCardPreview(
                    name: 'سماعة بلوتوث',
                    priceText: '500',
                    tokens: tokens,
                  ),
                ),
                if (!record.fromRegistry) ...[
                  const SizedBox(height: 8),
                  const StaggeredItem(
                      index: 7,
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
            if (record.status == 'archived')
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
                    'هتفعّل قالب "${record.name}"؟ الموقع هيتغير شكله للزوار الجدد، والقالب الحالي هيفضل محفوظ للرجوع ليه.');
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
          if (isAdmin && isLive && previousId.isNotEmpty)
            FilledButton(
              onPressed: () async {
                final confirm = await _confirm(
                    c, 'هترجع للقالب السابق؟ التفعيل الحالي هيتلغي في خطوة واحدة.');
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
