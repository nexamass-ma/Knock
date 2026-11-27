import 'package:material_ui/material_ui.dart';

import '../../design/tokens.dart';
import '../../design/widgets/kit.dart';
import '../shell/nav.dart';

typedef Faq = (String q, String a);

const faqCategories = <(String, IconData, List<Faq>)>[
  ('Account registration', Icons.person_add_alt_1_rounded, [
    ('Who can open a Knock account?', 'Anyone aged 18 or over with a valid email address and phone number. Knock is built for customers in Nigeria first.'),
    ('I did not get my verification code.', 'Wait for the resend timer, check your spam folder, then tap Resend. You can also change the email address on the verification screen if you made a typo.'),
    ('Can I have more than one account?', 'No. One person, one account. Duplicate accounts are closed and any rewards on them are cancelled.'),
  ]),
  ('Verification', Icons.verified_user_rounded, [
    ('What are the verification tiers?', 'Tier 1: verified phone and email, for trading, bills and gifts with lower limits. Tier 2: BVN, NIN and a bank account in your name, for withdrawals and higher limits. Tier 3: proof of address and an ID document, for the highest limits.'),
    ('Do you store my BVN or NIN?', 'No. We check them with our licensed verification partner and keep only the result and a one-way fingerprint, never the raw numbers.'),
    ('Why was my verification declined?', 'Usually the name on your BVN or bank account does not match your Knock profile. Update your name in Settings, or contact Support.'),
  ]),
  ('Gift card trading', Icons.card_giftcard_rounded, [
    ('How do I sell a gift card?', 'Tap Sell gift card, choose the brand, currency and type, enter the amount, then upload the card or e-code. You see your payout before you submit.'),
    ('What does "Rate locked" mean?', 'Some brands lock your rate for a few minutes after you get a quote. Others show an indicative rate. If an indicative rate changes before we confirm, we ask you to continue with the new rate or cancel. We never apply a lower rate silently.'),
    ('How long does a trade take?', 'Most trades complete within minutes. You can follow every step in the Trade Tracker. If we need something from you, the tracker shows "Action required" with a button.'),
    ('Can I send a gift card to someone?', 'Yes. Use Send a Gift Card. They get a gift to open in their Knock app. The code is revealed only to them, after they confirm it is them.'),
  ]),
  ('Cryptocurrency', Icons.currency_bitcoin_rounded, [
    ('Which coins can I trade?', 'BTC, ETH, USDT, USDC and other assets listed in the Crypto screen.'),
    ('How long is a crypto quote valid?', '30 seconds. When the timer runs out, refresh to get a new price.'),
  ]),
  ('Withdrawals', Icons.account_balance_rounded, [
    ('How do I withdraw?', 'Reach Tier 2, add a bank account in your own name, then tap Withdraw on the Wallet or Home screen and confirm with your PIN.'),
    ('Is there a minimum?', 'The minimum withdrawal is ₦1,000. A ₦50 fee applies.'),
    ('Can I withdraw my bonus balance?', 'No. Bonus balance from rewards is not withdrawable.'),
  ]),
  ('Deposits', Icons.savings_rounded, [
    ('How do I fund my wallet?', 'Tap Deposit to see your account details, then send a bank transfer. It reaches your wallet as soon as our bank partner confirms it.'),
  ]),
  ('Transaction fees', Icons.percent_rounded, [
    ('What does Knock charge?', 'Gift card and crypto rates already include our margin, and you always see your exact payout before you confirm. Withdrawals cost ₦50. Gift Send includes a small service charge shown at review.'),
  ]),
  ('Referrals', Icons.group_add_rounded, [
    ('How much can I earn?', '₦5,000 for each friend who signs up with your code and completes \$500 in settled, eligible trades.'),
    ('Why is my reward pending?', 'Rewards are held for a short review to protect against fraud. Self-referrals, duplicate accounts and reversed trades do not qualify.'),
  ]),
  ('Rewards', Icons.military_tech_rounded, [
    ('What is the welcome bonus?', '₦100, paid to your bonus balance after your first settled gift card or crypto trade. It is reversed if that trade is reversed.'),
    ('What are Knock Points?', 'Points you earn from Knockout challenges. They have no cash value yet.'),
    ('What are VIP levels?', 'Silver, Gold and Black, based on your settled trade volume over the last 90 days. Higher levels get better rates and faster support.'),
  ]),
  ('Betting', Icons.sports_soccer_rounded, [
    ('Who can fund a betting wallet?', 'Customers on Tier 2 who confirm they are 18 or over. Please gamble responsibly.'),
  ]),
  ('E-pins', Icons.pin_rounded, [
    ('Where do I find my e-pin?', 'Open the transaction in History and tap Reveal. We ask for your PIN before showing it.'),
  ]),
  ('eSIM', Icons.sim_card_rounded, [
    ('Will an eSIM work on my phone?', 'Your phone must support eSIM and be unlocked. Check Settings on your phone for "Add eSIM" before you buy.'),
    ('How do I install it?', 'Open the eSIM in My eSIMs and follow the steps. You can scan the QR code or enter the activation code manually.'),
  ]),
  ('Security', Icons.shield_rounded, [
    ('Will Knock ever ask for my PIN?', 'Never. Knock staff will never ask for your PIN, password or full gift card codes.'),
    ('How do I protect my account?', 'Turn on two-factor authentication and biometrics in Settings, and review your signed-in devices regularly.'),
  ]),
  ('Account deletion', Icons.delete_outline_rounded, [
    ('How do I delete my account?', 'Go to Settings, then Account, then Delete account. Withdraw your balance first. You have 14 days to change your mind.'),
    ('What do you keep after deletion?', 'The law requires us to keep transaction and verification records for at least 5 years. Your profile, photo and preferences are deleted.'),
  ]),
];

class FaqScreen extends StatefulWidget {
  const FaqScreen({super.key});
  @override
  State<FaqScreen> createState() => _FaqScreenState();
}

class _FaqScreenState extends State<FaqScreen> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final q = _q.toLowerCase();
    final results = [
      for (final (name, icon, items) in faqCategories)
        (name, icon, [for (final f in items) if (q.isEmpty || f.$1.toLowerCase().contains(q) || f.$2.toLowerCase().contains(q) || name.toLowerCase().contains(q)) f]),
    ].where((c) => c.$3.isNotEmpty).toList();
    return KPage(title: 'FAQ', children: [
      TextField(key: const ValueKey('faq-search'), onChanged: (v) => setState(() => _q = v), style: KnockText.body, decoration: const InputDecoration(hintText: 'Search questions', prefixIcon: Icon(Icons.search_rounded))),
      const SizedBox(height: 12),
      if (results.isEmpty)
        EmptyState(icon: Icons.search_off_rounded, title: 'No answers found', message: 'Try different words, or ask our team.', action: 'Contact support', onAction: () => Nav.support(context))
      else
        for (final (name, icon, items) in results)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: KnockCard(
              padding: EdgeInsets.zero,
              child: Theme(
                data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  key: PageStorageKey('faq-$name-${q.isNotEmpty}'),
                  initiallyExpanded: q.isNotEmpty,
                  leading: Icon(icon, color: KnockColors.greenBright),
                  title: Text(name, style: KnockText.bodyStrong),
                  subtitle: Text('${items.length} question${items.length == 1 ? '' : 's'}', style: KnockText.caption),
                  children: [
                    for (final (question, answer) in items)
                      ExpansionTile(
                        tilePadding: const EdgeInsets.symmetric(horizontal: 20),
                        childrenPadding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
                        title: Text(question, style: KnockText.body),
                        children: [Align(alignment: Alignment.centerLeft, child: Text(answer, style: KnockText.caption))],
                      ),
                  ],
                ),
              ),
            ),
          ),
      const SizedBox(height: 8),
      KnockButton(label: 'Still need help? Contact us', style: KnockButtonStyle.secondary, onPressed: () => Nav.support(context)),
    ]);
  }
}
