// Store Admin interaction ports — DeliveryFlow patterns restyled
// under the Flow dark visual language (see lib/theme/flow_theme.dart):
// tactile Pressable, staggered entrance, and the bin-eats-label
// delete confirmation. Colors come from FlowPalette; this file holds
// no theme of its own anymore (the white/gray era is gone).

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
/// stagger, capped at index 7, 300ms per item. Entry-only per mount;
/// a fresh mount (e.g. tab switch via the shell's keyed subtree)
/// replays it. Reduce-motion: items appear immediately.
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
  final Set<int> _seen = {};
  bool isSeen(int index) => _seen.contains(index);
  void markSeen(int index) => _seen.add(index);

  @override
  Widget build(BuildContext context) {
    return _StaggeredInherited(state: this, child: widget.child);
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
  bool _played = false;

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
    if (_played) return;
    _played = true;
    if (MediaQuery.disableAnimationsOf(context)) {
      _immediate = true;
      return;
    }
    final scope = StaggeredScope.maybeOf(context);
    if (scope != null && scope.isSeen(widget.index)) {
      _immediate = true;
      return;
    }
    scope?.markSeen(widget.index);
    _timer = Timer(StaggeredItem.delayFor(widget.index), () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
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
    const error = FlowPalette.danger;
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
          color: _showCheck ? FlowPalette.success : FlowPalette.dangerSoft,
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
