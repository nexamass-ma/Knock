import 'package:material_ui/material_ui.dart';

import '../../design/tokens.dart';
import '../../design/widgets/kit.dart';
import '../shell/nav.dart';

/// "Workings": how Knock works, step by step, for each product.
class WorkingsScreen extends StatelessWidget {
  const WorkingsScreen({super.key});

  static const _sections = [
    ('Selling a gift card', Icons.card_giftcard_rounded, [
      'Pick the brand, card currency and type, then enter the amount.',
      'See your payout before you submit. Some brands lock the rate for a few minutes; others show an indicative rate that is confirmed on review.',
      'Upload the card or enter the e-code. We check it with the brand.',
      'If the rate changes before we confirm, we ask you to continue with the new rate or cancel. We never apply a lower rate without asking.',
      'Once approved, your Naira lands in your wallet. You can follow every step in the Trade Tracker.',
    ]),
    ('Buying and selling crypto', Icons.currency_bitcoin_rounded, [
      'Get a quote. It holds for 30 seconds.',
      'Confirm with your PIN. The trade settles to your Naira or crypto balance immediately.',
    ]),
    ('Sending a gift', Icons.redeem_rounded, [
      'Choose a brand and amount, and who it is for: a Knock username, phone, email or a claim link.',
      'Pay from your wallet. The code is sealed; you never see it, and neither does anyone else.',
      'They get a gift to open. The code is revealed only after they confirm it is them.',
      'Gifts that are never claimed are refunded.',
    ]),
    ('Deposits and withdrawals', Icons.account_balance_rounded, [
      'Deposit by bank transfer to your Knock account details.',
      'Withdraw to a bank account in your own name once you are on Tier 2. A ₦50 fee applies.',
    ]),
    ('Rewards', Icons.military_tech_rounded, [
      'Welcome bonus: ₦100 after your first settled trade, held in your bonus balance.',
      'Referrals: ₦5,000 when a friend you invited completes \$500 in settled trades.',
      'Knock Points come from challenges. They have no cash value yet.',
    ]),
  ];

  @override
  Widget build(BuildContext context) {
    return KPage(title: 'How Knock works', subtitle: 'Your money moves when you do.', children: [
      for (final (title, icon, steps) in _sections) ...[
        SectionTitle(title),
        KnockCard(
          child: Column(children: [
            for (var i = 0; i < steps.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (i == 0) Icon(icon, color: KnockColors.greenBright, size: 22) else const SizedBox(width: 22),
                  const SizedBox(width: 10),
                  Container(
                    width: 22,
                    height: 22,
                    alignment: Alignment.center,
                    decoration: const BoxDecoration(color: KnockColors.surfaceHigh, shape: BoxShape.circle),
                    child: Text('${i + 1}', style: KnockText.micro.copyWith(color: KnockColors.textPrimary)),
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: Text(steps[i], style: KnockText.body)),
                ]),
              ),
          ]),
        ),
      ],
      const SizedBox(height: 16),
      KnockButton(label: 'See current rates', onPressed: () => Nav.rates(context)),
      const SizedBox(height: 8),
      KnockButton(label: 'Read the FAQ', style: KnockButtonStyle.secondary, onPressed: () => Nav.faq(context)),
    ]);
  }
}
