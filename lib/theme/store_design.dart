// Store Admin interaction ports — DeliveryFlow patterns restyled
// under the LONA Liquid Glass visual language (see the v4.2
// reference): frosted glass, gradient borders, gold accent. The
// token contract lives in exactly one place — this file — and every
// surface reads its tokens from it (see StoreGlassTokens below).
// Colors come from the LONA tokens + the store's 60-30-10 palette
// (cream #F7F2EA / navy #1C285A / orange #FF7A1A); this file holds
// no second theme of its own.

import 'dart:async';

import 'flow_theme.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Radii + paddings, mirroring DeliveryFlow's GlassTokens.
abstract class StoreTokens {
  static const double radiusL = 24;
  static const double radiusM = 18;
  static const double radiusS = 12;
  static const EdgeInsets cardPadding =
      EdgeInsets.symmetric(horizontal: 18, vertical: 16);
  static const EdgeInsets screenPadding = EdgeInsets.all(16);

  /// Clearance under the floating nav pill: root lists end this far
  /// above the screen bottom so the last item never hides under it.
  static const double navPillClearance = 96;
}

/// LONA Liquid Glass tokens, taken from the approved v4.2 preview
/// (`~/workspace/your_files/lona-liquid-glass-v4.2.html`): dark navy
/// base, blue/orange/purple blobs, gold accent, frosted glass with a
/// 26px blur, saturate + brightness lift, gradient border and inset
/// top highlight.
abstract class LonaTokens {
  static const Color gold = Color(0xFFF0C75E);
  static const Color goldSoft = Color(0xFFFFE9A8);
  static const Color base = Color(0xFF0B1430);
  static const Color tint = Color(0xFF0E163C);
  static const Color blobBlue = Color(0xFF3B5BFF);
  static const Color blobOrange = Color(0xFFFF8A3D);
  static const Color blobPurple = Color(0xFFB04BFF);
  static const Color ink = Color(0xFFFFFFFF);
  static const double glassBlur = 26;
  static const double glassSaturate = 1.85;
  static const double glassBrightness = 1.08;
}

/// The store's 60-30-10 palette: cream 60%, navy 30%, orange 10%.
/// In the dark LONA admin it maps as: cream is the ink (primary
/// text), navy is the surface tone, orange is the warm accent next
/// to LONA's gold.
abstract class StorePalette {
  static const Color cream = Color(0xFFF7F2EA);
  static const Color navy = Color(0xFF1C285A);
  static const Color orange = Color(0xFFFF7A1A);
}

/// One variant's full token set. The contract is owned here and only
/// here; surfaces read it through [StoreGlass.of] (variant-aware) or
/// the two const instances (fixed screens, e.g. sign-in).
class StoreGlassTokens {
  const StoreGlassTokens({
    required this.brightness,
    required this.backgroundTop,
    required this.backgroundBottom,
    required this.base,
    required this.tint,
    required this.cardTop,
    required this.cardBottom,
    required this.cardBorder,
    required this.glassFillTop,
    required this.glassFillBottom,
    required this.glassBorder,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.accent,
    required this.accentSoft,
    required this.accentText,
    required this.danger,
    required this.dangerSoft,
    required this.success,
    required this.blobBlue,
    required this.blobOrange,
    required this.blobPurple,
    required this.showBlobs,
    required this.blurShell,
    required this.shadowColor,
  });

  final Brightness brightness;
  final Color backgroundTop;
  final Color backgroundBottom;
  final Color base;
  final Color tint;
  final Color cardTop;
  final Color cardBottom;
  final Color cardBorder;
  final Color glassFillTop;
  final Color glassFillBottom;
  final Color glassBorder;
  final Color textPrimary;
  final Color textSecondary;
  final Color textMuted;
  final Color accent;
  final Color accentSoft;
  final Color accentText;
  final Color danger;
  final Color dangerSoft;
  final Color success;
  final Color blobBlue;
  final Color blobOrange;
  final Color blobPurple;
  final bool showBlobs;
  final double blurShell;
  final Color shadowColor;

  /// Primary button gradient: LONA gold into the store orange.
  LinearGradient get buttonGradient => LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [accentSoft, accent, StorePalette.orange],
        stops: const [0.0, 0.45, 1.0],
      );

  /// Brand gradient (sign-in title, product fallback): LONA gold.
  static const LinearGradient brandGradient = LinearGradient(
    colors: [LonaTokens.goldSoft, LonaTokens.gold],
  );

  /// Liquid Gloss — the full LONA treatment: dark navy base, three
  /// color blobs, 26px glass blur, gold accent, cream ink.
  static const StoreGlassTokens liquidGloss = StoreGlassTokens(
    brightness: Brightness.dark,
    backgroundTop: LonaTokens.tint,
    backgroundBottom: LonaTokens.base,
    base: LonaTokens.base,
    tint: LonaTokens.tint,
    cardTop: StorePalette.navy,
    cardBottom: Color(0xFF0D1530),
    cardBorder: Color(0xFF2A3A66),
    glassFillTop: Color(0x38FFFFFF),
    glassFillBottom: Color(0x12FFFFFF),
    glassBorder: Color(0x8CFFFFFF),
    textPrimary: StorePalette.cream,
    textSecondary: Color(0xADF7F2EA),
    textMuted: Color(0x6BF7F2EA),
    accent: LonaTokens.gold,
    accentSoft: LonaTokens.goldSoft,
    accentText: Color(0xFF4A3300),
    danger: Color(0xFFEF4444),
    dangerSoft: Color(0xFF3B1218),
    success: Color(0xFF22C55E),
    blobBlue: LonaTokens.blobBlue,
    blobOrange: LonaTokens.blobOrange,
    blobPurple: LonaTokens.blobPurple,
    showBlobs: true,
    blurShell: LonaTokens.glassBlur,
    shadowColor: Color(0x61080E28),
  );

  /// Gloss Morphism — the calmer frosted variant: same dark base and
  /// gold accent, no blobs, translucent glass cards, 12px shell blur.
  static const StoreGlassTokens glossMorphism = StoreGlassTokens(
    brightness: Brightness.dark,
    backgroundTop: Color(0xFF0B1030),
    backgroundBottom: Color(0xFF05070F),
    base: Color(0xFF070B1A),
    tint: Color(0xFF101A33),
    cardTop: Color(0x29FFFFFF),
    cardBottom: Color(0x0AFFFFFF),
    cardBorder: Color(0x1FFFFFFF),
    glassFillTop: Color(0x29FFFFFF),
    glassFillBottom: Color(0x0AFFFFFF),
    glassBorder: Color(0x8CFFFFFF),
    textPrimary: StorePalette.cream,
    textSecondary: Color(0xADF7F2EA),
    textMuted: Color(0x6BF7F2EA),
    accent: LonaTokens.gold,
    accentSoft: LonaTokens.goldSoft,
    accentText: Color(0xFF4A3300),
    danger: Color(0xFFEF4444),
    dangerSoft: Color(0xFF3B1218),
    success: Color(0xFF22C55E),
    blobBlue: LonaTokens.blobBlue,
    blobOrange: LonaTokens.blobOrange,
    blobPurple: LonaTokens.blobPurple,
    showBlobs: false,
    blurShell: 12,
    shadowColor: Color(0x66000000),
  );

  /// Explicit per-variant lookup — no boolean `isGloss` branching
  /// anywhere; every surface asks for its variant's set.
  static StoreGlassTokens forVariant(FlowThemeVariant variant) {
    switch (variant) {
      case FlowThemeVariant.liquidGloss:
        return liquidGloss;
      case FlowThemeVariant.glossMorphism:
        return glossMorphism;
    }
  }
}

/// Migration rule for the stored `flow_theme` preference. The key is
/// unchanged, so an existing preference carries over; the values map
/// 1:1. What changed in the redesign is what Gloss Morphism MEANS:
/// it is now the calmer frosted variant (no blobs, translucent
/// cards, 12px shell blur) instead of the old dark frosted look.
/// Unknown or missing values fall back to Liquid Gloss (the default).
FlowThemeVariant migrateStoredTheme(String? stored) {
  switch (stored) {
    case 'glossMorphism':
      return FlowThemeVariant.glossMorphism;
    case 'liquidGloss':
    default:
      return FlowThemeVariant.liquidGloss;
  }
}

/// Variant-aware access to the token contract for theme-aware widgets.
class StoreGlass {
  StoreGlass._();

  static StoreGlassTokens of(BuildContext context) {
    final variant = FlowThemeControllerScope.maybeOf(context)?.variant ??
        FlowThemeVariant.liquidGloss;
    return StoreGlassTokens.forVariant(variant);
  }
}

/// Tactile press wrapper, ported from DeliveryFlow's Pressable: the
/// child dips ~4px with a slight scale (120ms, easeOut) and springs
/// back. GPU-cheap: composited transforms only.
///
/// scaleOnly:true is animation-only and NEVER invokes onTap — use it
/// only around another tap handler (e.g. InkWell). The assert guards
/// this; pairing scaleOnly with onTap ships a dead button.
class Pressable extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final double pressedScale;
  final double pressedDip;
  final bool scaleOnly;

  const Pressable({
    super.key,
    required this.child,
    this.onTap,
    this.pressedScale = 0.96,
    this.pressedDip = 4.0,
    this.scaleOnly = false,
  }) : assert(
          !(scaleOnly && onTap != null),
          'Pressable: scaleOnly:true suppresses onTap — remove scaleOnly '
          'when Pressable is the tap handler, or drop onTap when it only '
          'adds animation around another handler (e.g. InkWell).',
        );

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    const duration = Duration(milliseconds: 120);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _setPressed(true),
      onTapUp: (_) {
        _setPressed(false);
        if (!widget.scaleOnly) widget.onTap?.call();
      },
      onTapCancel: () => _setPressed(false),
      child: AnimatedContainer(
        duration: duration,
        curve: Curves.easeOut,
        transform: Matrix4.translationValues(
          0,
          _pressed ? widget.pressedDip : 0.0,
          0,
        ),
        child: AnimatedScale(
          scale: _pressed ? widget.pressedScale : 1.0,
          duration: duration,
          curve: Curves.easeOut,
          child: widget.child,
        ),
      ),
    );
  }
}

/// Staggered list entrance, ported from DeliveryFlow's staggered
/// system: items fade in and slide up from 20% of their height, 80ms
/// stagger, capped at index 7, 300ms per item.
///
/// Visibility-driven replay (Phase 1): an item plays when it enters
/// the viewport and resets when it leaves, so the entrance replays
/// every time the item scrolls into view — scrolling down AND
/// scrolling up. A fresh mount (e.g. tab switch via the shell's
/// keyed subtree) replays it too. The scope listens to scroll
/// notifications from the list it wraps and asks each item to
/// re-check its visibility once per frame (coalesced). Items used
/// without a scope keep the old mount-once behaviour.
/// Reduce-motion: items appear immediately.
class StaggeredScope extends StatefulWidget {
  const StaggeredScope({super.key, required this.child});
  final Widget child;

  static StaggeredScopeState? maybeOf(BuildContext context) {
    final inherited =
        context.dependOnInheritedWidgetOfExactType<_StaggeredInherited>();
    return inherited?.state;
  }

  @override
  State<StaggeredScope> createState() => StaggeredScopeState();
}

class StaggeredScopeState extends State<StaggeredScope> {
  final Set<_StaggeredItemState> _items = {};
  bool _checkScheduled = false;

  void _register(_StaggeredItemState item) => _items.add(item);
  void _unregister(_StaggeredItemState item) => _items.remove(item);

  void _scheduleCheck() {
    if (_checkScheduled) return;
    _checkScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkScheduled = false;
      if (!mounted) return;
      for (final item in List<_StaggeredItemState>.of(_items)) {
        item.checkVisibility();
      }
    });
  }

  bool _onScroll(ScrollNotification notification) {
    _scheduleCheck();
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return _StaggeredInherited(
      state: this,
      child: NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: widget.child,
      ),
    );
  }
}

class _StaggeredInherited extends InheritedWidget {
  const _StaggeredInherited({required this.state, required super.child});
  final StaggeredScopeState state;
  @override
  bool updateShouldNotify(_StaggeredInherited old) => false;
}

class StaggeredItem extends StatefulWidget {
  const StaggeredItem({super.key, required this.index, required this.child});
  static const stagger = Duration(milliseconds: 80);
  static const capIndex = 7;
  static const itemDuration = Duration(milliseconds: 300);
  static const slideFraction = 0.2;

  static Duration delayFor(int index) =>
      stagger * (index < capIndex ? index : capIndex);

  final int index;
  final Widget child;

  @override
  State<StaggeredItem> createState() => _StaggeredItemState();
}

class _StaggeredItemState extends State<StaggeredItem>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _progress;
  Timer? _timer;
  bool _immediate = false;
  bool _visible = false;
  StaggeredScopeState? _scope;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: StaggeredItem.itemDuration,
    );
    _progress = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _immediate = true;
      return;
    }
    final scope = StaggeredScope.maybeOf(context);
    if (scope != _scope) {
      _scope?._unregister(this);
      _scope = scope;
      _scope?._register(this);
    }
    if (scope == null) {
      // No scope above: keep the mount-once behaviour.
      _play();
      return;
    }
    // First check after layout, so initially-visible items play
    // with their stagger and off-screen items wait for their turn.
    WidgetsBinding.instance.addPostFrameCallback((_) => checkVisibility());
  }

  /// Called by the scope after scrolls and on mount. Plays the
  /// entrance when the item is in the viewport; resets it when it
  /// leaves, so the next entry replays from the start.
  void checkVisibility() {
    if (!mounted || _immediate) return;
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return;
    final itemTop = renderObject.localToGlobal(Offset.zero).dy;
    final itemBottom = itemTop + renderObject.size.height;
    final scrollable = Scrollable.of(context);
    final viewportBox =
        scrollable.context.findRenderObject() as RenderBox?;
    double viewTop;
    double viewBottom;
    if (viewportBox != null && viewportBox.hasSize) {
      viewTop = viewportBox.localToGlobal(Offset.zero).dy;
      viewBottom = viewTop + viewportBox.size.height;
    } else {
      viewTop = 0;
      viewBottom = MediaQuery.sizeOf(context).height;
    }
    final visible = itemBottom > viewTop && itemTop < viewBottom;
    if (visible) {
      _play();
    } else {
      _reset();
    }
  }

  void _play() {
    if (_visible) return;
    _visible = true;
    _timer?.cancel();
    _timer = Timer(StaggeredItem.delayFor(widget.index), () {
      if (mounted) _controller.forward();
    });
  }

  void _reset() {
    if (!_visible && _controller.value == 0) return;
    _visible = false;
    _timer?.cancel();
    _controller.reset();
  }

  @override
  void dispose() {
    _scope?._unregister(this);
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_immediate) return widget.child;
    return AnimatedBuilder(
      animation: _progress,
      builder: (context, child) {
        final t = _progress.value;
        return Opacity(
          opacity: t,
          child: FractionalTranslation(
            translation: Offset(0, StaggeredItem.slideFraction * (1 - t)),
            child: child,
          ),
        );
      },
      child: widget.child,
    );
  }
}

/// Number that counts up to its target on entry (LONA's `.num`:
/// 1100ms, ease-out cubic). Re-runs from zero when the target
/// changes, so a live update counts again instead of jumping.
class CountUpText extends StatefulWidget {
  const CountUpText({
    super.key,
    required this.target,
    this.format,
    this.duration = const Duration(milliseconds: 1100),
    this.style,
  });

  final num target;
  final String Function(num value)? format;
  final Duration duration;
  final TextStyle? style;

  @override
  State<CountUpText> createState() => _CountUpTextState();
}

class _CountUpTextState extends State<CountUpText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late Animation<double> _animation;
  double _from = 0;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration);
    _animation = Tween<double>(begin: 0, end: widget.target.toDouble())
        .animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reduce-motion is read here, not in initState: initState may
    // not touch inherited widgets (MediaQuery).
    if (_started) return;
    _started = true;
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.value = 1;
    } else {
      _controller.forward();
    }
  }

  @override
  void didUpdateWidget(CountUpText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.target != oldWidget.target) {
      _from = _animation.value;
      _animation =
          Tween<double>(begin: _from, end: widget.target.toDouble()).animate(
        CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
      );
      _controller
        ..reset()
        ..forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, _) {
        final value = _animation.value;
        final text = widget.format != null
            ? widget.format!(value)
            : (widget.target is int
                ? value.toStringAsFixed(0)
                : value.toStringAsFixed(1));
        return Text(text, style: widget.style);
      },
    );
  }
}

/// Horizontal bar that grows from zero to [fraction] on entry
/// (LONA's `.barx`: 6px, gold gradient, 1s ease-out). Grows from
/// the inline-start side, so it reads right-to-left in RTL.
class GrowBar extends StatefulWidget {
  const GrowBar({
    super.key,
    required this.fraction,
    this.height = 6,
    this.duration = const Duration(milliseconds: 1000),
  });

  final double fraction;
  final double height;
  final Duration duration;

  @override
  State<GrowBar> createState() => _GrowBarState();
}

class _GrowBarState extends State<GrowBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late Animation<double> _animation;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration);
    _animation = Tween<double>(begin: 0, end: widget.fraction.clamp(0.0, 1.0))
        .animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reduce-motion is read here, not in initState: initState may
    // not touch inherited widgets (MediaQuery).
    if (_started) return;
    _started = true;
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.value = 1;
    } else {
      _controller.forward();
    }
  }

  @override
  void didUpdateWidget(GrowBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.fraction != oldWidget.fraction) {
      final from = _animation.value;
      _animation = Tween<double>(
        begin: from,
        end: widget.fraction.clamp(0.0, 1.0),
      ).animate(
        CurvedAnimation(parent: _controller, curve: Curves.easeOut),
      );
      _controller
        ..reset()
        ..forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = StoreGlass.of(context);
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, _) {
        return Container(
          height: widget.height,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(widget.height / 2),
          ),
          alignment: AlignmentDirectional.centerStart,
          child: FractionallySizedBox(
            widthFactor: _animation.value,
            alignment: AlignmentDirectional.centerStart,
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [tokens.accentSoft, tokens.accent],
                ),
                borderRadius: BorderRadius.circular(widget.height / 2),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// "Bin eats the label" delete button, ported from DeliveryFlow's
/// BinEatingDeleteButton (v27.29 behavior, the field-corrected one):
/// ONE bin — an open-top body with a single lid flush on its rim (no
/// detached line, no swinging). On tap: the lid lifts STRAIGHT UP and
/// holds, the label letters hop one-by-one DOWNWARD through the gap
/// into the bin from above (never sideways), the lid closes, a green
/// success check draws itself, and ONLY then [onConfirmed] fires
/// exactly once. Nothing is deleted before the animation completes;
/// taps are ignored while animating; under OS reduce-motion the
/// animation is skipped and [onConfirmed] fires directly.
///
/// v1.1.2: [autoplay] starts the animation on the first frame with
/// no tap — used after a delete CONFIRMATION dialog, so the flow is
/// confirm first, animation second, actual delete last. The button
/// itself never deletes anything; the caller deletes in [onConfirmed].
class BinEatingDeleteButton extends StatefulWidget {
  const BinEatingDeleteButton({
    super.key,
    required this.label,
    required this.onConfirmed,
    this.autoplay = false,
  });

  final String label;
  final VoidCallback onConfirmed;
  final bool autoplay;

  @override
  State<BinEatingDeleteButton> createState() =>
      _BinEatingDeleteButtonState();
}

const _totalDuration = Duration(milliseconds: 1400);
const _lidLiftDistance = 14.0;
const _dropDistance = 14.0;
const _hopHeight = 12.0;

class _BinEatingDeleteButtonState extends State<BinEatingDeleteButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _animating = false;
  bool _showCheck = false;
  bool _completed = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: _totalDuration)
      ..addListener(_onTick)
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed) _finish();
      });
    if (widget.autoplay) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _start();
      });
    }
  }

  void _onTick() {
    if (!_showCheck && _controller.value >= 0.82) {
      _showCheck = true;
      if (mounted) setState(() {});
    }
  }

  void _start() {
    if (_animating || _completed) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      _completed = true;
      widget.onConfirmed();
      return;
    }
    setState(() => _animating = true);
    _controller.forward();
  }

  void _finish() {
    if (!mounted || _completed) return;
    _completed = true;
    widget.onConfirmed();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  TextStyle _labelStyle(BuildContext context) {
    return Theme.of(context).textTheme.labelLarge ??
        const TextStyle(fontSize: 14, fontWeight: FontWeight.w700);
  }

  double _labelWidth(BuildContext context) {
    final painter = TextPainter(
      text: TextSpan(text: widget.label, style: _labelStyle(context)),
      textDirection: Directionality.of(context),
    )..layout();
    return painter.width + 24 + 16 + 32;
  }

  List<double> _letterWidths(BuildContext context) {
    final style = _labelStyle(context);
    final dir = Directionality.of(context);
    return widget.label.characters.map((c) {
      final painter = TextPainter(
        text: TextSpan(text: c, style: style),
        textDirection: dir,
      )..layout();
      return painter.width;
    }).toList();
  }

  double _lidLift(double t) {
    final up =
        const Interval(0.0, 0.15, curve: Curves.easeOut).transform(t);
    final down =
        const Interval(0.70, 0.82, curve: Curves.easeInOut).transform(t);
    return up * (1.0 - down);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = StoreGlass.of(context);
    final error = tokens.danger;
    final chars = widget.label.characters.toList();
    final widths = _letterWidths(context);
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final sign = rtl ? -1.0 : 1.0;
    final distances = List<double>.generate(chars.length, (i) {
      var after = 0.0;
      for (var j = i + 1; j < chars.length; j++) {
        after += widths[j];
      }
      return widths[i] / 2 + after + 8 + 12;
    });
    final stagger = chars.isEmpty
        ? 0.0
        : math.min(0.06, 0.40 / chars.length);

    return GestureDetector(
      onTap: _start,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
        width: _showCheck ? 48.0 : _labelWidth(context),
        height: 48,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: _showCheck ? tokens.success : tokens.dangerSoft,
          borderRadius: BorderRadius.circular(_showCheck ? 24 : 12),
        ),
        child: _showCheck
            ? AnimatedBuilder(
                animation: _controller,
                builder: (context, _) {
                  final progress =
                      ((_controller.value - 0.82) / 0.18).clamp(0.0, 1.0);
                  return CustomPaint(
                    key: const Key('binSuccessCheck'),
                    size: const Size(28, 28),
                    painter: _CheckPainter(progress),
                  );
                },
              )
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (var i = 0; i < chars.length; i++)
                        AnimatedBuilder(
                          animation: _controller,
                          builder: (context, child) {
                            final start = 0.15 + stagger * i;
                            final end = (start + 0.30).clamp(0.0, 0.70);
                            final p = Interval(start, end,
                                    curve: Curves.linear)
                                .transform(_controller.value);
                            final xProgress =
                                (p / 0.6).clamp(0.0, 1.0);
                            final dx = sign *
                                distances[i] *
                                Curves.easeIn.transform(xProgress);
                            double dy;
                            if (p < 0.6) {
                              dy = -_hopHeight *
                                  math.sin(math.pi * p / 0.6);
                            } else {
                              dy = _dropDistance * (p - 0.6) / 0.4;
                            }
                            final opacity = (p < 0.85
                                    ? 1.0
                                    : 1.0 - (p - 0.85) / 0.15)
                                .clamp(0.0, 1.0);
                            return Opacity(
                              opacity: opacity,
                              child: Transform.translate(
                                offset: Offset(dx, dy),
                                child: Transform.scale(
                                  scale: 1.0 - 0.85 * p,
                                  child: child,
                                ),
                              ),
                            );
                          },
                          child: Text(chars[i],
                              key: Key('binLetter_$i'),
                              style: _labelStyle(context).copyWith(
                                color: error,
                                fontWeight: FontWeight.w700,
                              )),
                        ),
                    ],
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    key: const Key('binIcon'),
                    width: 24,
                    height: 28,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned(
                          left: 3,
                          bottom: 0,
                          width: 18,
                          height: 20,
                          child: Container(
                            key: const Key('binBody'),
                            decoration: BoxDecoration(
                              border: Border(
                                left: BorderSide(color: error, width: 2),
                                right: BorderSide(color: error, width: 2),
                                bottom: BorderSide(color: error, width: 2),
                              ),
                              borderRadius:
                                  const BorderRadius.vertical(
                                bottom: Radius.circular(4),
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          left: 1,
                          bottom: 20,
                          width: 22,
                          height: 4,
                          child: AnimatedBuilder(
                            animation: _controller,
                            builder: (context, child) {
                              return Transform.translate(
                                offset: Offset(
                                    0,
                                    -_lidLift(_controller.value) *
                                        _lidLiftDistance),
                                child: child,
                              );
                            },
                            child: Container(
                              key: const Key('binLid'),
                              decoration: BoxDecoration(
                                color: error,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

/// Success check drawn stroke-by-stroke: circle arc first
/// (progress 0 → 0.55), then the check path (0.55 → 1).
class _CheckPainter extends CustomPainter {
  _CheckPainter(this.progress);
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 2;
    final circleProgress = (progress / 0.55).clamp(0.0, 1.0);
    if (circleProgress > 0) {
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        -0.5 * 3.14159,
        circleProgress * 2 * 3.14159,
        false,
        stroke,
      );
    }
    if (progress > 0.55) {
      final checkProgress = ((progress - 0.55) / 0.45).clamp(0.0, 1.0);
      final path = Path()
        ..moveTo(size.width * 0.28, size.height * 0.54)
        ..lineTo(size.width * 0.46, size.height * 0.72)
        ..lineTo(size.width * 0.74, size.height * 0.32);
      final metrics = path.computeMetrics().toList();
      if (metrics.isNotEmpty) {
        final extract =
            metrics.first.extractPath(0, metrics.first.length * checkProgress);
        canvas.drawPath(extract, stroke);
      }
    }
  }

  @override
  bool shouldRepaint(_CheckPainter old) => old.progress != progress;
}
