// Store Admin Liquid Glass visual language — Phase 1 redesign.
//
// LONA's Liquid Glass (v4.2 reference): dark navy base, soft color
// blobs, frosted glass with a 26px blur + gradient border + inset
// top highlight, gold accent. Two user-switchable variants,
// persisted in SharedPreferences and applied immediately with no
// restart (same pattern as a locale toggle):
//
//   (a) Liquid Gloss — the full LONA treatment: blobs, 26px shell
//       blur, glossy navy cards.
//   (b) Gloss Morphism — the calmer frosted variant: no blobs,
//       translucent glass cards, 12px shell blur.
//
// Default until a preference exists: Liquid Gloss. The LOGIN screen
// itself is FIXED (Liquid Gloss tokens) and never changes with this
// switch; gate / account-choice / create-account screens follow the
// selected variant.
//
// All tokens live in exactly one place — the contract in
// lib/theme/store_design.dart (StoreGlassTokens). Nothing in this
// file hard-codes a color; widgets read their variant's set through
// StoreGlass.of(context), and flowThemeData() builds ThemeData from
// the same set. The old FlowPalette is gone on purpose: a second
// palette would be a second source of truth.
// Interaction ports (Pressable, stagger, bin-eats-label, count-up,
// grow-bar) live in store_design.dart.
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'store_design.dart';

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
}

const String _kThemePrefsKey = 'flow_theme';

/// Persisted theme selection. Changing [variant] notifies listeners so
/// the MaterialApp rebuilds its ThemeData immediately — no restart.
/// Loading applies the migration rule from the token contract
/// (migrateStoredTheme): the key is unchanged, values map 1:1, and
/// unknown values fall back to Liquid Gloss.
class FlowThemeController extends ChangeNotifier {
  FlowThemeController([this._variant = FlowThemeVariant.liquidGloss]);

  FlowThemeVariant _variant;
  FlowThemeVariant get variant => _variant;

  static Future<FlowThemeController> load() async {
    final prefs = await SharedPreferences.getInstance();
    return FlowThemeController(
      migrateStoredTheme(prefs.getString(_kThemePrefsKey)),
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
  final tokens = StoreGlassTokens.forVariant(variant);
  return ThemeData(
    brightness: tokens.brightness,
    useMaterial3: true,
    scaffoldBackgroundColor: Colors.transparent,
    colorScheme: ColorScheme.dark(
      primary: tokens.accent,
      onPrimary: tokens.accentText,
      secondary: StorePalette.orange,
      surface: tokens.cardTop,
      onSurface: tokens.textPrimary,
      error: tokens.danger,
      onError: tokens.textPrimary,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      foregroundColor: tokens.textPrimary,
      elevation: 0,
      centerTitle: true,
      titleTextStyle: TextStyle(
        color: tokens.textPrimary,
        fontSize: 20,
        fontWeight: FontWeight.w800,
      ),
    ),
    cardTheme: CardThemeData(
      color: variant == FlowThemeVariant.liquidGloss
          ? tokens.cardTop
          : tokens.tint.withValues(alpha: 0.55),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(FlowTokens.radiusM),
        side: BorderSide(color: tokens.cardBorder),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: tokens.cardTop,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(FlowTokens.radiusL),
        side: BorderSide(color: tokens.glassBorder),
      ),
    ),
    textTheme: TextTheme(
      titleLarge:
          TextStyle(color: tokens.textPrimary, fontWeight: FontWeight.w800),
      titleMedium:
          TextStyle(color: tokens.textPrimary, fontWeight: FontWeight.w800),
      bodyLarge: TextStyle(color: tokens.textPrimary),
      bodyMedium: TextStyle(color: tokens.textPrimary),
      bodySmall: TextStyle(color: tokens.textSecondary),
      labelLarge:
          TextStyle(color: tokens.textPrimary, fontWeight: FontWeight.w700),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white.withValues(alpha: 0.07),
      labelStyle: TextStyle(color: tokens.textSecondary),
      hintStyle: TextStyle(color: tokens.textMuted),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(FlowTokens.radiusS),
        borderSide: BorderSide(color: tokens.glassBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(FlowTokens.radiusS),
        borderSide: BorderSide(color: tokens.glassBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(FlowTokens.radiusS),
        borderSide: BorderSide(color: tokens.accent, width: 1.5),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: tokens.cardTop,
      contentTextStyle: TextStyle(color: tokens.textPrimary),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: tokens.accent,
      foregroundColor: tokens.accentText,
    ),
  );
}

/// LONA's color blobs: three soft radial-gradient circles (blue
/// top-right, orange bottom-left, purple center) that slowly wobble
/// with [t] and drift with [drift]. No metaball shading, no glow
/// layer — the softness comes from the radial falloff itself, so the
/// painter is one cheap CustomPaint with no BackdropFilter. The
/// scaffold paints it once, static (t: 0.15); the sign-in screen
/// drives [t] on a 12s loop for the forever-morphing beat.
class FlowBlobPainter extends CustomPainter {
  FlowBlobPainter({required this.t, this.drift = Offset.zero, required this.colors});
  final double t;
  final Offset drift;
  final List<Color> colors;

  @override
  void paint(Canvas canvas, Size size) {
    final base = math.min(size.width, size.height);
    double wobble(double phase) => math.sin((t * 2 * math.pi) + phase);
    final blobs = <(Offset, double, Color)>[
      (
        Offset(
          size.width * 0.82 + wobble(0) * base * 0.06,
          size.height * 0.12 + wobble(1.3) * base * 0.04,
        ),
        base * 0.42,
        colors[0],
      ),
      (
        Offset(
          size.width * 0.14 + wobble(2.1) * base * 0.06,
          size.height * 0.88 + wobble(0.7) * base * 0.04,
        ),
        base * 0.38,
        colors[1],
      ),
      (
        Offset(
          size.width * 0.62 + wobble(4.2) * base * 0.05,
          size.height * 0.45 + wobble(2.8) * base * 0.05,
        ),
        base * 0.30,
        colors[2 % colors.length],
      ),
    ];
    for (final (c, r, color) in blobs) {
      canvas.drawCircle(
        c,
        r,
        Paint()
          ..shader = RadialGradient(
            colors: [color.withValues(alpha: 0.85), color.withValues(alpha: 0)],
          ).createShader(Rect.fromCircle(center: c, radius: r)),
      );
    }
  }

  @override
  bool shouldRepaint(FlowBlobPainter old) =>
      old.t != t || old.drift != drift || old.colors != colors;
}

/// Gradient backdrop for the whole app — the ONE shared backdrop
/// layer. The gradient + blobs are painted once here; dense lists
/// use translucent fills over it instead of a BackdropFilter per
/// card (adaptive glass). Liquid Gloss shows the blobs; Gloss
/// Morphism keeps the gradient calmer (no blobs).
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
    final tokens = StoreGlassTokens.forVariant(widget.variant);
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [tokens.backgroundTop, tokens.backgroundBottom],
        ),
      ),
      child: Stack(
        children: [
          if (tokens.showBlobs)
            Positioned.fill(
              child: CustomPaint(
                painter: FlowBlobPainter(
                  t: 0.15,
                  drift: Offset(0, -_scrollOffset * 0.3),
                  colors: [
                    tokens.blobBlue,
                    tokens.blobOrange,
                    tokens.blobPurple,
                  ],
                ),
              ),
            ),
          NotificationListener<ScrollNotification>(
            onNotification: _onScroll,
            child: Scaffold(
              backgroundColor: Colors.transparent,
              // The body extends under the floating nav pill, so the
              // screen behind the pill's rounded ends stays visible
              // (transparent corners) and content scrolls under the
              // glass instead of stopping above it. Root lists end
              // with StoreTokens.navPillClearance so the last item
              // never hides under the pill.
              extendBody: true,
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

/// Liquid Glass card (LONA `.glass`): gradient fill, gradient
/// border, inset top highlight, deep shadow. Adaptive glass: dense
/// lists use a translucent fill over the scaffold's shared backdrop
/// — NO BackdropFilter per card (one blur per card is the slow path).
/// The full 26px blur lives only on shell surfaces (nav pill,
/// dialog, sign-in card).
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
    final tokens = StoreGlass.of(context);
    // 3D depth, shared by both variants: multi-layer soft shadows
    // (ambient + key), a top-edge highlight and a darker bottom edge
    // for a beveled/embossed feel, plus LONA's inset sheen.
    Widget card = Container(
      padding: padding,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [tokens.cardTop, tokens.cardBottom],
        ),
        borderRadius: BorderRadius.circular(borderRadius),
        border: Border.all(
          color: tokens.cardBorder,
          width: 1,
        ),
        boxShadow: [
          // Ambient shadow: wide, soft, lifts the card off the bg.
          BoxShadow(
            color: tokens.shadowColor,
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
        ],
      ),
      child: child,
    );
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
/// (secondary) — the Flow button language. Primary is LONA's gold
/// action (`.act`): gold-to-orange gradient, dark text.
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
    final tokens = StoreGlass.of(context);
    final child = AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        // Raised pill: gradient lightens toward the top (highlight)
        // and deepens toward the bottom (shade) — real depth.
        gradient: primary
            ? tokens.buttonGradient
            : LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.white.withValues(alpha: 0.16),
                  Colors.white.withValues(alpha: 0.05),
                ],
              ),
        border: Border.all(
          color: primary ? Colors.transparent : tokens.glassBorder,
          width: 1,
        ),
        // Multi-layer shadows; the Pressable dip sinks the pill
        // (depth decreases) while pressed.
        boxShadow: [
          BoxShadow(
            color: (primary ? tokens.accent : Colors.black)
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
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: primary ? tokens.accentText : tokens.textPrimary,
                    ),
                  )
                else ...[
                  if (icon != null) ...[
                    Icon(
                      icon,
                      size: 20,
                      color: primary ? tokens.accentText : tokens.textPrimary,
                    ),
                    const SizedBox(width: 8),
                  ],
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        label,
                        maxLines: 1,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: primary
                              ? tokens.accentText
                              : tokens.textPrimary,
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

/// Frosted-glass dialog: LONA glass, light border, glow. Shell
/// surface, so it keeps one BackdropFilter at the variant's shell
/// blur — dialogs are one per screen, never one per list item.
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
    final tokens = StoreGlass.of(context);
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(FlowTokens.radiusL),
        child: BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: tokens.blurShell,
            sigmaY: tokens.blurShell,
          ),
          child: Container(
            padding: const EdgeInsets.fromLTRB(22, 20, 22, 14),
            decoration: BoxDecoration(
              color: tokens.cardTop.withValues(alpha: 0.92),
              borderRadius: BorderRadius.circular(FlowTokens.radiusL),
              border: Border.all(color: tokens.glassBorder, width: 1),
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
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: tokens.textPrimary,
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

/// Floating liquid-glass pill nav bar — the app's liquid visual
/// language, theme-aware:
/// - Liquid Gloss: full LONA treatment — navy glass over the blobs,
///   26px shell blur, gold glow shadow beneath the pill.
/// - Gloss Morphism: calmer frosted glass — translucent card, 12px
///   shell blur, softer shadow.
/// The pill floats: the scaffold extends the body under it
/// (extendBody), so the screen behind the rounded ends stays
/// visible — the corners are transparent, never an opaque rectangle.
/// The selected destination keeps its gold gradient pill.
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
    final tokens = StoreGlass.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(30),
        child: BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: tokens.blurShell,
            sigmaY: tokens.blurShell,
          ),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  tokens.cardTop.withValues(alpha: 0.92),
                  tokens.cardBottom.withValues(alpha: 0.92),
                ],
              ),
              borderRadius: BorderRadius.circular(30),
              border: Border.all(color: tokens.glassBorder, width: 1),
              boxShadow: [
                BoxShadow(
                  color: tokens.accent.withValues(alpha: 0.22),
                  blurRadius: 28,
                  offset: const Offset(0, 10),
                ),
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.35),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
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
    final tokens = StoreGlass.of(context);
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
            ? BoxDecoration(
                borderRadius: const BorderRadius.all(Radius.circular(20)),
                gradient: tokens.buttonGradient,
                boxShadow: [
                  BoxShadow(
                    color: tokens.accent.withValues(alpha: 0.4),
                    blurRadius: 14,
                    offset: const Offset(0, 4),
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
              color: selected ? tokens.accentText : tokens.textSecondary,
            ),
            const SizedBox(height: 2),
            Text(
              labels[i],
              style: TextStyle(
                fontSize: 11,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? tokens.accentText : tokens.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Widget flowLoading() {
  return Builder(
    builder: (context) => Center(
      child: CircularProgressIndicator(color: StoreGlass.of(context).accent),
    ),
  );
}

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
    final tokens = StoreGlass.of(context);
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
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w800,
                color: tokens.textPrimary,
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
                style: TextStyle(
                  color: tokens.accent,
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
    final tokens = StoreGlass.of(context);
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
              child: Icon(icon, size: 44, color: tokens.accent),
            ),
            const SizedBox(height: 18),
            Text(
              title,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: tokens.textPrimary,
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
