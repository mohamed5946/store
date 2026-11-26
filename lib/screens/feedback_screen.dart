// Feedback section (design doc file 17, Technical Plan v1.4 §8).
//
// A tab in the admin shell: the feedback list (states, priority,
// category), the admin reply, the tracking-code lookup, and the
// spam marking. Feedback is never hard-deleted. 'urgent' priority is
// admin-only in the rules — the screen offers it only to admins.
part of 'admin_shell.dart';

const Map<String, String> feedbackTypeLabels = {
  'complaint': 'شكوى',
  'suggestion': 'اقتراح',
};

const Map<String, String> feedbackCategoryLabels = {
  'order_issue': 'مشكلة في طلب',
  'product_quality': 'جودة المنتج',
  'delivery': 'التوصيل',
  'website': 'الموقع',
  'pricing': 'الأسعار',
  'other': 'أخرى',
};

class _FeedbackTab extends StatefulWidget {
  const _FeedbackTab();

  @override
  State<_FeedbackTab> createState() => _FeedbackTabState();
}

class _FeedbackTabState extends State<_FeedbackTab> {
  String? _role;
  final _codeCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  Map<String, dynamic>? _lookupResult;
  String? _lookupError;
  bool _lookingUp = false;

  @override
  void initState() {
    super.initState();
    Backend.instance.currentUserRole().then((r) {
      if (mounted) setState(() => _role = r);
    });
  }

  @override
  void dispose() {
    _codeCtrl.dispose();
    _phoneCtrl.dispose();
    super.dispose();
  }

  Future<void> _lookup() async {
    final code = _codeCtrl.text.trim();
    final phone = _phoneCtrl.text.trim();
    if (code.isEmpty || phone.isEmpty) {
      setState(() {
        _lookupError = 'اكتب كود التتبع ورقم الموبايل';
        _lookupResult = null;
      });
      return;
    }
    setState(() {
      _lookingUp = true;
      _lookupError = null;
      _lookupResult = null;
    });
    try {
      final res = await Backend.instance.getFeedbackStatus(
        trackingCode: code,
        phone: phone,
      );
      if (!mounted) return;
      setState(() => _lookupResult = res);
    } catch (e) {
      if (!mounted) return;
      setState(() => _lookupError = e.toString());
    } finally {
      if (mounted) setState(() => _lookingUp = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: FlowCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('تتبع شكوى بكود',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _codeCtrl,
                        decoration: const InputDecoration(
                            labelText: 'كود التتبع', hintText: 'FB-XXXXXX'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _phoneCtrl,
                        keyboardType: TextInputType.phone,
                        decoration:
                            const InputDecoration(labelText: 'رقم الموبايل'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _lookingUp ? null : _lookup,
                      child: const Text('بحث'),
                    ),
                  ],
                ),
                if (_lookupError != null) ...[
                  const SizedBox(height: 8),
                  Text(_lookupError!, style: const TextStyle(color: Colors.red)),
                ],
                if (_lookupResult != null) ...[
                  const SizedBox(height: 8),
                  Text(
                      'الحالة: ${Backend.feedbackStatusLabels[_lookupResult!['status']] ?? _lookupResult!['status'] ?? ''}'),
                  if ((_lookupResult!['lastReply'] as String?)?.isNotEmpty == true)
                    Text('آخر رد: ${_lookupResult!['lastReply']}'),
                ],
              ],
            ),
          ),
        ),
        Expanded(
          child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: Backend.instance.feedbackStream(),
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return _loading();
              }
              if (snap.hasError) return _streamError(snap.error!);
              final docs = snap.data?.docs ?? [];
              if (docs.isEmpty) {
                return const Center(child: Text('مفيش شكاوى لسه'));
              }
              return StaggeredScope(
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(
                      16, 16, 16, StoreTokens.navPillClearance),
                  itemCount: docs.length,
                  itemBuilder: (context, i) {
                    final d = docs[i];
                    final data = d.data();
                    final status = (data['status'] ?? 'new') as String;
                    final priority = (data['priority'] ?? 'low') as String;
                    return StaggeredItem(
                      index: i,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _FlowRow(
                          title: Text((data['title'] ?? '') as String),
                          subtitle: Text(
                              '${feedbackCategoryLabels[data['category']] ?? data['category'] ?? ''} — ${Backend.feedbackStatusLabels[status] ?? status} — ${Backend.feedbackPriorityLabels[priority] ?? priority}'),
                          trailing: Text((data['trackingCode'] ?? '') as String),
                          onTap: () => _showFeedbackDetail(context, d, _role),
                        ),
                      ),
                    );
                  },
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Feedback detail dialog: the message, the customer link, the
/// replies, the reply composer (with an optional status move), the
/// priority picker, and the spam marking. Staggered entrance on
/// entry (v1.1.2).
Future<void> _showFeedbackDetail(
  BuildContext context,
  QueryDocumentSnapshot<Map<String, dynamic>> doc,
  String? role,
) async {
  final data = doc.data();
  var status = (data['status'] ?? 'new') as String;
  var priority = (data['priority'] ?? 'low') as String;
  final replyCtrl = TextEditingController();
  final legalNext = Backend.feedbackTransitions[status] ?? [];
  String? replyStatus = legalNext.contains('awaiting_customer')
      ? 'awaiting_customer'
      : (legalNext.isNotEmpty ? legalNext.first : null);
  await showDialog<void>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, setState) => AlertDialog(
        title: Text((data['title'] ?? '') as String),
        content: SingleChildScrollView(
          child: StaggeredScope(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                StaggeredItem(
                    index: 0,
                    child: Text(
                        '${feedbackTypeLabels[data['type']] ?? data['type'] ?? ''} — ${feedbackCategoryLabels[data['category']] ?? data['category'] ?? ''}')),
                StaggeredItem(
                    index: 1,
                    child: Text('الكود: ${data['trackingCode'] ?? ''}')),
                StaggeredItem(
                    index: 2,
                    child: Text(
                        'العميل: ${((data['customerRef'] as Map<String, dynamic>?)?['phone'] ?? '')} ${((data['customerRef'] as Map<String, dynamic>?)?['linked'] == true) ? '(مربوط بطلب)' : ''}')),
                const StaggeredItem(index: 3, child: Divider()),
                StaggeredItem(
                    index: 4, child: Text((data['message'] ?? '') as String)),
                const StaggeredItem(index: 5, child: Divider()),
                const StaggeredItem(
                    index: 6,
                    child: Text('الردود',
                        style: TextStyle(fontWeight: FontWeight.bold))),
                StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                  stream: Backend.instance.feedbackRepliesStream(doc.id),
                  builder: (context, snap) {
                    final replies = snap.data?.docs ?? [];
                    if (replies.isEmpty) {
                      return const Text('مفيش ردود لسه');
                    }
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: replies.map((r) {
                        final rd = r.data();
                        return Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                              '${(rd['adminName'] ?? '')}: ${(rd['text'] ?? '')}'),
                        );
                      }).toList(),
                    );
                  },
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: status,
                  items: [status, ...legalNext]
                      .map((s) => DropdownMenuItem(
                          value: s,
                          child: Text(Backend.feedbackStatusLabels[s] ?? s)))
                      .toList(),
                  onChanged: (v) => setState(() => status = v ?? status),
                  decoration: const InputDecoration(labelText: 'حالة الشكوى'),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: priority,
                  items: Backend.feedbackPriorityLabels.entries
                      .where((e) => e.key != 'urgent' || role == 'admin')
                      .map((e) => DropdownMenuItem(
                          value: e.key, child: Text(e.value)))
                      .toList(),
                  onChanged: (v) => setState(() => priority = v ?? priority),
                  decoration: const InputDecoration(labelText: 'الأولوية'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: replyCtrl,
                  maxLines: 3,
                  decoration:
                      const InputDecoration(labelText: 'اكتب رد للعميل'),
                ),
                if (legalNext.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    initialValue: replyStatus,
                    items: legalNext
                        .map((s) => DropdownMenuItem(
                            value: s,
                            child: Text(
                                'بعد الرد: ${Backend.feedbackStatusLabels[s] ?? s}')))
                        .toList(),
                    onChanged: (v) => setState(() => replyStatus = v),
                    decoration:
                        const InputDecoration(labelText: 'الحالة بعد الرد'),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              final confirm = await showDialog<bool>(
                context: c,
                builder: (cc) => AlertDialog(
                  title: const Text('تحويل لسبام؟'),
                  content: const Text(
                      'الشكوى هتتقفل كسبام ورقم الموبايل هيتحظر 24 ساعة من الإرسال.'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(cc, false),
                        child: const Text('إلغاء')),
                    FilledButton(
                        onPressed: () => Navigator.pop(cc, true),
                        child: const Text('تحويل لسبام')),
                  ],
                ),
              );
              if (confirm != true) return;
              try {
                await Backend.instance.markFeedbackSpam(doc.id);
                if (c.mounted) Navigator.pop(c);
              } catch (e) {
                if (c.mounted) _snack(c, e.toString(), error: true);
              }
            },
            child: const Text('سبام'),
          ),
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('إغلاق')),
          FilledButton(
            onPressed: () async {
              try {
                if (status != (data['status'] ?? '')) {
                  await Backend.instance.setFeedbackStatus(doc.id, status);
                }
                if (priority != (data['priority'] ?? '')) {
                  await Backend.instance.setFeedbackPriority(doc.id, priority);
                }
                if (replyCtrl.text.trim().isNotEmpty) {
                  await Backend.instance.replyToFeedback(
                    doc.id,
                    replyCtrl.text,
                    newStatus: replyStatus,
                  );
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
