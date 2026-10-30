// ST splash — modeled on DeliveryFlow's draw-then-fill splash rhythm:
// the monogram DRAWS itself (~1000ms), then FILLS with a diagonal
// sweep (~1000ms), then the app name fades in (~500ms). Total ~2500ms.
// Weighted, smooth motion, nothing popping in suddenly. Under OS
// reduce-motion the static filled mark shows and entry is immediate.
//
// The mark: a capital T as the outer frame (top bar + center stem)
// with a capital S nested inside it, centered on the stem below the
// bar — the "ST" monogram. White/gray theme: light-gray background,
// gray strokes, dark-gray fill.
import 'package:flutter/material.dart';

/// Splash stages in order. Pure function of animation progress so
/// widget tests can assert the sequence without pumping painters.
/// Fractions of the exact 2500ms total: draw 0–0.40, sweep 0.40–0.80,
/// name 0.80–1.00.
enum StSplashStage { drawing, sweeping, name, exiting }

StSplashStage stSplashStageFor(double t) {
  if (t < 0.40) return StSplashStage.drawing;
  if (t < 0.80) return StSplashStage.sweeping;
  if (t < 1.0) return StSplashStage.name;
  return StSplashStage.exiting;
}

/// The monogram's own coordinate space (160 x 160).
const Size _kMarkSpace = Size(160, 160);

/// The T frame as one closed outline path: top bar + center stem.
/// Stroking it draws the T outline; filling its two rects paints the
/// solid T.
Path stTOutlinePath() {
  final p = Path();
  p.moveTo(28, 24);
  p.lineTo(132, 24);
  p.lineTo(132, 44);
  p.lineTo(92, 44);
  p.lineTo(92, 136);
  p.lineTo(68, 136);
  p.lineTo(68, 44);
  p.lineTo(28, 44);
  p.close();
  return p;
}

/// The solid T: bar rect + stem rect.
Path stTFillPath() {
  final p = Path();
  p.addRect(const Rect.fromLTWH(28, 24, 104, 20));
  p.addRect(const Rect.fromLTWH(68, 44, 24, 92));
  return p;
}

/// The S nested inside the T: a centerline curve centered on the stem
/// below the bar. Stroked thin during the draw phase, stroked thick
/// (bold) for the filled mark.
Path stSPath() {
  final p = Path();
  p.moveTo(104, 66);
  p.cubicTo(104, 52, 90, 46, 78, 48);
  p.cubicTo(64, 50, 56, 60, 60, 72);
  p.cubicTo(64, 84, 78, 86, 88, 90);
  p.cubicTo(100, 94, 106, 104, 102, 114);
  p.cubicTo(98, 126, 82, 130, 70, 126);
  p.cubicTo(58, 122, 54, 112, 58, 104);
  return p;
}

/// Extracts the first [fraction] of [path] (across all contours, in
/// order) — the progressive "drawing" effect.
Path _extractPartial(Path path, double fraction) {
  if (fraction <= 0) return Path();
  if (fraction >= 1) return path;
  final metrics = path.computeMetrics().toList();
  var total = 0.0;
  for (final m in metrics) {
    total += m.length;
  }
  var remaining = total * fraction.clamp(0.0, 1.0);
  final out = Path();
  for (final m in metrics) {
    if (remaining <= 0) break;
    final take = remaining < m.length ? remaining : m.length;
    out.addPath(m.extractPath(0, take), Offset.zero);
    remaining -= take;
  }
  return out;
}

/// Clips the 160x160 box against the half-plane x - y <= [front].
/// Sutherland–Hodgman over the box corners.
List<Offset> _clipBox(double front) {
  final box = [
    const Offset(0, 0),
    const Offset(160, 0),
    const Offset(160, 160),
    const Offset(0, 160),
  ];
  double value(Offset p) => p.dx - p.dy;
  bool inside(Offset p) => value(p) <= front;
  Offset intersect(Offset a, Offset b) {
    final va = value(a);
    final vb = value(b);
    final t = (front - va) / (vb - va);
    return Offset(a.dx + (b.dx - a.dx) * t, a.dy + (b.dy - a.dy) * t);
  }

  var poly = box;
  var out = <Offset>[];
  for (var i = 0; i < poly.length; i++) {
    final cur = poly[i];
    final prev = poly[(i + poly.length - 1) % poly.length];
    final curIn = inside(cur);
    final prevIn = inside(prev);
    if (curIn) {
      if (!prevIn) out.add(intersect(prev, cur));
      out.add(cur);
    } else if (prevIn) {
      out.add(intersect(prev, cur));
    }
  }
  poly = out;
  out = [];
  return poly;
}

class _StMonogramPainter extends CustomPainter {
  _StMonogramPainter({
    required this.drawProgress,
    required this.sweepProgress,
  });

  final double drawProgress;
  final double sweepProgress;

  static const _strokeGray = Color(0xFF9E9E9E);
  static const _fillDark = Color(0xFF212121);
  static const _fillMid = Color(0xFF616161);

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / _kMarkSpace.width;
    canvas.save();
    canvas.scale(scale, scale);

    final thin = Paint()
      ..color = _strokeGray
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fill = Paint()
      ..color = _fillDark
      ..style = PaintingStyle.fill;

    // Ahead of the sweep: thin outlines (during draw, partial).
    final outline = Path()
      ..addPath(stTOutlinePath(), Offset.zero)
      ..addPath(stSPath(), Offset.zero);
    final drawn = _extractPartial(outline, drawProgress);
    canvas.drawPath(drawn, thin);

    // Glowing tip dot at the leading point of the draw.
    if (drawProgress > 0 && drawProgress < 1) {
      final metrics = outline.computeMetrics().toList();
      var total = 0.0;
      for (final m in metrics) {
        total += m.length;
      }
      var target = total * drawProgress;
      for (final m in metrics) {
        if (target <= m.length) {
          final pos = m.getTangentForOffset(target)?.position;
          if (pos != null) {
            canvas.drawCircle(
              pos,
              4,
              Paint()..color = _fillMid,
            );
          }
          break;
        }
        target -= m.length;
      }
    }

    // Behind the sweep: solid fills, clipped to the swept half-plane.
    if (sweepProgress > 0) {
      final front = -160 + sweepProgress.clamp(0.0, 1.0) * 320;
      final clip = _clipBox(front);
      if (clip.length >= 3) {
        canvas.save();
        canvas.clipPath(Path()..addPolygon(clip, true));
        canvas.drawPath(stTFillPath(), fill);
        // S in mid gray so it reads nested inside the dark T.
        final sPaint = Paint()
          ..color = _fillMid
          ..style = PaintingStyle.stroke
          ..strokeWidth = 11
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round;
        canvas.drawPath(stSPath(), sPaint);
        canvas.restore();
        // Sweep edge line: the diagonal x - y == front, clipped to
        // the box (endpoints depend on the sign of front).
        final edge = Paint()
          ..color = _strokeGray.withValues(alpha: 0.5)
          ..strokeWidth = 1.5;
        final Offset edgeA;
        final Offset edgeB;
        if (front <= 0) {
          edgeA = Offset(0, -front);
          edgeB = Offset(160 + front, 160);
        } else {
          edgeA = Offset(front, 0);
          edgeB = Offset(160, 160 - front);
        }
        canvas.drawLine(edgeA, edgeB, edge);
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_StMonogramPainter old) =>
      old.drawProgress != drawProgress ||
      old.sweepProgress != sweepProgress;
}

/// ST splash screen: draw (~1000ms) + sweep (~1000ms) + name fade
/// (~500ms) = exactly 2500ms, then [onDone].
class StSplashScreen extends StatefulWidget {
  const StSplashScreen({super.key, required this.onDone});
  final VoidCallback onDone;

  static const totalDuration = Duration(milliseconds: 2500);

  @override
  State<StSplashScreen> createState() => _StSplashScreenState();
}

class _StSplashScreenState extends State<StSplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _draw;
  late final Animation<double> _sweep;
  late final Animation<double> _name;
  bool _done = false;

  void _finish() {
    if (_done || !mounted) return;
    _done = true;
    widget.onDone();
  }

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: StSplashScreen.totalDuration,
    );
    _draw = _controller.drive(
      CurveTween(curve: const Interval(0.0, 0.40, curve: Curves.easeOut)),
    );
    _sweep = _controller.drive(
      CurveTween(curve: const Interval(0.40, 0.80, curve: Curves.easeInOut)),
    );
    _name = _controller.drive(
      CurveTween(curve: const Interval(0.80, 1.0, curve: Curves.easeOut)),
    );
    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed) _finish();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (MediaQuery.disableAnimationsOf(context)) {
        _finish();
      } else {
        _controller.forward();
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return Scaffold(
      backgroundColor: const Color(0xFFF2F2F7),
      body: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final draw = reduceMotion ? 1.0 : _draw.value;
          final sweep = reduceMotion ? 1.0 : _sweep.value;
          final nameOpacity = reduceMotion ? 1.0 : _name.value;
          return SafeArea(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CustomPaint(
                    key: const Key('stMonogram'),
                    size: const Size(160, 160),
                    painter: _StMonogramPainter(
                      drawProgress: draw,
                      sweepProgress: sweep,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Opacity(
                    key: const Key('stSplashName'),
                    opacity: nameOpacity,
                    child: const Text(
                      'إدارة المتجر',
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF212121),
                        letterSpacing: -0.5,
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
}
