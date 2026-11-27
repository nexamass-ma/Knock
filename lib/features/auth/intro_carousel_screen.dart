import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../app/app_controller.dart';
import '../../design/tokens.dart';
import '../../design/widgets/surfaces.dart';

/// First-launch intro: three full-bleed photo slides shown before Welcome.
/// Photos are from Unsplash (Unsplash License), credited in Settings > Credits.
class IntroCarouselScreen extends StatefulWidget {
  const IntroCarouselScreen({super.key});

  @override
  State<IntroCarouselScreen> createState() => _IntroCarouselScreenState();
}

class _Slide {
  const _Slide(this.image, this.align, this.title, this.body, this.chips, this.semantic);
  final String image;
  final Alignment align;
  final String title;
  final String body;
  final List<(String, String, Alignment)> chips;
  final String semantic;
}

const _slides = [
  _Slide(
    'assets/onboarding/intro_1.jpg',
    Alignment(0, -0.2),
    'Your money.\nOne conversation.',
    'Sell gift cards and crypto, pay bills and top up airtime, all in one simple chat.',
    [('💬', 'Just ask Knock', Alignment(-0.85, -0.35)), ('⚡', 'Paid in minutes', Alignment(0.8, 0.05))],
    'A man relaxing on a couch, smiling at his phone',
  ),
  _Slide(
    'assets/onboarding/intro_2.jpg',
    Alignment(0, -0.35),
    'Gifts that feel\npersonal.',
    'Send a gift card to anyone by username, phone or link. They open it like a real present.',
    [('🎁', 'Gift sent', Alignment(0.8, -0.4)), ('💚', 'Opened!', Alignment(-0.8, 0.0))],
    'A woman in a red dress holding a wrapped gift box',
  ),
  _Slide(
    'assets/onboarding/intro_3.jpg',
    Alignment(0, -0.3),
    'Invite friends.\nEarn together.',
    'Refer friends, climb the leaderboard and unlock rewards every week.',
    [('🏆', 'Top 10 this week', Alignment(-0.8, -0.4)), ('🔥', '₦2,000 bonus', Alignment(0.82, 0.02))],
    'Three friends laughing and hugging outdoors',
  ),
];

class _IntroCarouselScreenState extends State<IntroCarouselScreen> with SingleTickerProviderStateMixin {
  final _pages = PageController();
  late final AnimationController _float = AnimationController(vsync: this, duration: const Duration(seconds: 3))..repeat();
  int _index = 0;

  @override
  void dispose() {
    _pages.dispose();
    _float.dispose();
    super.dispose();
  }

  bool get _last => _index == _slides.length - 1;

  void _next() {
    if (_last) {
      context.app.introDone();
    } else {
      _pages.nextPage(duration: KnockMotion.slow, curve: KnockMotion.curve);
    }
  }

  @override
  Widget build(BuildContext context) {
    final slide = _slides[_index];
    final inset = MediaQuery.paddingOf(context);
    return Scaffold(
      backgroundColor: KnockColors.background,
      body: Stack(
        children: [
          // Photos with floating chips; swipe to move between slides.
          Positioned.fill(
            child: PageView.builder(
              controller: _pages,
              itemCount: _slides.length,
              onPageChanged: (i) => setState(() => _index = i),
              itemBuilder: (_, i) => _Photo(slide: _slides[i], float: _float),
            ),
          ),
          // Progress pills and Skip.
          Positioned(
            top: inset.top + 14,
            left: 20,
            right: 12,
            child: Row(
              children: [
                for (var i = 0; i < _slides.length; i++)
                  AnimatedContainer(
                    duration: KnockMotion.base,
                    margin: const EdgeInsets.only(right: 6),
                    width: i == _index ? 26 : 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: i == _index ? KnockColors.green : Colors.white.withValues(alpha: 0.45),
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                const Spacer(),
                TextButton(
                  key: const ValueKey('intro-skip'),
                  onPressed: () => context.app.introDone(),
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.white,
                    backgroundColor: Colors.black.withValues(alpha: 0.28),
                    shape: const StadiumBorder(),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                  ),
                  child: const Text('Skip', style: TextStyle(fontWeight: FontWeight.w600)),
                ),
              ],
            ),
          ),
          // Bottom card.
          Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              width: double.infinity,
              padding: EdgeInsets.fromLTRB(24, 26, 24, 20 + inset.bottom),
              decoration: const BoxDecoration(
                color: KnockColors.surface,
                borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
                border: Border(top: BorderSide(color: KnockColors.strokeStrong)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AnimatedSwitcher(
                    duration: KnockMotion.base,
                    layoutBuilder: (current, previous) => Stack(alignment: Alignment.topLeft, children: [...previous, ?current]),
                    child: Column(
                      key: ValueKey(_index),
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(slide.title, style: KnockText.display.copyWith(fontSize: 32, height: 1.1)),
                        const SizedBox(height: 12),
                        Text(slide.body, style: KnockText.body.copyWith(color: KnockColors.textSecondary, fontSize: 15.5)),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  KnockButton(
                    key: const ValueKey('intro-next'),
                    label: _last ? 'Get Started' : 'Continue',
                    onPressed: _next,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Photo extends StatelessWidget {
  const _Photo({required this.slide, required this.float});
  final _Slide slide;
  final Animation<double> float;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Image.asset(
          slide.image,
          fit: BoxFit.cover,
          alignment: slide.align,
          semanticLabel: slide.semantic,
          errorBuilder: (_, _, _) => const DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment(0.6, -0.6),
                radius: 1.3,
                colors: [Color(0x6600B03C), Color(0x33FF5001), KnockColors.background],
                stops: [0, 0.5, 1],
              ),
            ),
          ),
        ),
        // Darken the top for the pills and the lower half for the card.
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0x66000000), Color(0x00000000), Color(0x00000000), Color(0xCC0A0A0E)],
              stops: [0, 0.22, 0.5, 0.72],
            ),
          ),
        ),
        // Floating emoji chips, above the bottom card.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 90, 16, 330),
          child: Stack(
            children: [
              for (var i = 0; i < slide.chips.length; i++)
                Align(
                  alignment: slide.chips[i].$3,
                  child: AnimatedBuilder(
                    animation: float,
                    builder: (_, child) => Transform.translate(
                      offset: Offset(0, 6 * math.sin(2 * math.pi * float.value + i * math.pi)),
                      child: child,
                    ),
                    child: _Chip(emoji: slide.chips[i].$1, label: slide.chips[i].$2),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.emoji, required this.label});
  final String emoji;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 7, 14, 7),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(40),
        boxShadow: const [BoxShadow(color: Color(0x40000000), blurRadius: 18, offset: Offset(0, 6))],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: const BoxDecoration(color: Color(0x1A00B03C), shape: BoxShape.circle),
            child: Text(emoji, style: const TextStyle(fontSize: 16)),
          ),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(color: Color(0xFF0A0A0E), fontWeight: FontWeight.w700, fontSize: 13.5)),
        ],
      ),
    );
  }
}
