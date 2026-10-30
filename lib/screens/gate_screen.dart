// Invite-code gate — the FIRST screen of the app. The app does not open
// without the correct code. The code lives ONLY in this const; it must
// never be printed, logged, or copied anywhere else (not in tests, docs,
// commit messages, or diagnostics).
import 'package:flutter/material.dart';

import '../core/diagnostics.dart';
import '../theme/flow_theme.dart';

/// The invite code. Referenced by tests through this const only.
const String kInviteCode = '037204';

class GateScreen extends StatefulWidget {
  const GateScreen({super.key, required this.onPassed});
  final VoidCallback onPassed;

  @override
  State<GateScreen> createState() => _GateScreenState();
}

class _GateScreenState extends State<GateScreen> {
  final TextEditingController _code = TextEditingController();
  String? _error;

  void _submit() {
    if (_code.text.trim() == kInviteCode) {
      Diagnostics.instance.log('Invite code accepted');
      widget.onPassed();
    } else {
      Diagnostics.instance.log('Invite code rejected');
      setState(() => _error = 'كود الدعوة مش صحيح');
    }
  }

  @override
  Widget build(BuildContext context) {
    final variant = FlowThemeControllerScope.maybeOf(context)?.variant ??
        FlowThemeVariant.liquidGloss;
    return FlowScaffold(
      variant: variant,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.storefront_rounded, size: 64, color: FlowPalette.cyan),
              const SizedBox(height: 16),
              const Text('إدارة المتجر', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              const Text('اكتب كود الدعوة عشان تفتح البرنامج', style: TextStyle(color: FlowPalette.textSecondary)),
              const SizedBox(height: 24),
              TextField(
                key: const Key('invite-code-field'),
                controller: _code,
                keyboardType: TextInputType.number,
                obscureText: true,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'كود الدعوة',
                  errorText: _error,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                ),
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FlowButton(
                  key: const Key('invite-submit'),
                  label: 'دخول',
                  onPressed: _submit,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
