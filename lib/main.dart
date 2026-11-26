// Store Admin — entry point.
// Launch flow, exact order: ST splash (once per launch) -> invite gate
// -> account choice ("إنشاء حساب" / "لدي حساب بالفعل") -> sign-in
// (fixed Flow screen) -> admin shell. Session persists; only an
// explicit confirmed sign-out logs out. The post-login app follows the
// selected Flow theme (Liquid Gloss / Gloss Morphism), persisted and
// applied immediately with no restart.
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'screens/admin_shell.dart';
import 'screens/auth_screens.dart';
import 'screens/gate_screen.dart';
import 'screens/splash_screen.dart';
import 'services/backend.dart';
import 'core/diagnostics.dart';
import 'theme/flow_theme.dart';
import 'theme/store_design.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Diagnostics first: the log must be loaded before anything logs
  // into it (Backend.init logs the Firebase result).
  await Diagnostics.instance.init();
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
  bool _splashDone = false;
  FlowThemeController? _themeController;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((prefs) {
      if (mounted) {
        setState(() => _gatePassed = prefs.getBool('gate_passed') ?? false);
      }
    });
    FlowThemeController.load().then((c) {
      if (mounted) setState(() => _themeController = c);
    });
  }

  Future<void> _passGate() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('gate_passed', true);
    if (mounted) setState(() => _gatePassed = true);
  }

  @override
  Widget build(BuildContext context) {
    final controller =
        _themeController ?? FlowThemeController();
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final variant = controller.variant;
        return MaterialApp(
          title: 'إدارة المتجر',
          debugShowCheckedModeBanner: false,
          theme: flowThemeData(variant),
          builder: (context, child) => Directionality(
            textDirection: TextDirection.rtl,
            child: _themeController == null
                ? child!
                : FlowThemeControllerScope(
                    controller: _themeController!,
                    child: child!,
                  ),
          ),
          home: _buildHome(),
        );
      },
    );
  }

  Widget _buildHome() {
    if (!_splashDone) {
      return StSplashScreen(onDone: () => setState(() => _splashDone = true));
    }
    if (_gatePassed == null) {
      return Scaffold(
        backgroundColor: StoreGlassTokens.liquidGloss.base,
        body: Center(
          child: CircularProgressIndicator(
              color: StoreGlassTokens.liquidGloss.accent),
        ),
      );
    }
    if (!_gatePassed!) {
      return GateScreen(onPassed: _passGate);
    }
    if (!Backend.instance.initialized) {
      final tokens = StoreGlassTokens.liquidGloss;
      return Scaffold(
        backgroundColor: tokens.base,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.cloud_off_outlined,
                    size: 48, color: tokens.danger),
                const SizedBox(height: 16),
                const Text('تعذر الاتصال بقاعدة البيانات',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Text(
                  Backend.instance.initError ?? 'خطأ غير معروف',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: tokens.textSecondary, fontSize: 13),
                ),
                const SizedBox(height: 16),
                FlowButton(
                  label: 'إعادة المحاولة',
                  onPressed: () async {
                    await Backend.instance.init();
                    setState(() {});
                  },
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
          return Scaffold(
            backgroundColor: StoreGlassTokens.liquidGloss.base,
            body: Center(
              child: CircularProgressIndicator(
                  color: StoreGlassTokens.liquidGloss.accent),
            ),
          );
        }
        if (snap.data != null) {
          return AdminShell(
            onSignedOut: () => setState(() => _page = 'choice'),
            themeController: _themeController,
          );
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
              onCreateAccount: () => setState(() => _page = 'create'),
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
