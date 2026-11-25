part of 'admin_shell.dart';

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
