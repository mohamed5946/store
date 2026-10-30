// Store Admin Flow visual language — v1.1.
//
// The ENTIRE post-login app uses the Flow dark family (the same world as
// the sign-in screen), with TWO user-switchable variants, persisted in
// SharedPreferences and applied immediately with no restart (same
// pattern as a locale toggle). The LOGIN screen itself is FIXED Flow
// and never changes with this switch; gate / account-choice /
// create-account screens follow the selected variant.
//
//   (a) Liquid Gloss — dark, liquid-blob accents, glossy gradient
//       surfaces and buttons: the wet, flowing, high-gloss variant.
//   (b) Gloss Morphism — frosted-glass cards with blur + light borders
//       over a gradient backdrop: the glass-emphasis, calmer variant.
//
// Default until a preference exists: Liquid Gloss.
// Interaction ports (Pressable, stagger, bin-eats-label) live in
// store_design.dart and take their colors from FlowPalette here.
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'store_design.dart';

/// Flow palette — dark navy family, cyan/blue gradients. Semantic
/// colors survive only where they carry meaning: red = destructive,
/// green = delete success.
abstract class FlowPalette {
  static const Color background = Color(0xFF070B1A);
  static const Color backgroundTop = Color(0xFF0B1030);
  static const Color backgroundBottom = Color(0xFF05070F);
  static const Color card = Color(0xFF101A33);
  static const Color border = Color(0xFF2A3A66);
  static const Color borderLight = Color(0x44FFFFFF);
  static const Color textPrimary = Colors.white;
  static const Color textSecondary = Color(0xFFB8C2D9);
  static const Color textMuted = Color(0xFF7E8AA8);
  static const Color cyan = Color(0xFF22D3EE);
  static const Color blue = Color(0xFF2563EB);
  static const Color blueDeep = Color(0xFF1D4ED8);
  static const LinearGradient brandGradient =
      LinearGradient(colors: [Color(0xFF38BDF8), Color(0xFF22D3EE)]);
  static const LinearGradient buttonGradient = LinearGradient(
    colors: [Color(0xFF2563EB), Color(0xFF22D3EE)],
  );
  static const Color danger = Color(0xFFEF4444);
  static const Color dangerSoft = Color(0xFF3B1218);
  static const Color success = Color(0xFF22C55E);
}

/// Radii + paddings, mirroring DeliveryFlow's GlassTokens.
abstract class FlowTokens {
  static const double radiusL = 24;
  static const double radiusM = 18;
  static const double radiusS = 12;
  static const EdgeInsets cardPadding =
      EdgeInsets.symmetric(horizontal: 18, vertical: 16);
  static const EdgeInsets screenPadding = EdgeInsets.all(16);
}

enum FlowThemeVariant { liquidGloss, glossMorphism }

extension FlowThemeVariantLabel on FlowThemeVariant {
  String get label =>
      this == FlowThemeVariant.liquidGloss ? 'Liquid Gloss' : 'Gloss Morphism';
  String get prefsValue =>
      this == FlowThemeVariant.liquidGloss ? 'liquidGloss' : 'glossMorphism';

  static FlowThemeVariant fromPrefs(String? value) =>
      value == 'glossMorphism'
          ? FlowThemeVariant.glossMorphism
          : FlowThemeVariant.liquidGloss;
}

const String _kThemePrefsKey = 'flow_theme';

/// Persisted theme selection. Changing [variant] notifies listeners so
/// the MaterialApp rebuilds its ThemeData immediately — no restart.
class FlowThemeController extends ChangeNotifier {
  FlowThemeController([this._variant = FlowThemeVariant.liquidGloss]);

  FlowThemeVariant _variant;
  FlowThemeVariant get variant => _variant;

  static Future<FlowThemeController> load() async {
    final prefs = await SharedPreferences.getInstance();
    return FlowThemeController(
      FlowThemeVariantLabel.fromPrefs(prefs.getString(_kThemePrefsKey)),
    );
  }

  Future<void> setVariant(FlowThemeVariant value) async {
    if (_variant == value) return;
    _variant = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kThemePrefsKey, value.prefsValue);
  }
}

ThemeData flowThemeData(FlowThemeVariant variant) {
  final isGloss = variant == FlowThemeVariant.liquidGloss;
  return ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    scaffoldBackgroundColor: Colors.transparent,
    colorScheme: const ColorScheme.dark(
      primary: FlowPalette.cyan,
      onPrimary: Colors.white,
      secondary: FlowPalette.blue,
      surface: FlowPalette.card,
      onSurface: FlowPalette.textPrimary,
      error: FlowPalette.danger,
      onError: Colors.white,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      foregroundColor: FlowPalette.textPrimary,
      elevation: 0,
      centerTitle: true,
      titleTextStyle: TextStyle(
        color: FlowPalette.textPrimary,
        fontSize: 20,
        fontWeight: FontWeight.w800,
      ),
    ),
    cardTheme: CardThemeData(
      color: isGloss
          ? FlowPalette.card
          : FlowPalette.card.withValues(alpha: 0.55),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(FlowTokens.radiusM),
        side: BorderSide(
          color: isGloss ? FlowPalette.border : FlowPalette.borderLight,
        ),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: FlowPalette.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(FlowTokens.radiusL),
        side: const BorderSide(color: FlowPalette.borderLight),
      ),
    ),
    textTheme: const TextTheme(
      titleLarge: TextStyle(
          color: FlowPalette.textPrimary, fontWeight: FontWeight.w800),
      titleMedium: TextStyle(
          color: FlowPalette.textPrimary, fontWeight: FontWeight.w800),
      bodyLarge: TextStyle(color: FlowPalette.textPrimary),
      bodyMedium: TextStyle(color: FlowPalette.textPrimary),
      bodySmall: TextStyle(color: FlowPalette.textSecondary),
      labelLarge: TextStyle(
          color: FlowPalette.textPrimary, fontWeight: FontWeight.w700),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white.withValues(alpha: 0.07),
      labelStyle: const TextStyle(color: FlowPalette.textSecondary),
      hintStyle: const TextStyle(color: FlowPalette.textMuted),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(FlowTokens.radiusS),
        borderSide: const BorderSide(color: FlowPalette.borderLight),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(FlowTokens.radiusS),
        borderSide: const BorderSide(color: FlowPalette.borderLight),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(FlowTokens.radiusS),
        borderSide: const BorderSide(color: FlowPalette.cyan, width: 1.5),
      ),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: FlowPalette.card,
      contentTextStyle: TextStyle(color: Colors.white),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: FlowPalette.blue,
      foregroundColor: Colors.white,
    ),
  );
}

/// The liquid metaball blob: overlapping circles merging/splitting with
/// a glow, a small white highlight dot, and a tiny satellite droplet
/// that detaches and rejoins. [t] is a looping 0..1 phase; [drift] is a
/// slow autonomous offset (no cursor on mobile).
class FlowBlobPainter extends CustomPainter {
  FlowBlobPainter({required this.t, this.drift = Offset.zero});
  final double t;
  final Offset drift;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2) + drift;
    final base = math.min(size.width, size.height);
    double wobble(double phase) => math.sin((t * 2 * math.pi) + phase);
    // Soft glow beneath the blob, so it floats above the background.
    final glowRect = Rect.fromCenter(
      center: Offset(center.dx, center.dy + base * 0.30),
      width: base * 0.9,
      height: base * 0.45,
    );
    canvas.drawOval(
      glowRect,
      Paint()
        ..shader = const RadialGradient(
          colors: [Color(0x552563EB), Color(0x002563EB)],
        ).createShader(glowRect),
    );
    final blobs = [
      (Offset(center.dx + wobble(0) * base * 0.10, center.dy), base * 0.34),
      (
        Offset(center.dx + wobble(2.1) * base * 0.14,
            center.dy + wobble(1.3) * base * 0.08),
        base * 0.26
      ),
      (
        Offset(center.dx - wobble(4.2) * base * 0.12,
            center.dy + wobble(0.7) * base * 0.10),
        base * 0.22
      ),
    ];
    // Volumetric sphere shading: bright highlight offset toward the
    // top-left (focal), bright mid, darker limb at the edge.
    for (final (c, r) in blobs) {
      final paint = Paint()
        ..shader = RadialGradient(
          center: Alignment.center,
          focal: const Alignment(-0.45, -0.5),
          focalRadius: 0.05,
          colors: const [
            Color(0xFFE0F2FE),
            Color(0xFF38BDF8),
            Color(0xFF2563EB),
            Color(0xFF1E3A8A),
          ],
          stops: const [0.0, 0.30, 0.65, 1.0],
        ).createShader(Rect.fromCircle(center: c, radius: r));
      canvas.drawCircle(c, r, paint);
    }
    // White highlight dot on the main blob.
    canvas.drawCircle(
      Offset(center.dx - base * 0.10, center.dy - base * 0.12),
      base * 0.035,
      Paint()..color = Colors.white.withValues(alpha: 0.9),
    );
    // Satellite droplet: orbits out and back as t loops.
    final angle = t * 2 * math.pi;
    final dist = base * (0.42 + 0.10 * math.sin(angle * 2));
    final droplet = Offset(
      center.dx + math.cos(angle) * dist,
      center.dy + math.sin(angle) * dist * 0.6,
    );
    canvas.drawCircle(
      droplet,
      base * 0.045,
      Paint()
        ..shader = const RadialGradient(
          colors: [Color(0xFF7DD3FC), Color(0xFF2563EB)],
        ).createShader(
            Rect.fromCircle(center: droplet, radius: base * 0.045)),
    );
  }

  @override
  bool shouldRepaint(FlowBlobPainter old) =>
      old.t != t || old.drift != drift;
}

/// Gradient backdrop for the whole app. Liquid Gloss adds drifting blob
/// accents; Gloss Morphism keeps the gradient calmer (no blobs).
/// Subtle parallax: the blob layer moves at 0.3x the foreground scroll
/// (ScrollNotifications bubble up from any scrolling body), so the
/// background lags behind the content — cheap, no sensors.
class FlowScaffold extends StatefulWidget {
  const FlowScaffold({
    super.key,
    required this.variant,
    this.appBar,
    required this.body,
    this.bottomNavigationBar,
    this.floatingActionButton,
  });
  final FlowThemeVariant variant;
  final PreferredSizeWidget? appBar;
  final Widget body;
  final Widget? bottomNavigationBar;
  final Widget? floatingActionButton;

  @override
  State<FlowScaffold> createState() => _FlowScaffoldState();
}

class _FlowScaffoldState extends State<FlowScaffold> {
  double _scrollOffset = 0;

  bool _onScroll(ScrollNotification n) {
    if (n.metrics.axis == Axis.vertical) {
      final rounded = (n.metrics.pixels / 4).round() * 4.0;
      if (rounded != _scrollOffset) {
        setState(() => _scrollOffset = rounded);
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [FlowPalette.backgroundTop, FlowPalette.backgroundBottom],
        ),
      ),
      child: Stack(
        children: [
          if (widget.variant == FlowThemeVariant.liquidGloss)
            Positioned(
              top: -60 - _scrollOffset * 0.3,
              right: -40,
              child: Opacity(
                opacity: 0.35,
                child: CustomPaint(
                  size: const Size(220, 220),
                  painter: FlowBlobPainter(t: 0.15),
                ),
              ),
            ),
          NotificationListener<ScrollNotification>(
            onNotification: _onScroll,
            child: Scaffold(
              backgroundColor: Colors.transparent,
              appBar: widget.appBar,
              body: widget.body,
              bottomNavigationBar: widget.bottomNavigationBar,
              floatingActionButton: widget.floatingActionButton,
            ),
          ),
        ],
      ),
    );
  }
}

/// Flow card: Liquid Gloss = glossy gradient surface; Gloss Morphism =
/// frosted glass (blur + light border) over the gradient backdrop.
class FlowCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double borderRadius;
  final VoidCallback? onTap;

  const FlowCard({
    super.key,
    required this.child,
    this.padding = FlowTokens.cardPadding,
    this.borderRadius = FlowTokens.radiusM,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final variant = FlowThemeControllerScope.maybeOf(context)?.variant ??
        FlowThemeVariant.liquidGloss;
    final isGloss = variant == FlowThemeVariant.liquidGloss;
    // 3D depth, shared by both variants: multi-layer soft shadows
    // (ambient + key), a top-edge highlight and a darker bottom edge
    // for a beveled/embossed feel. Gloss Morphism adds inner glow.
    Widget card = Container(
      padding: padding,
      decoration: BoxDecoration(
        gradient: isGloss
            ? const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFF1B2A56), Color(0xFF0D1530)],
              )
            : LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.white.withValues(alpha: 0.16),
                  Colors.white.withValues(alpha: 0.04),
                ],
              ),
        borderRadius: BorderRadius.circular(borderRadius),
        border: Border.all(
          color: isGloss ? FlowPalette.border : FlowPalette.borderLight,
          width: 1,
        ),
        boxShadow: [
          // Ambient shadow: wide, soft, lifts the card off the bg.
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.28),
            blurRadius: 32,
            spreadRadius: 2,
            offset: const Offset(0, 16),
          ),
          // Key shadow: tighter, darker, grounds the card.
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.45),
            blurRadius: 12,
            offset: const Offset(0, 6),
          ),
          if (!isGloss)
            // Inner glow for glass: a faint cyan halo.
            BoxShadow(
              color: FlowPalette.cyan.withValues(alpha: 0.12),
              blurRadius: 24,
              offset: const Offset(0, 0),
            ),
        ],
      ),
      child: child,
    );
    if (!isGloss) {
      card = ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: card,
        ),
      );
    }
    if (onTap == null) return card;
    return Pressable(
      scaleOnly: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(borderRadius),
          onTap: onTap,
          child: card,
        ),
      ),
    );
  }
}

/// Inherited access to the current variant for theme-aware widgets.
class FlowThemeControllerScope extends InheritedWidget {
  const FlowThemeControllerScope({
    super.key,
    required this.controller,
    required super.child,
  });
  final FlowThemeController controller;
  FlowThemeVariant get variant => controller.variant;

  static FlowThemeControllerScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<FlowThemeControllerScope>();

  @override
  bool updateShouldNotify(FlowThemeControllerScope old) =>
      old.controller.variant != controller.variant;
}

/// Glossy gradient pill button (primary) or dark translucent pill
/// (secondary) — the Flow button language.
class FlowButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final bool primary;
  final IconData? icon;
  final bool busy;

  const FlowButton({
    super.key,
    required this.label,
    this.onPressed,
    this.primary = true,
    this.icon,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    final child = AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        // Raised pill: gradient lightens toward the top (highlight)
        // and deepens toward the bottom (shade) — real depth.
        gradient: primary
            ? const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFF60A5FA), Color(0xFF2563EB), Color(0xFF22D3EE)],
                stops: [0.0, 0.45, 1.0],
              )
            : LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.white.withValues(alpha: 0.16),
                  Colors.white.withValues(alpha: 0.05),
                ],
              ),
        border: Border.all(
          color: primary ? Colors.transparent : FlowPalette.borderLight,
          width: 1,
        ),
        // Multi-layer shadows; the Pressable dip sinks the pill
        // (depth decreases) while pressed.
        boxShadow: [
          BoxShadow(
            color: (primary ? FlowPalette.blue : Colors.black)
                .withValues(alpha: primary ? 0.45 : 0.25),
            blurRadius: primary ? 20 : 12,
            offset: const Offset(0, 6),
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.30),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: (onPressed == null || busy) ? null : onPressed,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (busy)
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                else ...[
                  if (icon != null) ...[
                    Icon(icon, size: 20, color: Colors.white),
                    const SizedBox(width: 8),
                  ],
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        label,
                        maxLines: 1,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
    // Pressable(scaleOnly) is correct here: the inner InkWell owns the tap.
    return Pressable(scaleOnly: true, child: child);
  }
}

/// Frosted-glass dialog (both variants): dark glass, light border, glow.
class FlowDialog extends StatelessWidget {
  final Widget? title;
  final Widget content;
  final List<Widget> actions;

  const FlowDialog({
    super.key,
    this.title,
    required this.content,
    this.actions = const [],
  });

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(FlowTokens.radiusL),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
            padding: const EdgeInsets.fromLTRB(22, 20, 22, 14),
            decoration: BoxDecoration(
              color: FlowPalette.card.withValues(alpha: 0.92),
              borderRadius: BorderRadius.circular(FlowTokens.radiusL),
              border: Border.all(color: FlowPalette.borderLight, width: 1),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.45),
                  blurRadius: 40,
                  offset: const Offset(0, 16),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (title != null) ...[
                  DefaultTextStyle(
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: FlowPalette.textPrimary,
                    ),
                    child: title!,
                  ),
                  const SizedBox(height: 12),
                ],
                content,
                if (actions.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      for (var i = 0; i < actions.length; i++) ...[
                        if (i > 0) const SizedBox(width: 8),
                        actions[i],
                      ],
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Future<T?> showFlowDialog<T>({
  required BuildContext context,
  Widget? title,
  required Widget content,
  List<Widget> actions = const [],
  bool barrierDismissible = true,
}) {
  return showDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    useRootNavigator: false,
    builder: (ctx) => FlowDialog(
      title: title,
      content: content,
      actions: actions,
    ),
  );
}

/// Floating glass pill nav bar — DeliveryFlow's GlassNavBar shape in
/// Flow dark: frosted pill, gradient selected indicator.
class FlowNavPill extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<IconData> icons;
  final List<String> labels;

  const FlowNavPill({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.icons,
    required this.labels,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(30),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            decoration: BoxDecoration(
              color: FlowPalette.card.withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(30),
              border: Border.all(color: FlowPalette.borderLight, width: 1),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.4),
                  blurRadius: 28,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                for (var i = 0; i < labels.length; i++) _item(context, i),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _item(BuildContext context, int i) {
    final selected = i == selectedIndex;
    return Pressable(
      onTap: () => onDestinationSelected(i),
      pressedScale: 0.9,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        padding:
            EdgeInsets.symmetric(horizontal: selected ? 16 : 10, vertical: 8),
        decoration: selected
            ? const BoxDecoration(
                borderRadius: BorderRadius.all(Radius.circular(20)),
                gradient: FlowPalette.buttonGradient,
                boxShadow: [
                  BoxShadow(
                    color: Color(0x662563EB),
                    blurRadius: 14,
                    offset: Offset(0, 4),
                  ),
                ],
              )
            : null,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icons[i],
              size: 24,
              color: selected ? Colors.white : FlowPalette.textSecondary,
            ),
            const SizedBox(height: 2),
            Text(
              labels[i],
              style: TextStyle(
                fontSize: 11,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? Colors.white : FlowPalette.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Widget flowLoading() => const Center(
      child: CircularProgressIndicator(color: FlowPalette.cyan),
    );

class FlowSectionHeader extends StatelessWidget {
  final String title;
  final String? actionLabel;
  final VoidCallback? onAction;

  const FlowSectionHeader({
    super.key,
    required this.title,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w800,
                color: FlowPalette.textPrimary,
              ),
            ),
          ),
          if (actionLabel != null)
            TextButton(
              onPressed: onAction,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(
                actionLabel!,
                style: const TextStyle(
                  color: FlowPalette.cyan,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class FlowEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String actionLabel;
  final VoidCallback onAction;

  const FlowEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.actionLabel,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(22),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: 0.08),
              ),
              child: Icon(icon, size: 44, color: FlowPalette.cyan),
            ),
            const SizedBox(height: 18),
            Text(
              title,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: FlowPalette.textPrimary,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            FlowButton(label: actionLabel, onPressed: onAction),
          ],
        ),
      ),
    );
  }
}
