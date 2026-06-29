import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Nexemble brand blue.
const Color kNexembleBlue = Color(0xFF2328A0);

/// The full Nexemble cube (the four brand pieces) in blue, viewBox cropped
/// tightly around the mark so it fills the frame.
const String _cubeSvg =
    '<svg viewBox="34 36 32 32" xmlns="http://www.w3.org/2000/svg">'
    '<g transform="translate(50 52) scale(0.011) translate(-21895 -1320)" fill="#2328A0">'
    '<path d="M20895 1961.14V1219.43L21305.1 1496V2225.14L20895 1961.14Z"/>'
    '<path d="M21683.6 2501.71V1332.57L20895 773.143V678.857L21197.8 484L22112.7 1131.43V2501.71L21917.1 2640L21683.6 2501.71Z"/>'
    '<path d="M22895 1961.14L22503.8 2225.14H22478.6V898.857L21822.4 452.571L22213.6 207.429L22895 678.857V1961.14Z"/>'
    '<path d="M21904.5 0L21525.9 245.143L21690 364.571L22074.8 119.429L21904.5 0Z"/>'
    '</g></svg>';

double _easeInQuad(double t) => t * t;
double _easeOutQuad(double t) => t * (2 - t);
double _clamp01(double v) => v.clamp(0.0, 1.0);

// Decaying-bounce keyframes (seconds): drop in from the top, then four bounces
// of decreasing height, settling on the floor. Heights are "units above rest"
// (ported from the reference scene's bounce curve, retimed for ~3.5s).
const List<double> _bTimes =   [0.0, 0.60, 1.05, 1.50, 1.85, 2.10, 2.40, 2.55, 2.72, 2.90];
const List<double> _bHeights = [1383, 0,   603,  0,    403,  0,    193,  0,    63,   0];
const List<double> _contacts = [0.60, 1.50, 2.10, 2.55, 2.90];

double _bounceHeight(double s) {
  if (s <= _bTimes.first) return _bHeights.first;
  if (s >= _bTimes.last) return _bHeights.last;
  for (int i = 0; i < _bTimes.length - 1; i++) {
    if (s >= _bTimes[i] && s <= _bTimes[i + 1]) {
      final local = (s - _bTimes[i]) / (_bTimes[i + 1] - _bTimes[i]);
      final rising = _bHeights[i + 1] > _bHeights[i];
      final e = rising ? _easeOutQuad(local) : _easeInQuad(local); // gravity feel
      return _bHeights[i] + (_bHeights[i + 1] - _bHeights[i]) * e;
    }
  }
  return _bHeights.last;
}

// Squash-and-stretch pulse near each floor contact.
double _squash(double s) {
  double v = 0;
  for (final c in _contacts) {
    final d = (s - c).abs();
    if (d < 0.09) v = math.max(v, 1 - d / 0.09);
  }
  return v;
}

/// Plays the bouncing-cube loading screen over [child], then fades to reveal it.
class RevealGate extends StatefulWidget {
  final Widget child;
  const RevealGate({super.key, required this.child});

  @override
  State<RevealGate> createState() => _RevealGateState();
}

class _RevealGateState extends State<RevealGate> {
  bool _done = false;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        widget.child,
        if (!_done)
          NexembleReveal(
            onCompleted: () {
              if (mounted) setState(() => _done = true);
            },
          ),
      ],
    );
  }
}

/// The Nexemble cube drops in and bounces (decaying) with squash-and-stretch
/// on a light floor, settles, then the whole screen fades out.
class NexembleReveal extends StatefulWidget {
  final VoidCallback onCompleted;
  const NexembleReveal({super.key, required this.onCompleted});

  @override
  State<NexembleReveal> createState() => _NexembleRevealState();
}

class _NexembleRevealState extends State<NexembleReveal>
    with SingleTickerProviderStateMixin {
  static const double _dur = 3.6; // seconds
  static const double _fadeStart = 3.15;
  static const double _fadeEnd = 3.5;

  late final AnimationController _controller;
  late final Widget _cube;

  @override
  void initState() {
    super.initState();
    _cube = SvgPicture.string(_cubeSvg);
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3600),
    )..addStatusListener((status) {
        if (status == AnimationStatus.completed) widget.onCompleted();
      });
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final s = _controller.value * _dur;
        final overlayOpacity =
            1.0 - _clamp01((s - _fadeStart) / (_fadeEnd - _fadeStart));
        return Opacity(
          opacity: overlayOpacity,
          child: LayoutBuilder(
            builder: (context, c) {
              final w = c.maxWidth, h = c.maxHeight;
              final floorY = h * 0.65;
              final cube = math.min(w, h) * 0.42;
              final restTop = floorY - cube; // cube's base rests on the floor
              final hUnit = floorY / 1383.0; // drop starts just above the top
              final top = restTop - _bounceHeight(s) * hUnit;

              final sq = _squash(s);
              final sx = 1 + sq * 0.15;
              final sy = 1 - sq * 0.24;

              // subtle 3D wobble that decays after the cube settles
              final amp = (1 - _clamp01((s - 0.6) / 2.4)) * 0.13;
              final ry = amp * math.sin(s * 3.0 + 0.4);
              final rz = amp * 0.5 * math.sin(s * 1.9);

              final cubeBottom = top + cube;
              final close = _clamp01(1 - (floorY - cubeBottom) / (h * 0.16));
              final shW = cube * (0.72 + 0.5 * close) * sx;
              final shH = shW * 0.18;
              final shOp = 0.05 + 0.22 * close;
              final cx = w / 2;

              return Stack(
                children: [
                  // light surface with a soft floor tint
                  const Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Color(0xFFFFFFFF),
                            Color(0xFFFFFFFF),
                            Color(0xFFEEF1F8),
                            Color(0xFFE4E8F4),
                          ],
                          stops: [0.0, 0.64, 0.66, 1.0],
                        ),
                      ),
                    ),
                  ),
                  // floor highlight line
                  Positioned(
                    left: 0,
                    right: 0,
                    top: floorY - 1,
                    height: 2,
                    child: const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [Color(0x00FFFFFF), Color(0xE6FFFFFF), Color(0x00FFFFFF)],
                        ),
                      ),
                    ),
                  ),
                  // contact shadow
                  Positioned(
                    left: cx - shW / 2,
                    top: floorY - shH / 2,
                    width: shW,
                    height: shH,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: RadialGradient(
                          colors: [
                            Color.fromRGBO(30, 33, 120, shOp),
                            const Color(0x001E2178),
                          ],
                          stops: const [0.0, 0.72],
                        ),
                      ),
                    ),
                  ),
                  // the bouncing cube
                  Positioned(
                    left: cx - cube / 2,
                    top: top,
                    width: cube,
                    height: cube,
                    child: Transform(
                      alignment: Alignment.center,
                      transform: Matrix4.identity()
                        ..setEntry(3, 2, 0.0012)
                        ..rotateY(ry)
                        ..rotateZ(rz),
                      child: Transform.scale(
                        scaleX: sx,
                        scaleY: sy,
                        alignment: Alignment.bottomCenter,
                        child: _cube,
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }
}
