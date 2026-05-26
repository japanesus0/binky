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
        child: Center(
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
            ],
          ),
        ),
      ),
    );
  }
}
