import 'package:flutter/material.dart';

/// Flutter-rendered splash that runs after the OS-level splash hands off to
/// our process. The `b` bounces, `binky` stays put, then a fade transition
/// hands control to [next].
class SplashScreen extends StatefulWidget {
  final Widget next;
  const SplashScreen({super.key, required this.next});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  static const _brown = Color(0xFF6B4423);
  static const _cream = Color(0xFFF5E6D3);

  /// How long the splash stays on screen before transitioning. Two full
  /// bounce cycles plus a tiny pause feels right.
  static const _totalSplashDuration = Duration(milliseconds: 2000);
  static const _bouncePeriod = Duration(milliseconds: 900);
  static const _crossfadeDuration = Duration(milliseconds: 350);

  late final AnimationController _controller;
  late final Animation<double> _bounce;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: _bouncePeriod,
      vsync: this,
    )..repeat();

    // Two-phase tween: smooth ease-out going up, bounce-out coming down.
    // Reads as "lifted then dropped onto a surface" rather than symmetric sine.
    _bounce = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(begin: 0.0, end: -55.0)
            .chain(CurveTween(curve: Curves.easeOut)),
        weight: 45,
      ),
      TweenSequenceItem(
        tween: Tween<double>(begin: -55.0, end: 0.0)
            .chain(CurveTween(curve: Curves.bounceOut)),
        weight: 55,
      ),
    ]).animate(_controller);

    Future.delayed(_totalSplashDuration, _advance);
  }

  void _advance() {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => widget.next,
        transitionDuration: _crossfadeDuration,
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _brown,
      body: SafeArea(
        child: Stack(
          children: [
            // Logo + wordmark, centered. Same as before — using a Stack
            // (rather than a single Column) so the bottom quote can be
            // independently positioned without shifting the centered
            // block.
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Bouncing b — translates vertically. The decoration is a
                  // const subtree so AnimatedBuilder doesn't rebuild it per
                  // frame; only the Transform wrapper rebuilds.
                  AnimatedBuilder(
                    animation: _bounce,
                    builder: (_, child) => Transform.translate(
                      offset: Offset(0, _bounce.value),
                      child: child,
                    ),
                    child: Container(
                      width: 160,
                      height: 160,
                      decoration: const BoxDecoration(
                        color: _cream,
                        shape: BoxShape.circle,
                      ),
                      alignment: Alignment.center,
                      child: const Text(
                        'b',
                        style: TextStyle(
                          fontFamily: 'serif',
                          fontSize: 120,
                          fontWeight: FontWeight.bold,
                          color: _brown,
                          height: 1.0,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 36),
                  // Static wordmark — never moves.
                  const Text(
                    'binky',
                    style: TextStyle(
                      fontFamily: 'serif',
                      fontSize: 56,
                      fontWeight: FontWeight.bold,
                      color: _cream,
                      letterSpacing: 2,
                    ),
                  ),
                  const SizedBox(height: 28),
                  // Brand tagline. Light italic serif, two lines centered.
                  // Sets the product philosophy ("don't watch the clock,
                  // we'll signal you") before the home screen takes over.
                  // The em-dash break is explicit rather than auto-wrap
                  // so the line break lands on the rhetorical pause
                  // regardless of screen width.
                  //
                  // PLACEHOLDER: the wording, weight, and overall splash
                  // composition are pre-designer-engagement. The graphics
                  // artist working on the launcher icon and feature
                  // graphic is expected to revisit this layout — keep
                  // typography choices flexible (no embedded SVGs, no
                  // pixel-fitted artwork) so a redesign is a straight
                  // text/style edit rather than a structural rewrite.
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 32),
                    child: Text(
                      'Tea time should be free of distraction\n'
                      '— we\'ll tell you when to enjoy.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontFamily: 'serif',
                        fontStyle: FontStyle.italic,
                        fontSize: 15,
                        color: _cream,
                        height: 1.45,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // Lower-left credits-style line. Small upright sans-serif —
            // "Powered by" bold to read as the label, the names that
            // follow in regular weight to read as the attribution. The
            // brew-complete notification system is dedicated to the
            // author's daughters; this is its public credit.
            const Align(
              alignment: Alignment.bottomLeft,
              child: Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text.rich(
                  TextSpan(
                    style: TextStyle(
                      fontFamily: 'sans-serif',
                      fontSize: 9,
                      color: _cream,
                      letterSpacing: 0.2,
                    ),
                    children: [
                      TextSpan(
                        text: 'Powered by',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      TextSpan(text: ': Elle and Lorelei'),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
