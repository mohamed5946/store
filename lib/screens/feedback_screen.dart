// Feedback section (no-functions contract §6).
//
// One-way complaint cards: name, email, phone, complaint + date.
// NO status, NO priority, NO replies, NO tracking code, NO lookup.
// The admin reads the cards and can delete one (spam, audited
// delete). A new complaint can be added on a customer's behalf
// (same one-way shape as the storefront contact form).
part of 'admin_shell.dart';

String _feedbackDate(Timestamp? ts) {
  if (ts == null) return '';
  final d = ts.toDate();
  final hh = d.hour.toString().padLeft(2, '0');
  final mm = d.minute.toString().padLeft(2, '0');
  return '${d.day}/${d.month}/${d.year} $hh:$mm';
}

class _FeedbackTab extends StatefulWidget {
  const _FeedbackTab();

  @override
  State<_FeedbackTab> createState() => _FeedbackTabState();
}

class _FeedbackTabState extends State<_FeedbackTab> {
  Future<void> _addFeedback() async {
    final nameCtrl = TextEditingController();
    final emailCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    final messageCtrl = TextEditingController();
    var errorText = '';
    var busy = false;
    final saved = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setState) => AlertDialog(
          title: const Text('شكوى جديدة'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(labelText: 'اسم العميل'),
                ),
                TextField(
                  controller: emailCtrl,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(labelText: 'الإيميل'),
                ),
                TextField(
                  controller: phoneCtrl,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(labelText: 'رقم الموبايل'),
                ),
                TextField(
                  controller: messageCtrl,
                  maxLines: 4,
                  decoration: const InputDecoration(labelText: 'الشكوى'),
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
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: const Text('إلغاء')),
            FilledButton(
              onPressed: busy
                  ? null
                  : () async {
                      final error = Backend.validateFeedbackInput(
                        name: nameCtrl.text,
                        email: emailCtrl.text,
                        phone: phoneCtrl.text,
                        message: messageCtrl.text,
                      );
                      if (error != null) {
                        setState(() => errorText = error);
                        return;
                      }
                      setState(() => busy = true);
                      try {
                        await Backend.instance.submitFeedback(
                          name: nameCtrl.text,
                          email: emailCtrl.text,
                          phone: phoneCtrl.text,
                          message: messageCtrl.text,
                        );
                        if (c.mounted) Navigator.pop(c, true);
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
        ),
      ),
    );
    if (saved == true && mounted) _snack(context, 'تم حفظ الشكوى');
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Align(
            alignment: AlignmentDirectional.centerEnd,
            child: FilledButton.icon(
              onPressed: _addFeedback,
              icon: const Icon(Icons.add),
              label: const Text('شكوى جديدة'),
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
                    return StaggeredItem(
                      index: i,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _FlowRow(
                          title: Text((data['name'] ?? '') as String),
                          subtitle: Text(
                              '${(data['email'] ?? '')}\n${(data['message'] ?? '')}'),
                          trailing: Text(
                              _feedbackDate(data['createdAt'] as Timestamp?)),
                          onTap: () => _showFeedbackDetail(context, d),
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

/// Complaint detail dialog: name, email, phone, complaint + date,
/// and the audited delete (spam). Nothing else — no status, no
/// replies, no tracking code.
Future<void> _showFeedbackDetail(
  BuildContext context,
  QueryDocumentSnapshot<Map<String, dynamic>> doc,
) async {
  final data = doc.data();
  await showDialog<void>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text((data['name'] ?? '') as String),
      content: SingleChildScrollView(
        child: StaggeredScope(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              StaggeredItem(
                  index: 0, child: Text('الإيميل: ${data['email'] ?? ''}')),
              StaggeredItem(
                  index: 1,
                  child: Text(
                      'رقم الموبايل: ${(data['phone'] ?? data['address'] ?? '')}')),
              StaggeredItem(
                  index: 2,
                  child: Text(
                      'التاريخ: ${_feedbackDate(data['createdAt'] as Timestamp?)}')),
              const StaggeredItem(index: 3, child: Divider()),
              StaggeredItem(
                  index: 4, child: Text((data['message'] ?? '') as String)),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            if (!await _confirm(
                context, 'امسح الشكوى دي؟ (بتتمسح نهائي — للسبام بس)')) {
              return;
            }
            try {
              await Backend.instance.deleteFeedback(doc.id);
              if (c.mounted) Navigator.pop(c);
            } catch (e) {
              if (c.mounted) _snack(c, e.toString(), error: true);
            }
          },
          child: Text('مسح', style: TextStyle(color: StoreGlass.of(c).danger)),
        ),
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('إغلاق')),
      ],
    ),
  );
}
