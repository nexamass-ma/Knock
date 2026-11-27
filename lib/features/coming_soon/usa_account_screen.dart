import 'package:material_ui/material_ui.dart';

import '../../design/tokens.dart';
import '../../design/widgets/kit.dart';
import 'coming_soon.dart';

class UsaAccountScreen extends StatelessWidget {
  const UsaAccountScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return KPage(title: 'USA Account', children: [
      KnockCard(
        gradient: KnockColors.dollarCardGradient,
        child: SizedBox(
          height: 170,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text('Knock', style: KnockText.headline),
              const Spacer(),
              Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4), decoration: BoxDecoration(color: KnockColors.orange, borderRadius: BorderRadius.circular(99)), child: Text('Coming soon', style: KnockText.micro.copyWith(color: Colors.white))),
            ]),
            const Spacer(),
            Text('\$ USD account', style: KnockText.title),
            Text('Account and routing number in your name', style: KnockText.caption.copyWith(color: Colors.white70)),
          ]),
        ),
      ),
      const SectionTitle('What you will be able to do'),
      for (final (i, t) in [
        (Icons.payments_outlined, 'Get paid in dollars by clients and platforms in the US'),
        (Icons.savings_outlined, 'Hold dollars and convert to Naira when you choose'),
        (Icons.credit_card_rounded, 'Spend online with a virtual dollar card'),
        (Icons.receipt_long_outlined, 'Clear statements for every payment'),
      ])
        ListRow(icon: i, title: t),
      const SizedBox(height: 10),
      const Note('USA accounts will be provided by a licensed US banking partner once approvals are in place. Nothing is available yet, and joining the list does not open an account.', icon: Icons.info_outline_rounded),
      const SizedBox(height: 16),
      const NotifyMe(product: 'usa_account', consentText: 'I agree that Knock may contact me by email and in the app about the USA Account launch.'),
    ]);
  }
}
