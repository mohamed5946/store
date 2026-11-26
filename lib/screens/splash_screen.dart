// Blob-ST splash — modeled on DeliveryFlow's draw-then-fill splash rhythm:
// the mark DRAWS itself (~1000ms), then FILLS with a diagonal
// sweep (~1000ms), then the app name fades in (~500ms). Total ~2500ms.
// Weighted, smooth motion, nothing popping in suddenly. Under OS
// reduce-motion the static filled mark shows and entry is immediate.
//
// The mark: a glossy blue liquid blob on a dark navy tile, with the
// letters S and T side by side carved into it as dark cut-outs — the
// approved blob-ST design (user pick 2026-10-30). The launcher icon
// carries the exact artwork; this painter is the animated schematic
// of the same mark: blob outline, then S + T outlines, then the
// diagonal sweep reveals the filled blob with its carved letters.
// The blue is LONA's blob blue (#3b5bff family), so the mark already
// reads as LONA glass; Phase 1 only re-tones the screen background
// and the name to the token contract.
import 'package:flutter/material.dart';

import '../theme/store_design.dart';

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

/// The mark's own coordinate space (160 x 160).
const Size _kMarkSpace = Size(160, 160);

/// The liquid blob: one closed wobbly outline, centered in the box.
Path blobOutlinePath() {
  final p = Path();
  p.moveTo(80, 20);
  p.cubicTo(104, 20, 126, 32, 136, 54);
  p.cubicTo(146, 76, 140, 100, 126, 116);
  p.cubicTo(112, 132, 96, 144, 80, 144);
  p.cubicTo(64, 144, 48, 132, 34, 116);
  p.cubicTo(20, 100, 14, 76, 24, 54);
  p.cubicTo(34, 32, 56, 20, 80, 20);
  p.close();
  return p;
}

/// The S carved on the left of the blob: a centerline curve, stroked
/// thick (bold) for the carved letter.
Path blobSPath() {
  final p = Path();
  p.moveTo(68, 70);
  p.cubicTo(68, 58, 56, 52, 46, 55);
  p.cubicTo(36, 58, 33, 68, 39, 76);
  p.cubicTo(45, 84, 57, 86, 62, 92);
  p.cubicTo(68, 99, 66, 110, 56, 115);
  p.cubicTo(46, 120, 35, 116, 33, 106);
  return p;
}

/// The T carved on the right of the blob, as one closed outline:
/// top bar + center stem.
Path blobTOutlinePath() {
  final p = Path();
  p.moveTo(86, 50);
  p.lineTo(134, 50);
  p.lineTo(134, 66);
  p.lineTo(117, 66);
  p.lineTo(117, 122);
  p.lineTo(103, 122);
  p.lineTo(103, 66);
  p.lineTo(86, 66);
  p.close();
  return p;
}

/// The solid T: bar rect + stem rect.
Path blobTFillPath() {
  final p = Path();
  p.addRect(const Rect.fromLTWH(86, 50, 48, 16));
  p.addRect(const Rect.fromLTWH(103, 66, 14, 56));
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

class _BlobStPainter extends CustomPainter {
  _BlobStPainter({
    required this.drawProgress,
    required this.sweepProgress,
  });

  final double drawProgress;
  final double sweepProgress;

  static const _outlineLight = Color(0xFF8FC7FF);
  static const _carveDark = Color(0xFF0A1730);
  static const _blobTop = Color(0xFF3D9BFF);
  static const _blobBottom = Color(0xFF1B5FC4);

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / _kMarkSpace.width;
    canvas.save();
    canvas.scale(scale, scale);

    final thin = Paint()
      ..color = _outlineLight
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // Ahead of the sweep: thin outlines (during draw, partial).
    final outline = Path()
      ..addPath(blobOutlinePath(), Offset.zero)
      ..addPath(blobSPath(), Offset.zero)
      ..addPath(blobTOutlinePath(), Offset.zero);
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
              Paint()..color = _outlineLight,
            );
          }
          break;
        }
        target -= m.length;
      }
    }

    // Behind the sweep: the filled blob + carved letters, clipped to
    // the swept half-plane.
    if (sweepProgress > 0) {
      final front = -160 + sweepProgress.clamp(0.0, 1.0) * 320;
      final clip = _clipBox(front);
      if (clip.length >= 3) {
        canvas.save();
        canvas.clipPath(Path()..addPolygon(clip, true));
        // Blob fill, clipped to the blob outline.
        canvas.save();
        canvas.clipPath(blobOutlinePath());
        canvas.drawRect(
          const Rect.fromLTWH(0, 0, 160, 160),
          Paint()
            ..shader = const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [_blobTop, _blobBottom],
            ).createShader(const Rect.fromLTWH(0, 0, 160, 160)),
        );
        canvas.restore();
        // Carved letters: a light under-edge first (light catching
        // the cut), then the dark cut-out on top.
        final carveLight = Paint()
          ..color = _outlineLight.withValues(alpha: 0.35)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 11
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round;
        canvas.save();
        canvas.translate(0, 1.5);
        canvas.drawPath(blobSPath(), carveLight);
        canvas.restore();
        final carveDark = Paint()
          ..color = _carveDark
          ..style = PaintingStyle.stroke
          ..strokeWidth = 11
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round;
        canvas.drawPath(blobSPath(), carveDark);
        canvas.drawPath(
          blobTFillPath(),
          Paint()
            ..color = _carveDark
            ..style = PaintingStyle.fill,
        );
        canvas.restore();
        // Sweep edge line: the diagonal x - y == front, clipped to
        // the box (endpoints depend on the sign of front).
        final edge = Paint()
          ..color = _outlineLight.withValues(alpha: 0.5)
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
  bool shouldRepaint(_BlobStPainter old) =>
      old.drawProgress != drawProgress ||
      old.sweepProgress != sweepProgress;
}

/// Blob-ST splash screen: draw (~1000ms) + sweep (~1000ms) + name
/// fade (~500ms) = exactly 2500ms, then [onDone].
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
    final tokens = StoreGlassTokens.liquidGloss;
    return Scaffold(
      backgroundColor: tokens.base,
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
                    painter: _BlobStPainter(
                      drawProgress: draw,
                      sweepProgress: sweep,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Opacity(
                    key: const Key('stSplashName'),
                    opacity: nameOpacity,
                    child: Text(
                      'إدارة المتجر',
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                        color: tokens.textPrimary,
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
