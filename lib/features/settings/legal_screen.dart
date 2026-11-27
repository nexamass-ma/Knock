import 'package:material_ui/material_ui.dart';

import '../../design/tokens.dart';
import '../../design/widgets/kit.dart';

enum LegalKind { terms, privacy, referralTerms, credits }

/// [Guess] Placeholder legal copy for the prototype. Knock's counsel must
/// supply the final Terms and Privacy Policy before launch.
class LegalScreen extends StatelessWidget {
  const LegalScreen({super.key, required this.kind});
  final LegalKind kind;

  @override
  Widget build(BuildContext context) {
    final (title, sections) = switch (kind) {
      LegalKind.terms => ('Terms of Use', _terms),
      LegalKind.privacy => ('Privacy Policy', _privacy),
      LegalKind.referralTerms => ('Referral terms', _referral),
      LegalKind.credits => ('Credits and licences', _credits),
    };
    return KPage(
      title: title,
      children: [
        const Note('Draft for the prototype. The final version will be provided by Knock\'s legal team before launch.', icon: Icons.gavel_rounded, color: KnockColors.orange),
        for (final (h, b) in sections) ...[
          SectionTitle(h, top: 20),
          Text(b, style: KnockText.body.copyWith(color: KnockColors.textSecondary)),
        ],
      ],
    );
  }
}

const _terms = [
  ('Your account', 'You must be 18 or older and give accurate information. One account per person. You are responsible for keeping your password, PIN and devices secure.'),
  ('Verification', 'We verify identity in tiers. Some services and limits need a higher tier. We never upgrade an account until verification succeeds.'),
  ('Rates and quotes', 'Locked quotes are honoured until they expire. Indicative rates can change until a trade is approved; if a rate changes during your trade, we show you the new payout and you choose to continue or cancel.'),
  ('Gift card trades', 'Cards must be legitimately obtained and unused. We may decline, hold or reverse trades that fail checks or are linked to fraud.'),
  ('Rewards', 'Bonuses, points and campaign rewards follow their own rules. Promotional balances are not withdrawable unless stated. Rewards gained through fraud or abuse are reversed.'),
  ('Closing your account', 'You can ask us to delete your account in Settings. We keep records the law requires us to keep.'),
];

const _privacy = [
  ('What we collect', 'Your name, email, phone, device information and transaction records. For verification we check BVN and NIN with our provider and store only a protected token and the last four digits, never the full number.'),
  ('How we use it', 'To run your account, prevent fraud, meet legal obligations and, only if you agree, to send offers.'),
  ('Your choices', 'Change notification and privacy settings any time. Hide yourself from the leaderboard and activity feed. Ask for a copy or deletion of your data.'),
  ('Security', 'Data is encrypted in transit and at rest. Sensitive codes are encrypted and only revealed after you authenticate.'),
];

const _referral = [
  ('How you earn', 'You earn ₦5,000 when a friend you invited signs up with your code and completes \$500 in settled, eligible trades.'),
  ('Eligible trades', 'Gift card sales and crypto sales that complete successfully. Cancelled, failed or reversed trades do not count.'),
  ('When you are paid', 'The reward is pending for a short review period, then moves to your wallet. In this sandbox the review takes one minute; in the live app it is 7 days.'),
  ('Fair use', 'No self-referrals, fake or duplicate accounts, or traded volume between linked accounts. We may withhold or reverse rewards linked to abuse.'),
];

const _credits = [
  ('Intro photograph 1', 'Photo by Kagou Dicko on Unsplash, used under the Unsplash License.'),
  ('Intro photograph 2', 'Photo by McFollis on Unsplash, used under the Unsplash License.'),
  ('Intro photograph 3', 'Photo by Brian Kungu on Unsplash, used under the Unsplash License.'),
  ('Customer care photograph', 'Photo by LumenSoft Technologies on Unsplash, used under the Unsplash License.'),
  ('Brand', 'Knock name and mark belong to Knock.'),
];
