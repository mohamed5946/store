part of 'admin_shell.dart';

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
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, StoreTokens.navPillClearance),
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
                                    child: Icon(Icons.delete_outline,
                                        color: StoreGlass.of(context).danger),
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
              Text(
                'العضو هيدخل من موبايله باختيار "لدي حساب بالفعل" بالإيميل أو الرقم وكلمة السر دي.',
                style: TextStyle(color: StoreGlass.of(c).textMuted, fontSize: 13),
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
