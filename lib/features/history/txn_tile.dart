import 'package:material_ui/material_ui.dart';

import '../../api/api.dart';
import '../../core/format.dart';
import '../../design/tokens.dart';
import '../../design/widgets/kit.dart';
import '../shell/nav.dart';

IconData txnIcon(String type) => switch (type) {
      'giftcard_sell' => Icons.card_giftcard_rounded,
      'crypto_buy' || 'crypto_sell' || 'crypto_deposit' => Icons.currency_bitcoin_rounded,
      'deposit' => Icons.south_west_rounded,
      'withdrawal' => Icons.north_east_rounded,
      'airtime' => Icons.phone_android_rounded,
      'data' => Icons.wifi_rounded,
      'electricity' => Icons.bolt_rounded,
      'cable' => Icons.tv_rounded,
      'betting' => Icons.sports_soccer_rounded,
      'epin' => Icons.pin_outlined,
      'esim' => Icons.sim_card_outlined,
      'gift_send' => Icons.redeem_rounded,
      'reward' || 'referral_payout' => Icons.workspace_premium_rounded,
      _ => Icons.receipt_long_rounded,
    };

String trackerLabel(String? s) => switch (s) {
      'submitted' => 'Submitted',
      'received' => 'Received',
      'under_review' => 'Under review',
      'approved' => 'Approved',
      'payment_processing' => 'Payment processing',
      'completed' => 'Completed',
      'action_required' => 'Action required',
      'cancelled' => 'Cancelled',
      'failed' => 'Failed',
      _ => '',
    };

class TxnTile extends StatelessWidget {
  const TxnTile(this.t, {super.key, this.hidden = false});
  final Json t;
  final bool hidden;

  @override
  Widget build(BuildContext context) {
    final status = t['status'] as String;
    final credit = t['direction'] == 'credit';
    final amount = t['amount'] as int;
    final d = t['details'] as Map? ?? const {};
    final tracker = d['tracker'] as String?;
    final chipStatus = tracker == 'action_required' ? 'action_required' : status;
    final chipLabel = tracker != null && status == 'pending' ? trackerLabel(tracker) : F.status(status);
    return ListRow(
      key: ValueKey('txn-${t['id']}'),
      leading: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(color: KnockColors.surfaceHigh, borderRadius: BorderRadius.circular(13)),
        child: Icon(txnIcon(t['type'] as String), size: 20, color: credit ? KnockColors.greenBright : KnockColors.textPrimary),
      ),
      title: t['title'] as String,
      subtitle: '${F.ago(t['createdAt'] as String)} · ${t['subtitle'] ?? F.txnType(t['type'] as String)}',
      trailing: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          BalanceText(amount == 0 ? '—' : F.signed(amount, credit: credit), hidden: hidden, style: KnockText.number.copyWith(color: credit && status == 'successful' ? KnockColors.greenBright : null)),
          const SizedBox(height: 4),
          StatusChip(chipStatus, label: chipLabel),
        ],
      ),
      onTap: () => Nav.txn(context, t['id'] as String),
    );
  }
}
