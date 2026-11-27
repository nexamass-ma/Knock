import 'package:material_ui/material_ui.dart';

import '../../design/tokens.dart';
import '../../design/widgets/kit.dart';
import 'coming_soon.dart';

class KnockAiScreen extends StatelessWidget {
  const KnockAiScreen({super.key});

  static const prompts = [
    'What is my best rate for a \$100 Apple card today?',
    'Why is my trade still pending?',
    'How much did I spend on data this month?',
    'Remind me when the Steam rate goes above ₦1,300.',
    'Explain the referral rules simply.',
  ];

  @override
  Widget build(BuildContext context) {
    return KPage(title: 'Knock AI', children: [
      KnockCard(
        gradient: KnockColors.heroGradient,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.auto_awesome_rounded, color: KnockColors.orange),
            const SizedBox(width: 8),
            Text('Coming soon', style: KnockText.caption.copyWith(color: KnockColors.orange)),
          ]),
          const SizedBox(height: 10),
          Text('Your money. One conversation.', style: KnockText.title),
          const SizedBox(height: 6),
          Text('Ask about rates, trades and your spending in plain English. Knock AI will explain and guide you.', style: KnockText.body.copyWith(color: Colors.white70)),
        ]),
      ),
      const SectionTitle('Things you will be able to ask'),
      for (final p in prompts)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: KnockCard(
            onTap: () => toast(context, 'Knock AI is not live yet. Join the list to try it first.'),
            child: Row(children: [
              const Icon(Icons.chat_bubble_outline_rounded, size: 18, color: KnockColors.greenBright),
              const SizedBox(width: 10),
              Expanded(child: Text(p, style: KnockText.body)),
            ]),
          ),
        ),
      const SizedBox(height: 8),
      const Note('Knock AI will never move your money. Every trade and payment still needs you to review it and confirm with your PIN.', icon: Icons.lock_outline_rounded),
      const SizedBox(height: 16),
      const NotifyMe(product: 'knock_ai', consentText: 'I agree that Knock may contact me about early access to Knock AI.'),
    ]);
  }
}
