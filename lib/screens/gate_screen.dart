// Invite-code gate — the FIRST screen of the app. The app does not open
// without the correct code. The code lives ONLY in this const; it must
// never be printed, logged, or copied anywhere else (not in tests, docs,
// commit messages, or diagnostics).
import 'package:flutter/material.dart';
import 'package:pinput/pinput.dart';

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

  /// One Pinput box: rounded, centered digit, border color by state.
  /// Shape and state behavior follow the @moza.flutter Pinput demo;
  /// colors follow this app's own Flow theme, never the demo's palette.
  PinTheme _box({
    required Color border,
    required Color fill,
    List<BoxShadow>? shadow,
  }) {
    return PinTheme(
      width: 52,
      height: 56,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      textStyle: const TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.bold,
        color: Colors.white,
      ),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: border, width: 1.5),
        boxShadow: shadow,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final variant = FlowThemeControllerScope.maybeOf(context)?.variant ??
        FlowThemeVariant.liquidGloss;
    final isGloss = variant == FlowThemeVariant.liquidGloss;
    final defaultFill =
        isGloss ? FlowPalette.card : Colors.white.withValues(alpha: 0.08);
    final defaultBorder =
        isGloss ? FlowPalette.border : FlowPalette.borderLight;
    final focusedShadow = isGloss
        ? [
            BoxShadow(
              color: FlowPalette.cyan.withValues(alpha: 0.35),
              blurRadius: 12,
              spreadRadius: 1,
            ),
          ]
        : null;
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
              Directionality(
                textDirection: TextDirection.ltr,
                child: Pinput(
                  key: const Key('invite-code-field'),
                  controller: _code,
                  // Length always tracks the const — never a hardcoded digit.
                  length: kInviteCode.length,
                  keyboardType: TextInputType.number,
                  obscureText: true,
                  // No blinking cursor: the focused border already signals
                  // focus, and this keeps widget tests deterministic.
                  showCursor: false,
                  defaultPinTheme: _box(
                    border: defaultBorder,
                    fill: defaultFill,
                  ),
                  focusedPinTheme: _box(
                    border: FlowPalette.cyan,
                    fill: defaultFill,
                    shadow: focusedShadow,
                  ),
                  submittedPinTheme: _box(
                    border: FlowPalette.blue,
                    fill: FlowPalette.blue.withValues(alpha: 0.15),
                  ),
                  errorPinTheme: _box(
                    border: FlowPalette.danger,
                    fill: FlowPalette.dangerSoft,
                  ),
                  forceErrorState: _error != null,
                  onChanged: (_) {
                    if (_error != null) setState(() => _error = null);
                  },
                  onSubmitted: (_) => _submit(),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: const TextStyle(color: FlowPalette.danger),
                ),
              ],
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
