import 'package:material_ui/material_ui.dart';

import '../../api/api.dart';
import '../../app/app_controller.dart';
import '../../design/tokens.dart';
import '../../design/widgets/kit.dart';

class _GuidePage {
  const _GuidePage(this.icon, this.color, this.title, this.body);
  final IconData icon;
  final Color color;
  final String title;
  final String body;
}

const _pages = [
  _GuidePage(Icons.waving_hand_rounded, KnockColors.green, 'Welcome to Knock', 'Your money moves when you do. Here is a quick look at what you can do. It takes 30 seconds, and you can skip any time.'),
  _GuidePage(Icons.card_giftcard_rounded, KnockColors.orange, 'Sell gift cards', 'Pick a card, see the rate and your payout before you submit, then track every step until the money lands in your wallet.'),
  _GuidePage(Icons.currency_bitcoin_rounded, Color(0xFFF7931A), 'Sell crypto', 'Sell BTC, ETH, USDT and more at a locked quote. Your naira is in your wallet the moment the trade completes.'),
  _GuidePage(Icons.account_balance_rounded, KnockColors.greenBright, 'Receive payments', 'Fund your wallet by bank transfer to your own account number, then withdraw to any Nigerian bank once you are verified.'),
  _GuidePage(Icons.redeem_rounded, Color(0xFFE85D9C), 'Send a gift', 'Send a gift card to anyone by username, phone, email or a private link. They get a gift to open, not a code in a text.'),
  _GuidePage(Icons.group_add_rounded, Color(0xFF7FA7FF), 'Invite friends', 'Earn ₦5,000 for every friend who joins and trades \$500 in eligible volume. Share your link in one tap.'),
  _GuidePage(Icons.emoji_events_rounded, Color(0xFFFFC542), 'Rewards that add up', 'Complete Knockout challenges, join Fire Load campaigns and climb VIP levels for better rates.'),
];

/// The skippable product guide shown after sign-up and from Settings.
class GuideScreen extends StatefulWidget {
  const GuideScreen({super.key, this.onDone});
  final VoidCallback? onDone;
  @override
  State<GuideScreen> createState() => _GuideScreenState();
}

class _GuideScreenState extends State<GuideScreen> {
  final _pc = PageController();
  int _i = 0;

  Future<void> _finish() async {
    final app = context.app;
    try {
      final r = await app.api.call((s, t) => s.updateSettings(t!, guideSeen: true));
      app.updateMe(r['user'] as Json);
    } catch (_) {}
    if (!mounted) return;
    if (widget.onDone != null) {
      widget.onDone!();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final last = _i == _pages.length - 1;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 8, 0),
              child: Row(children: [
                Text('${_i + 1} of ${_pages.length}', style: KnockText.caption),
                const Spacer(),
                TextButton(key: const ValueKey('guide-skip'), onPressed: _finish, child: Text('Skip', style: KnockText.bodyStrong.copyWith(color: KnockColors.textSecondary))),
              ]),
            ),
            Expanded(
              child: PageView.builder(
                controller: _pc,
                itemCount: _pages.length,
                onPageChanged: (i) => setState(() => _i = i),
                itemBuilder: (_, i) {
                  final p = _pages[i];
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 28),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        TweenAnimationBuilder<double>(
                          key: ValueKey(i),
                          tween: Tween(begin: 0.6, end: 1),
                          duration: const Duration(milliseconds: 700),
                          curve: Curves.elasticOut,
                          builder: (_, v, c) => Transform.scale(scale: v, child: c),
                          child: Container(
                            width: 148,
                            height: 148,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: RadialGradient(colors: [p.color.withValues(alpha: 0.45), p.color.withValues(alpha: 0.05)]),
                            ),
                            child: Icon(p.icon, size: 64, color: p.color),
                          ),
                        ),
                        const SizedBox(height: 36),
                        Text(p.title, style: KnockText.title.copyWith(fontSize: 28), textAlign: TextAlign.center),
                        const SizedBox(height: 12),
                        Text(p.body, style: KnockText.body.copyWith(color: KnockColors.textSecondary, fontSize: 16), textAlign: TextAlign.center),
                      ],
                    ),
                  );
                },
              ),
            ),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              for (var k = 0; k < _pages.length; k++)
                AnimatedContainer(
                  duration: KnockMotion.base,
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: k == _i ? 20 : 7,
                  height: 7,
                  decoration: BoxDecoration(color: k == _i ? KnockColors.green : KnockColors.surfaceHigh, borderRadius: BorderRadius.circular(7)),
                ),
            ]),
            Padding(
              padding: const EdgeInsets.all(20),
              child: KnockButton(
                key: const ValueKey('guide-next'),
                label: last ? 'Get started' : 'Next',
                onPressed: last ? _finish : () => _pc.nextPage(duration: KnockMotion.slow, curve: KnockMotion.curve),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One step of the dashboard tour: a highlighted widget and a caption.
class TourStep {
  const TourStep(this.target, this.title, this.body);
  final GlobalKey target;
  final String title;
  final String body;
}

/// Spotlight tour over the dashboard. Skippable at every step.
Future<void> showTour(BuildContext context, List<TourStep> steps) async {
  final visible = steps.where((s) => s.target.currentContext != null).toList();
  if (visible.isEmpty) return;
  await Navigator.of(context).push(PageRouteBuilder<void>(
    opaque: false,
    barrierDismissible: false,
    transitionDuration: KnockMotion.base,
    pageBuilder: (_, _, _) => _Tour(steps: visible),
    transitionsBuilder: (_, a, _, c) => FadeTransition(opacity: a, child: c),
  ));
}

class _Tour extends StatefulWidget {
  const _Tour({required this.steps});
  final List<TourStep> steps;
  @override
  State<_Tour> createState() => _TourState();
}

class _TourState extends State<_Tour> {
  int _i = 0;

  Rect? _rect() {
    final ctx = widget.steps[_i].target.currentContext;
    final box = ctx?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return null;
    return (box.localToGlobal(Offset.zero) & box.size).inflate(6);
  }

  @override
  Widget build(BuildContext context) {
    final step = widget.steps[_i];
    final r = _rect();
    final size = MediaQuery.sizeOf(context);
    final below = r == null || r.center.dy < size.height / 2;
    final last = _i == widget.steps.length - 1;
    return Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          Positioned.fill(child: CustomPaint(painter: _Hole(r))),
          if (r != null)
            AnimatedPositioned(
              duration: KnockMotion.base,
              left: r.left,
              top: r.top,
              width: r.width,
              height: r.height,
              child: IgnorePointer(
                child: Container(decoration: BoxDecoration(borderRadius: BorderRadius.circular(20), border: Border.all(color: KnockColors.green, width: 2))),
              ),
            ),
          AnimatedPositioned(
            duration: KnockMotion.base,
            curve: KnockMotion.curve,
            left: 20,
            right: 20,
            top: below ? (r?.bottom ?? 120) + 14 : null,
            bottom: below ? null : size.height - r.top + 14,
            child: KnockCard(
              color: KnockColors.surfaceRaised,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${_i + 1} of ${widget.steps.length}', style: KnockText.micro),
                  const SizedBox(height: 6),
                  Text(step.title, style: KnockText.headline),
                  const SizedBox(height: 4),
                  Text(step.body, style: KnockText.body.copyWith(color: KnockColors.textSecondary)),
                  const SizedBox(height: 14),
                  Row(children: [
                    TextButton(key: const ValueKey('tour-skip'), onPressed: () => Navigator.pop(context), child: Text('Skip tour', style: KnockText.bodyStrong.copyWith(color: KnockColors.textSecondary))),
                    const Spacer(),
                    KnockButton(
                      key: const ValueKey('tour-next'),
                      label: last ? 'Done' : 'Next',
                      expand: false,
                      onPressed: () => last ? Navigator.pop(context) : setState(() => _i++),
                    ),
                  ]),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Hole extends CustomPainter {
  _Hole(this.r);
  final Rect? r;
  @override
  void paint(Canvas canvas, Size size) {
    final p = Path()..addRect(Offset.zero & size);
    if (r != null) p.addRRect(RRect.fromRectAndRadius(r!, const Radius.circular(20)));
    p.fillType = PathFillType.evenOdd;
    canvas.drawPath(p, Paint()..color = const Color(0xCC000000));
  }

  @override
  bool shouldRepaint(_Hole old) => old.r != r;
}
