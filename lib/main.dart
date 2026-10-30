// Store Admin — entry point.
// Launch flow, exact order: invite gate -> account choice
// ("إنشاء حساب" / "لدي حساب بالفعل") -> sign-in -> admin shell.
// Session persists; only an explicit confirmed sign-out logs out.
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'screens/admin_shell.dart';
import 'screens/auth_screens.dart';
import 'screens/gate_screen.dart';
import 'services/backend.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Backend.instance.init();
  runApp(const StoreAdminApp());
}

class StoreAdminApp extends StatefulWidget {
  const StoreAdminApp({super.key});

  @override
  State<StoreAdminApp> createState() => _StoreAdminAppState();
}

class _StoreAdminAppState extends State<StoreAdminApp> {
  bool? _gatePassed;
  String _page = 'choice';

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((prefs) {
      if (mounted) {
        setState(() => _gatePassed = prefs.getBool('gate_passed') ?? false);
      }
    });
  }

  Future<void> _passGate() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('gate_passed', true);
    if (mounted) setState(() => _gatePassed = true);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'إدارة المتجر',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0A84FF)),
        useMaterial3: true,
      ),
      builder: (context, child) => Directionality(
        textDirection: TextDirection.rtl,
        child: child!,
      ),
      home: _buildHome(),
    );
  }

  Widget _buildHome() {
    if (_gatePassed == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!_gatePassed!) {
      return GateScreen(onPassed: _passGate);
    }
    if (!Backend.instance.initialized) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.cloud_off_outlined, size: 48, color: Colors.red),
                const SizedBox(height: 16),
                const Text('تعذر الاتصال بقاعدة البيانات', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Text(
                  Backend.instance.initError ?? 'خطأ غير معروف',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.grey, fontSize: 13),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () async {
                    await Backend.instance.init();
                    setState(() {});
                  },
                  child: const Text('إعادة المحاولة'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return StreamBuilder<User?>(
      stream: Backend.instance.auth.authStateChanges(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        if (snap.data != null) {
          return AdminShell(onSignedOut: () => setState(() => _page = 'choice'));
        }
        switch (_page) {
          case 'create':
            return CreateAccountScreen(
              onDone: () => setState(() {}),
              onBack: () => setState(() => _page = 'choice'),
            );
          case 'signin':
            return SignInScreen(
              onDone: () => setState(() {}),
              onBack: () => setState(() => _page = 'choice'),
            );
          case 'choice':
          default:
            return AccountChoiceScreen(
              onCreate: () => setState(() => _page = 'create'),
              onHaveAccount: () => setState(() => _page = 'signin'),
            );
        }
      },
    );
  }
}
