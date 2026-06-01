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
                ],
              ),
            ),
            // Upper-left personal "backdoor" — small status notes the
            // author maintains about his daughters. Intentionally
            // nominal in size and position so it reads as a quiet
            // dedication caption, not a UI element. Update the strings
            // here whenever the statuses change.
            const Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text(
                  'Elle: future college student (age 16)\n'
                  'Lorelei: future state track champion, '
                  'and future final stage unicorn (age 14)',
                  style: TextStyle(
                    fontFamily: 'sans-serif',
                    fontSize: 8,
                    color: _cream,
                    height: 1.4,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
            ),
            // Long-form quote pinned to the bottom of the SafeArea.
            // Right-aligned non-italic sans-serif. Width-constrained to
            // the rendered width of the "binky" wordmark above, so the
            // quote's right edge lines up with the right edge of the "y"
            // (not the screen edge). Explicit line breaks between each
            // sentence so the rhythm reads as the rambling internal
            // monologue it actually is, not disclaimer text.
            // `sans-serif` resolves to Roboto on Android — the closest
            // commonly-available approximation of Helvetica. Quote
            // wording verified against the Regulation Podcast episode 92
            // transcript (~1:18 in).
            const Align(
              alignment: Alignment.bottomCenter,
              child: SizedBox(
                // Approximate width of the "binky" wordmark at fontSize 56
                // serif bold + letterSpacing 2. Tune by eye if the right
                // edge of the quote doesn't quite kiss the right edge of
                // the "y" in your rendered build.
                width: 180,
                child: Text(
                  'Did I deserve to live today or was I a waste of fucking space?\n'
                  'Did I take oxygen and give nothing back to humanity?\n'
                  'Should I have just not woken up this morning or did I do enough throughout the day to deserve my life?\n'
                  'And I feel like everybody probably does that.\n'
                  ' -Geoffrey Lazer Ramsey',
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontFamily: 'sans-serif',
                    fontSize: 8,
                    color: _cream,
                    height: 1.5,
                    letterSpacing: 0.2,
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
