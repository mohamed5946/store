// Auth screens: account choice, first-admin creation, sign-in.
// All errors surface loudly with their real reason + a diagnostics entry.
import 'package:flutter/material.dart';

import '../core/diagnostics.dart';
import '../core/identifier.dart';
import '../services/backend.dart';

void _showError(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message), backgroundColor: Colors.red.shade700),
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
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.storefront_rounded, size: 64, color: Color(0xFF0A84FF)),
              const SizedBox(height: 16),
              const Text('إدارة المتجر', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              const Text('اختر طريقة الدخول', style: TextStyle(color: Colors.grey)),
              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  key: const Key('choice-create'),
                  onPressed: onCreate,
                  child: const Text('إنشاء حساب'),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  key: const Key('choice-have-account'),
                  onPressed: onHaveAccount,
                  child: const Text('لدي حساب بالفعل'),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'إنشاء الحساب للأدمن بس — لو زميلك عمل لك حساب قبل كده، اختار "لدي حساب بالفعل" وادخل من موبايلك.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey, fontSize: 13),
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
    return Scaffold(
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
            decoration: const InputDecoration(labelText: 'الإيميل', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('create-phone'),
            controller: _phone,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(
              labelText: 'رقم الموبايل',
              hintText: '01xxxxxxxxx',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('create-password'),
            controller: _password,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'كلمة السر', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 20),
          FilledButton(
            key: const Key('create-submit'),
            onPressed: _busy ? null : _submit,
            child: _busy
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('إنشاء الحساب'),
          ),
        ],
      ),
    );
  }
}

class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key, required this.onDone, this.onBack});
  final VoidCallback onDone;
  final VoidCallback? onBack;

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final _identifier = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;

  Future<void> _submit() async {
    final error = validateSignIn(_identifier.text, _password.text);
    if (error != null) {
      _showError(context, error);
      return;
    }
    setState(() => _busy = true);
    try {
      await Backend.instance.signIn(_identifier.text, _password.text);
      if (mounted) widget.onDone();
    } catch (e) {
      Diagnostics.instance.log('Sign-in failed: $e');
      if (mounted) _showError(context, e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('تسجيل الدخول'),
        leading: widget.onBack == null
            ? null
            : IconButton(icon: const Icon(Icons.arrow_back), onPressed: widget.onBack),
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          TextField(
            key: const Key('signin-identifier'),
            controller: _identifier,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(
              labelText: 'الإيميل أو رقم الموبايل',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('signin-password'),
            controller: _password,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'كلمة السر', border: OutlineInputBorder()),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 20),
          FilledButton(
            key: const Key('signin-submit'),
            onPressed: _busy ? null : _submit,
            child: _busy
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('دخول'),
          ),
        ],
      ),
    );
  }
}
