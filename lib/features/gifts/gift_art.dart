import 'dart:math';

import 'package:material_ui/material_ui.dart';

import '../../design/tokens.dart';

/// Illustrated gift card face used across Gift Send.
class GiftCardArt extends StatelessWidget {
  const GiftCardArt({super.key, required this.brand, required this.glyph, required this.color, required this.valueLabel, this.height = 180});
  final String brand;
  final String glyph;
  final int color;
  final String valueLabel;
  final double height;

  @override
  Widget build(BuildContext context) {
    final c = Color(color);
    return Container(
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(KnockRadius.lg),
        gradient: LinearGradient(colors: [Color.lerp(c, Colors.black, 0.55)!, Color.lerp(c, const Color(0xFF0A4A23), 0.6)!, const Color(0xFF14141A)], begin: Alignment.topLeft, end: Alignment.bottomRight),
        boxShadow: [BoxShadow(color: c.withValues(alpha: 0.25), blurRadius: 30, offset: const Offset(0, 12))],
      ),
      child: Stack(children: [
        Positioned(right: -20, top: -20, child: Icon(Icons.redeem_rounded, size: height * 0.9, color: Colors.white.withValues(alpha: 0.06))),
        Padding(
          padding: const EdgeInsets.all(20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(
                width: 38,
                height: 38,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(12)),
                child: Text(glyph, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: Colors.white)),
              ),
              const SizedBox(width: 10),
              Text(brand, style: KnockText.headline),
              const Spacer(),
              const Icon(Icons.card_giftcard_rounded, color: KnockColors.orange),
            ]),
            const Spacer(),
            Text(valueLabel, style: KnockText.display),
            Text('Gift card · Sent with Knock', style: KnockText.caption.copyWith(color: Colors.white70)),
          ]),
        ),
      ]),
    );
  }
}

/// Wrapped present that shakes and bursts open when tapped.
class GiftBox extends StatefulWidget {
  const GiftBox({super.key, required this.onOpened, this.size = 170});
  final VoidCallback onOpened;
  final double size;
  @override
  State<GiftBox> createState() => _GiftBoxState();
}

class _GiftBoxState extends State<GiftBox> with TickerProviderStateMixin {
  late final _idle = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))..repeat(reverse: true);
  late final _open = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));
  bool _opening = false;

  @override
  void dispose() {
    _idle.dispose();
    _open.dispose();
    super.dispose();
  }

  Future<void> _tap() async {
    if (_opening) return;
    _opening = true;
    await _open.forward();
    widget.onOpened();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    return Semantics(
      button: true,
      label: 'Open your gift',
      child: GestureDetector(
        key: const ValueKey('gift-box'),
        onTap: _tap,
        child: AnimatedBuilder(
          animation: Listenable.merge([_idle, _open]),
          builder: (_, _) {
            final o = _open.value;
            final shake = o < 0.45 ? sin(o * 60) * 0.08 * (1 - o / 0.45) : 0.0;
            final lift = o > 0.45 ? Curves.easeOutBack.transform(((o - 0.45) / 0.55).clamp(0, 1)) : 0.0;
            return SizedBox(
              width: s * 1.6,
              height: s * 1.5,
              child: Stack(alignment: Alignment.center, children: [
                // Glow
                Container(
                  width: s * (1.1 + lift * 0.5),
                  height: s * (1.1 + lift * 0.5),
                  decoration: BoxDecoration(shape: BoxShape.circle, gradient: RadialGradient(colors: [KnockColors.orange.withValues(alpha: 0.35 + 0.3 * lift), Colors.transparent])),
                ),
                // Confetti
                if (lift > 0)
                  for (var i = 0; i < 14; i++)
                    Transform.translate(
                      offset: Offset(cos(i * 0.45) * s * 0.75 * lift, -sin(i * 0.45 + 0.3) * s * 0.65 * lift),
                      child: Opacity(opacity: (1 - lift * 0.6).clamp(0, 1), child: Container(width: 8, height: 8, decoration: BoxDecoration(color: i.isEven ? KnockColors.green : KnockColors.orange, borderRadius: BorderRadius.circular(2)))),
                    ),
                Transform.rotate(
                  angle: shake,
                  child: Transform.translate(
                    offset: Offset(0, -6 * _idle.value * (1 - o)),
                    child: SizedBox(
                      width: s,
                      height: s,
                      child: Stack(children: [
                        // Box body
                        Positioned(left: s * 0.08, right: s * 0.08, bottom: 0, height: s * 0.62, child: Container(decoration: BoxDecoration(color: KnockColors.green, borderRadius: BorderRadius.circular(14)))),
                        Positioned(left: s * 0.44, width: s * 0.12, bottom: 0, height: s * 0.62, child: Container(color: KnockColors.orange)),
                        // Lid
                        Positioned(
                          left: 0,
                          right: 0,
                          top: s * 0.22 - lift * s * 0.35,
                          height: s * 0.2,
                          child: Transform.rotate(
                            angle: -0.5 * lift,
                            child: Stack(children: [
                              Container(decoration: BoxDecoration(color: KnockColors.greenBright, borderRadius: BorderRadius.circular(12))),
                              Positioned(left: s * 0.44, width: s * 0.12, top: 0, bottom: 0, child: Container(color: KnockColors.orange)),
                            ]),
                          ),
                        ),
                        // Bow
                        Positioned(
                          left: s * 0.32,
                          top: s * 0.06 - lift * s * 0.35,
                          child: Opacity(opacity: 1 - lift, child: Icon(Icons.auto_awesome_rounded, size: s * 0.36, color: KnockColors.orange)),
                        ),
                      ]),
                    ),
                  ),
                ),
              ]),
            );
          },
        ),
      ),
    );
  }
}

String giftStatusLabel(String s) => switch (s) {
      'payment_pending' => 'Payment pending',
      'preparing' => 'Gift being prepared',
      'sent' => 'Gift sent',
      'awaiting_claim' => 'Waiting to be claimed',
      'delivered' => 'Gift delivered',
      'opened' => 'Gift opened',
      'redeemed' => 'Gift redeemed',
      'traded' => 'Traded on Knock',
      'expired' => 'Gift expired',
      'failed' => 'Delivery failed',
      _ => s,
    };
