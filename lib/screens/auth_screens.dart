// Auth screens: account choice, first-admin creation, sign-in.
// All errors surface loudly with their real reason + a diagnostics entry.
// Choice + create use the selected Flow theme; sign-in is the FIXED
// Flow screen (flow_signin_screen.dart) and never follows the theme.
import 'package:flutter/material.dart';

import '../core/diagnostics.dart';
import '../core/identifier.dart';
import '../services/backend.dart';
import '../theme/flow_theme.dart';
import '../theme/store_design.dart';
import 'flow_signin_screen.dart';

void _showError(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
        content: Text(message),
        backgroundColor: StoreGlass.of(context).danger),
  );
}

class AccountChoiceScreen extends StatelessWidget {
  const AccountChoiceScreen({
    super.key,
    required this.onCreate,
    required this.onHaveAccount,
  });
  final VoidCallback onCreate;
  final VoidCallback onHaveAccount;

  @override
  Widget build(BuildContext context) {
    final variant = FlowThemeControllerScope.maybeOf(context)?.variant ??
        FlowThemeVariant.liquidGloss;
    final tokens = StoreGlassTokens.forVariant(variant);
    return FlowScaffold(
      variant: variant,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.storefront_rounded,
                  size: 64, color: tokens.accent),
              const SizedBox(height: 16),
              const Text('إدارة المتجر',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text('اختر طريقة الدخول',
                  style: TextStyle(color: tokens.textSecondary)),
              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                child: FlowButton(
                  key: const Key('choice-create'),
                  label: 'إنشاء حساب',
                  onPressed: onCreate,
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FlowButton(
                  key: const Key('choice-have-account'),
                  label: 'لدي حساب بالفعل',
                  primary: false,
                  onPressed: onHaveAccount,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'إنشاء الحساب للأدمن بس — لو زميلك عمل لك حساب قبل كده، اختار "لدي حساب بالفعل" وادخل من موبايلك.',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: tokens.textSecondary, fontSize: 13),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class CreateAccountScreen extends StatefulWidget {
  const CreateAccountScreen({super.key, required this.onDone, this.onBack});
  final VoidCallback onDone;
  final VoidCallback? onBack;

  @override
  State<CreateAccountScreen> createState() => _CreateAccountScreenState();
}

class _CreateAccountScreenState extends State<CreateAccountScreen> {
  final _email = TextEditingController();
  final _phone = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;

  Future<void> _submit() async {
    final email = _email.text.trim();
    final phone = _phone.text.trim();
    final password = _password.text;
    if (email.isEmpty || !email.contains('@')) {
      _showError(context, 'اكتب إيميل صحيح');
      return;
    }
    if (normalizeEgyptPhone(phone) == null) {
      _showError(context, 'اكتب رقم موبايل مصري صحيح');
      return;
    }
    if (password.length < 6) {
      _showError(context, 'كلمة السر لازم تكون 6 حروف على الأقل');
      return;
    }
    setState(() => _busy = true);
    try {
      await Backend.instance.createFirstAdmin(email: email, phone: phone, password: password);
      if (mounted) widget.onDone();
    } catch (e) {
      Diagnostics.instance.log('Create account failed: $e');
      if (mounted) _showError(context, e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final variant = FlowThemeControllerScope.maybeOf(context)?.variant ??
        FlowThemeVariant.liquidGloss;
    final tokens = StoreGlassTokens.forVariant(variant);
    return FlowScaffold(
      variant: variant,
      appBar: AppBar(
        title: const Text('إنشاء حساب أدمن'),
        leading: widget.onBack == null
            ? null
            : IconButton(icon: const Icon(Icons.arrow_back), onPressed: widget.onBack),
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          TextField(
            key: const Key('create-email'),
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            style: TextStyle(color: tokens.textPrimary),
            decoration: const InputDecoration(labelText: 'الإيميل'),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('create-phone'),
            controller: _phone,
            keyboardType: TextInputType.phone,
            style: TextStyle(color: tokens.textPrimary),
            decoration: const InputDecoration(
              labelText: 'رقم الموبايل',
              hintText: '01xxxxxxxxx',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('create-password'),
            controller: _password,
            obscureText: true,
            style: TextStyle(color: tokens.textPrimary),
            decoration: const InputDecoration(labelText: 'كلمة السر'),
          ),
          const SizedBox(height: 20),
          FlowButton(
            key: const Key('create-submit'),
            label: 'إنشاء الحساب',
            busy: _busy,
            onPressed: _busy ? null : _submit,
          ),
        ],
      ),
    );
  }
}

/// Sign-in delegates entirely to the fixed Flow screen. Keys
/// signin-identifier / signin-password / signin-submit live there.
class SignInScreen extends StatelessWidget {
  const SignInScreen({
    super.key,
    required this.onDone,
    this.onBack,
    this.onCreateAccount,
  });
  final VoidCallback onDone;
  final VoidCallback? onBack;
  final VoidCallback? onCreateAccount;

  @override
  Widget build(BuildContext context) {
    return FlowSignInScreen(
      onDone: onDone,
      onBack: onBack,
      onCreateAccount: onCreateAccount,
    );
  }
}
