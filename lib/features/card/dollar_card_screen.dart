import 'dart:ui';

import 'package:material_ui/material_ui.dart';

import '../../app/app_scope.dart';
import '../../design/tokens.dart';
import '../../design/widgets/surfaces.dart';
import '../auth/wordmark.dart';

/// The KNOCK Dollar Card is visible but locked. It must not look usable
/// until an issuing partner and funding rails are integrated: no card
/// number, no balance, no spend controls.
class DollarCardScreen extends StatefulWidget {
  const DollarCardScreen({super.key});

  @override
  State<DollarCardScreen> createState() => _DollarCardScreenState();
}

class _DollarCardScreenState extends State<DollarCardScreen> {
  bool? _joined;
  bool _busy = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_joined == null) {
      context.app.services.waitlist.isOnWaitlist().then((v) {
        if (mounted) setState(() => _joined = v);
      });
    }
  }

  Future<void> _join() async {
    setState(() => _busy = true);
    await context.app.services.waitlist.joinWaitlist();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _joined = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    const features = [
      (Icons.currency_bitcoin_rounded, 'Fund from crypto sales', 'Top up from eligible crypto conversion proceeds.'),
      (Icons.card_giftcard_rounded, 'Fund from gift card sales', 'Move eligible gift card proceeds onto your card.'),
      (Icons.account_balance_wallet_outlined, 'Fund from your wallet', 'Use your available Naira wallet balance.'),
      (Icons.attach_money_rounded, 'Dollar spending balance', 'Hold a USD balance for online spending.'),
      (Icons.public_rounded, 'Pay online, worldwide', 'Subscriptions, shopping and services that take USD cards.'),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('Dollar card')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(KnockSpace.gutter, 8, KnockSpace.gutter, 48),
        children: [
          const _LockedCard(),
          const SizedBox(height: KnockSpace.xl),
          const Row(
            children: [Tag('Coming soon', color: KnockColors.orange, icon: Icons.lock_rounded)],
          ),
          const SizedBox(height: 12),
          const Text('A virtual dollar card for the internet', style: KnockText.title),
          const SizedBox(height: 8),
          Text(
            'We are working with a card issuing partner to launch the KNOCK Dollar Card. '
            'It is not active yet, and no card details exist until launch.',
            style: KnockText.body.copyWith(color: KnockColors.textSecondary),
          ),
          const SizedBox(height: KnockSpace.lg),
          Text('PLANNED FEATURES', style: KnockText.micro),
          const SizedBox(height: 10),
          for (final (icon, title, body) in features)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: KnockColors.surfaceRaised,
                      borderRadius: BorderRadius.circular(11),
                    ),
                    child: Icon(icon, size: 18, color: KnockColors.textSecondary),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: KnockText.bodyStrong),
                        Text(body, style: KnockText.caption),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: KnockSpace.md),
          AnimatedSwitcher(
            duration: KnockMotion.base,
            child: _joined == true
                ? KnockCard(
                    key: const ValueKey('joined'),
                    color: KnockColors.greenSoft,
                    child: Row(
                      children: [
                        const Icon(Icons.notifications_active_outlined, color: KnockColors.green),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            "You're on the early-access list. We'll notify you when the card opens.",
                            style: KnockText.body,
                          ),
                        ),
                      ],
                    ),
                  )
                : KnockButton(
                    key: const ValueKey('join'),
                    label: 'Notify me at launch',
                    icon: Icons.notifications_none_rounded,
                    loading: _busy || _joined == null,
                    onPressed: _join,
                  ),
          ),
          const SizedBox(height: 10),
          Text(
            'Availability depends on partner approval and regulation.',
            style: KnockText.micro.copyWith(fontWeight: FontWeight.w400),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _LockedCard extends StatelessWidget {
  const _LockedCard();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'KNOCK Dollar Card preview, locked',
      excludeSemantics: true,
      child: AspectRatio(
        aspectRatio: 1.586,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(KnockRadius.lg),
          child: Stack(
            fit: StackFit.expand,
            children: [
              const DecoratedBox(decoration: BoxDecoration(gradient: KnockColors.dollarCardGradient)),
              Positioned(
                right: -60,
                top: -60,
                child: Container(
                  width: 220,
                  height: 220,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(colors: [Color(0x40FF5001), Color(0x00FF5001)]),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        KnockWordmark(size: 14),
                        Spacer(),
                        Text(
                          'USD',
                          style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w700, letterSpacing: 1.2),
                        ),
                      ],
                    ),
                    const Spacer(),
                    Container(
                      width: 42,
                      height: 30,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(6),
                        gradient: const LinearGradient(colors: [Color(0xFFD9C48B), Color(0xFF9C8A5A)]),
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      '••••  ••••  ••••  ••••',
                      style: TextStyle(
                        color: Colors.white60,
                        fontSize: 18,
                        letterSpacing: 2,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text('VIRTUAL', style: TextStyle(color: Colors.white38, fontSize: 11, letterSpacing: 2)),
                  ],
                ),
              ),
              BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 3, sigmaY: 3),
                child: Container(
                  color: Colors.black.withValues(alpha: 0.28),
                  alignment: Alignment.center,
                  child: Container(
                    width: 58,
                    height: 58,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.black.withValues(alpha: 0.45),
                      border: Border.all(color: Colors.white24),
                    ),
                    child: const Icon(Icons.lock_rounded, color: Colors.white, size: 26),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
