// Flow sign-in screen — exact replication of the reference video's
// beats, translated to mobile (tap instead of hover, autonomous blob
// drift instead of cursor-lean). The video's browser chrome and
// code-editor panes are NOT part of the UI and are not replicated.
//
// Beat 0 — dark navy bg, blue liquid metaball blob ALONE, morphing
// forever behind everything (volumetric sphere shading + glow).
// Beat 1 — frosted-glass card shell enters with ONLY the title
// (live brand name, NEVER "Flow"; fallback "Store") + subtitle + a
// centered dark-translucent "Log in" peek pill with chevron. Form hidden.
// Beat 2 — tapping peek wipes rows in TOP TO BOTTOM, one by one, each
// row clip-wiping (hidden-below -> fully shown) with 0.65s SPRING
// easing, staggered. Row order: Email, Password (+eye),
// Remember/Forgot row, Sign in pill, divider, Google button
// (full-width, Google-only — NO Apple button anywhere), Create line.
// Beat 3 — REVERSE: system-back or tapping outside the card wipes the
// form back out the same way and returns to peek; it does NOT pop.
// Beat 4 — SIGN-IN PRESS MELT: on Sign in press the button first
// SINKS (depth decreases, 3D pressed state), then MELTS — bottom edge
// sags, drips form and drop ~20px — over 500ms, then droplets FALL
// over 220ms, and only then does auth proceed. On auth failure the
// button UN-MELTS (restores) and shows the error; never stays melted.
//
// Arabic RTL labels: Email -> البريد الإلكتروني (identifier still
// accepts email OR phone), Password -> كلمة السر, Remember me ->
// تذكرني, Forgot -> نسيت كلمة السر؟, Sign in -> تسجيل الدخول,
// divider -> أو تابع باستخدام, bottom -> جديد هنا؟ إنشاء حساب.
// In RTL, Remember me sits on the right, Forgot on the left.
// Google sign-in is wired for real with the admin gate (non-admin ->
// signed out + plain message). The login screen is FIXED Flow: it
// never changes with the app theme switch.
import 'dart:ui';

import 'package:flutter/material.dart';

import '../core/diagnostics.dart';
import '../core/identifier.dart';
import '../services/backend.dart';
import '../theme/flow_theme.dart';
import '../theme/store_design.dart';

// The login screen is FIXED: it never follows the theme switch, so
// it reads the Liquid Gloss (LONA dark) token set directly instead
// of the variant-aware StoreGlass.of(context).
const _tokens = StoreGlassTokens.liquidGloss;

void _showMessage(BuildContext context, String message, {bool error = false}) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(message),
      backgroundColor: error ? _tokens.danger : _tokens.cardTop,
    ),
  );
}

class FlowSignInScreen extends StatefulWidget {
  const FlowSignInScreen({
    super.key,
    required this.onDone,
    this.onBack,
    this.onCreateAccount,
  });
  final VoidCallback onDone;
  final VoidCallback? onBack;
  final VoidCallback? onCreateAccount;

  @override
  State<FlowSignInScreen> createState() => _FlowSignInScreenState();
}

class _FlowSignInScreenState extends State<FlowSignInScreen>
    with TickerProviderStateMixin {
  final _identifier = TextEditingController();
  final _password = TextEditingController();
  bool _obscure = true;
  bool _remember = false;
  bool _formOpen = false;
  bool _busy = false;
  bool _googleBusy = false;
  bool _sunk = false;

  late final AnimationController _blobController;
  late final AnimationController _formController;
  late final AnimationController _meltController;
  Stream? _brandStream;

  static const _rowStagger = Duration(milliseconds: 90);
  static const _rowDuration = Duration(milliseconds: 650);
  static const _rowCount = 7;
  static const _meltDuration = Duration(milliseconds: 500);
  static const _fallDuration = Duration(milliseconds: 220);

  @override
  void initState() {
    super.initState();
    _blobController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 12),
    )..repeat();
    _formController = AnimationController(
      vsync: this,
      duration: _rowStagger * (_rowCount - 1) + _rowDuration,
    );
    _meltController = AnimationController(
      vsync: this,
      duration: _meltDuration + _fallDuration,
    );
    _loadRemember();
  }

  Future<void> _loadRemember() async {
    try {
      final value = await Backend.instance.getRememberMe();
      if (mounted) setState(() => _remember = value);
    } catch (_) {
      // Preference unavailable (e.g. widget test) — default off.
    }
  }

  @override
  void dispose() {
    _blobController.dispose();
    _formController.dispose();
    _meltController.dispose();
    _identifier.dispose();
    _password.dispose();
    super.dispose();
  }

  void _openForm() {
    if (_formOpen) return;
    setState(() => _formOpen = true);
    _formController.forward(from: 0);
  }

  Future<void> _closeForm() async {
    if (!_formOpen) return;
    await _formController.reverse();
    if (mounted) setState(() => _formOpen = false);
  }

  Future<bool> _onPop() async {
    if (_formOpen) {
      await _closeForm();
      return false;
    }
    if (!mounted) return false;
    widget.onBack?.call();
    return false;
  }

  /// Beat 4: sink -> melt (500ms) -> droplets fall (220ms) -> auth.
  /// On failure the button un-melts and the error shows.
  Future<void> _submit() async {
    if (_busy) return;
    final error = validateSignIn(_identifier.text, _password.text);
    if (error != null) {
      _showMessage(context, error, error: true);
      return;
    }
    setState(() {
      _busy = true;
      _sunk = true;
    });
    try {
      await _meltController.forward(from: 0);
    } catch (_) {}
    try {
      await Backend.instance.signIn(_identifier.text, _password.text);
      try {
        await Backend.instance.setRememberMe(_remember);
      } catch (_) {}
      if (mounted) widget.onDone();
    } catch (e) {
      Diagnostics.instance.log('Sign-in failed: $e');
      try {
        await _meltController.reverse();
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _busy = false;
        _sunk = false;
      });
      _showMessage(context, e.toString(), error: true);
    }
  }

  Future<void> _submitGoogle() async {
    if (_googleBusy) return;
    setState(() => _googleBusy = true);
    try {
      await Backend.instance.signInWithGoogle();
      if (mounted) widget.onDone();
    } catch (e) {
      Diagnostics.instance.log('Google sign-in failed: $e');
      if (mounted) _showMessage(context, e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _googleBusy = false);
    }
  }

  Future<void> _forgot() async {
    final id = _identifier.text.trim();
    if (!id.contains('@')) {
      _showMessage(
        context,
        'إعادة تعيين كلمة السر محتاجة الإيميل المسجل على الحساب',
      );
      return;
    }
    try {
      await Backend.instance.sendPasswordReset(id);
      if (mounted) _showMessage(context, 'اتبعت إيميل إعادة تعيين كلمة السر');
    } catch (e) {
      if (mounted) _showMessage(context, e.toString(), error: true);
    }
  }

  String _brandName(Object? snapshotError, String? brand) {
    if (brand != null && brand.isNotEmpty) return brand;
    return 'Store';
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (_, __) => _onPop(),
      child: Scaffold(
        backgroundColor: _tokens.base,
        body: Stack(
          children: [
            // Beat 0: blob alone behind everything, morphing forever.
            Positioned.fill(
              child: AnimatedBuilder(
                animation: _blobController,
                builder: (context, _) {
                  final t = _blobController.value;
                  return CustomPaint(
                    painter: FlowBlobPainter(
                      t: t,
                      drift: Offset(
                        18 * (t < 0.5 ? t * 2 : (1 - t) * 2) - 9,
                        0,
                      ),
                      colors: [
                        _tokens.blobBlue,
                        _tokens.blobOrange,
                        _tokens.blobPurple,
                      ],
                    ),
                    size: Size.infinite,
                  );
                },
              ),
            ),
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    _tokens.base.withValues(alpha: 0.4),
                    _tokens.base.withValues(alpha: 0.8),
                  ],
                ),
              ),
            ),
            // Tap outside the card reverses the form (Beat 3).
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: _closeForm,
              ),
            ),
            SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 32,
                  ),
                  child: GestureDetector(
                    onTap: () {},
                    child: _card(),
                  ),
                ),
              ),
            ),
            if (widget.onBack != null)
              SafeArea(
                child: Align(
                  alignment: Alignment.topRight,
                  child: IconButton(
                    icon: Icon(Icons.arrow_back,
                        color: _tokens.textSecondary),
                    onPressed: () => _onPop(),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _card() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(FlowTokens.radiusL),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(FlowTokens.radiusL),
            border: Border.all(color: _tokens.glassBorder, width: 1),
            // 3D depth: ambient + key shadow, top highlight, bottom shade.
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.white.withValues(alpha: 0.14),
                Colors.white.withValues(alpha: 0.04),
              ],
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.25),
                blurRadius: 32,
                spreadRadius: 2,
                offset: const Offset(0, 16),
              ),
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.45),
                blurRadius: 12,
                offset: const Offset(0, 6),
              ),
              BoxShadow(
                color: _tokens.accent.withValues(alpha: 0.25),
                blurRadius: 48,
                offset: const Offset(0, 0),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _title(),
              const SizedBox(height: 8),
              Text(
                'أهلًا بعودتك، كمّل شغل متجرك.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: _tokens.textSecondary,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 20),
              if (!_formOpen) _peekPill() else _formRows(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _title() {
    // Live brand name from Firestore (public read); fallback "Store".
    // When the backend is not initialized (e.g. widget tests) the
    // fallback shows without ever touching Firestore.
    if (!Backend.instance.initialized) {
      return _gradientTitle('Store');
    }
    _brandStream ??= Backend.instance.brandStream();
    return StreamBuilder(
      stream: _brandStream as Stream,
      builder: (context, snap) {
        final data = snap.data?.data() as Map<String, dynamic>?;
        final brand = (data?['brandName'] ?? '') as String;
        return _gradientTitle(_brandName(snap.error, brand));
      },
    );
  }

  Widget _gradientTitle(String text) {
    return ShaderMask(
      shaderCallback: (bounds) => StoreGlassTokens.brandGradient.createShader(
        Rect.fromLTWH(0, 0, bounds.width, bounds.height),
      ),
      child: Text(
        text,
        key: const Key('signin-brand-title'),
        textAlign: TextAlign.center,
        style: const TextStyle(
          fontSize: 40,
          fontWeight: FontWeight.w900,
          color: Colors.white,
          letterSpacing: -0.5,
        ),
      ),
    );
  }

  /// Beat 1: the peek pill — the only control visible before the form.
  Widget _peekPill() {
    return Center(
      child: PressableScale(
        onTap: _openForm,
        child: Container(
          key: const Key('signin-peek'),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: _tokens.glassBorder, width: 1),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.35),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Log in',
                style: TextStyle(
                  color: _tokens.textPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                ),
              ),
              const SizedBox(width: 6),
              Icon(Icons.keyboard_arrow_down,
                  size: 20, color: _tokens.textSecondary),
            ],
          ),
        ),
      ),
    );
  }

  /// Beat 2: rows wipe in top to bottom, 0.65s spring each, staggered.
  /// Beat 3 reverses this controller (see _closeForm).
  Widget _formRows() {
    final rows = <Widget>[
      _identifierField(),
      _passwordField(),
      _rememberForgotRow(),
      _meltSignInButton(),
      _divider(),
      _googleButton(),
      _createLine(),
    ];
    return AnimatedBuilder(
      animation: _formController,
      builder: (context, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < rows.length; i++) _wipeRow(i, rows[i]),
          ],
        );
      },
    );
  }

  Widget _wipeRow(int index, Widget row) {
    final total = _formController.duration!.inMilliseconds.toDouble();
    final start = (_rowStagger.inMilliseconds * index) / total;
    final end = start + _rowDuration.inMilliseconds / total;
    final interval = Interval(start, end.clamp(0.0, 1.0),
        curve: Curves.elasticOut);
    final p = interval.transform(_formController.value);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (reduceMotion) return row;
    return ClipRect(
      child: Opacity(
        opacity: p.clamp(0.0, 1.0),
        child: Transform.translate(
          offset: Offset(0, (1 - p) * 48),
          child: row,
        ),
      ),
    );
  }

  Widget _identifierField() {
    return TextField(
      key: const Key('signin-identifier'),
      controller: _identifier,
      keyboardType: TextInputType.emailAddress,
      style: TextStyle(color: _tokens.textPrimary),
      decoration: const InputDecoration(
        labelText: 'البريد الإلكتروني',
        hintText: 'الإيميل أو رقم الموبايل',
      ),
    );
  }

  Widget _passwordField() {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: TextField(
        key: const Key('signin-password'),
        controller: _password,
        obscureText: _obscure,
        style: TextStyle(color: _tokens.textPrimary),
        decoration: InputDecoration(
          labelText: 'كلمة السر',
          suffixIcon: IconButton(
            icon: Icon(
              _obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined,
              color: _tokens.textSecondary,
            ),
            onPressed: () => setState(() => _obscure = !_obscure),
          ),
        ),
        onSubmitted: (_) => _submit(),
      ),
    );
  }

  Widget _rememberForgotRow() {
    // RTL mirror of the video: Remember me on the right, Forgot left.
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 24,
                height: 24,
                child: Checkbox(
                  key: const Key('signin-remember'),
                  value: _remember,
                  activeColor: _tokens.accent,
                  onChanged: (v) async {
                    setState(() => _remember = v ?? false);
                    try {
                      await Backend.instance.setRememberMe(_remember);
                    } catch (_) {}
                  },
                ),
              ),
              const SizedBox(width: 4),
              Text('تذكرني',
                  style: TextStyle(color: _tokens.textSecondary)),
            ],
          ),
          TextButton(
            key: const Key('signin-forgot'),
            onPressed: _forgot,
            child: Text(
              'نسيت كلمة السر؟',
              style: TextStyle(color: _tokens.accent),
            ),
          ),
        ],
      ),
    );
  }

  /// Beat 4 button: sinks on press, melts 500ms, droplets fall 220ms.
  Widget _meltSignInButton() {
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: AnimatedBuilder(
        animation: _meltController,
        builder: (context, _) {
          final t = _meltController.value;
          final meltT = (t / (_meltDuration.inMilliseconds /
                  (_meltDuration.inMilliseconds + _fallDuration.inMilliseconds)))
              .clamp(0.0, 1.0);
          final fallT = ((t -
                      (_meltDuration.inMilliseconds /
                          (_meltDuration.inMilliseconds +
                              _fallDuration.inMilliseconds))) /
                  (_fallDuration.inMilliseconds /
                      (_meltDuration.inMilliseconds +
                          _fallDuration.inMilliseconds)))
              .clamp(0.0, 1.0);
          final sag = Curves.easeOut.transform(meltT);
          final sunkOffset = _sunk ? 2.0 : 0.0;
          return GestureDetector(
            onTapDown: (_) => setState(() => _sunk = true),
            onTapUp: (_) {
              if (!_busy) setState(() => _sunk = false);
              _submit();
            },
            onTapCancel: () {
              if (!_busy) setState(() => _sunk = false);
            },
            child: Transform.translate(
              offset: Offset(0, sunkOffset + sag * 2),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    key: const Key('signin-submit'),
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(999),
                      // Liquid-glass melt button: gold→orange, dark
                      // text (LONA's .act). White text on gold would
                      // wash out; accentText (#4a3300) stays readable.
                      gradient: _tokens.buttonGradient,
                      // Depth decreases while sunk/melting.
                      boxShadow: [
                        BoxShadow(
                          color: _tokens.accent.withValues(
                              alpha: _sunk ? 0.20 : 0.45),
                          blurRadius: _sunk ? 8 : 20,
                          offset: Offset(0, _sunk ? 2 : 6),
                        ),
                        BoxShadow(
                          color: Colors.white.withValues(alpha: 0.25),
                          blurRadius: 1,
                          offset: const Offset(0, -1),
                        ),
                      ],
                    ),
                    alignment: Alignment.center,
                    child: _busy && meltT >= 1
                        ? SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: _tokens.accentText,
                            ),
                          )
                        : Text(
                            'تسجيل الدخول',
                            style: TextStyle(
                              color: _tokens.accentText,
                              fontWeight: FontWeight.w800,
                              fontSize: 17,
                            ),
                          ),
                  ),
                  // Melt drips: form during the 500ms melt, fall ~20px
                  // during the 220ms fall, then auth proceeds.
                  if (sag > 0)
                    Positioned(
                      bottom: -sag * 6 - fallT * 20,
                      right: 48,
                      child: Opacity(
                        opacity: (1 - fallT).clamp(0.0, 1.0),
                        child: Container(
                          width: 10 + sag * 4,
                          height: 10 + sag * 10,
                          decoration: BoxDecoration(
                            color: _tokens.accent,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                    ),
                  if (sag > 0.4)
                    Positioned(
                      bottom: -sag * 4 - fallT * 20,
                      left: 64,
                      child: Opacity(
                        opacity: (1 - fallT).clamp(0.0, 1.0),
                        child: Container(
                          width: 7 + sag * 3,
                          height: 7 + sag * 8,
                          decoration: BoxDecoration(
                            color: StorePalette.orange,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _divider() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 18),
      child: Row(
        children: [
          Expanded(child: Divider(color: _tokens.glassBorder)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              'أو تابع باستخدام',
              style: TextStyle(color: _tokens.textMuted, fontSize: 13),
            ),
          ),
          Expanded(child: Divider(color: _tokens.glassBorder)),
        ],
      ),
    );
  }

  /// Google-only row: single full-width dark translucent button, G logo,
  /// white text. NO Apple button anywhere in this screen.
  Widget _googleButton() {
    return GestureDetector(
      key: const Key('signin-google'),
      onTap: _submitGoogle,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: _tokens.glassBorder, width: 1),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.30),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _googleG(),
            const SizedBox(width: 10),
            _googleBusy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Text(
                    'Google',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
                  ),
          ],
        ),
      ),
    );
  }

  Widget _googleG() {
    // Multi-color G mark drawn with text-free shapes (no asset needed).
    return SizedBox(
      width: 22,
      height: 22,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: 22,
            height: 22,
            decoration: const BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: const Text(
              'G',
              style: TextStyle(
                color: Color(0xFF4285F4),
                fontWeight: FontWeight.w900,
                fontSize: 15,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _createLine() {
    return Padding(
      padding: const EdgeInsets.only(top: 18),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            'جديد هنا؟ ',
            style: TextStyle(color: _tokens.textSecondary),
          ),
          GestureDetector(
            key: const Key('signin-create'),
            onTap: () {
              // Goes straight to the existing create-account screen.
              if (widget.onCreateAccount != null) {
                widget.onCreateAccount!();
              } else {
                widget.onBack?.call();
              }
            },
            child: Text(
              'إنشاء حساب',
              style: TextStyle(
                color: _tokens.accent,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Small press-scale wrapper (Pressable's scaleOnly mode requires an
/// inner tap handler; this is the tap handler itself).
class PressableScale extends StatefulWidget {
  const PressableScale({super.key, required this.onTap, required this.child});
  final VoidCallback onTap;
  final Widget child;

  @override
  State<PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<PressableScale> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) {
        setState(() => _pressed = false);
        widget.onTap();
      },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.96 : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}
