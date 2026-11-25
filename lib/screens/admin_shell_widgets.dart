part of 'admin_shell.dart';

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
