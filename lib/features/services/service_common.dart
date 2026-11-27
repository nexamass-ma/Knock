import 'package:material_ui/material_ui.dart';

import '../../api/api.dart';
import '../../app/app_controller.dart';
import '../../core/format.dart';
import '../../design/widgets/kit.dart';
import '../common/pin_sheet.dart';
import '../common/success_screen.dart';
import '../history/transaction_detail_screen.dart';

/// Shared purchase step for bills, betting, e-pins and eSIM: PIN, then the
/// animated result screen with the reference and a next action.
Future<void> payForService(
  BuildContext context, {
  required String kind,
  required String billerId,
  String? planId,
  int? amountKobo,
  required String customer,
  String? customerName,
  required String idempotencyKey,
  required String summary,
  bool confirmedAdult = false,
  String? successTitle,
  String? successMessage,
  String nextLabel = 'View receipt',
}) async {
  final api = context.api;
  try {
    final r = await withPin<Json>(context, title: 'Confirm payment', subtitle: summary, action: (pin) {
      final sec = api.security();
      return api.call((s, t) => s.purchaseService(t!, kind: kind, billerId: billerId, planId: planId, amountKobo: amountKobo, customer: customer, customerName: customerName, pin: pin, idempotencyKey: idempotencyKey, nonce: sec.nonce, sentAt: sec.sentAt, confirmedAdult: confirmedAdult));
    });
    if (r == null || !context.mounted) return;
    final txn = r['txn'] as Json;
    context.app.poke();
    await Navigator.of(context).pushReplacement(KRoute(ResultScreen(
      title: successTitle ?? (txn['status'] == 'pending' ? 'Payment received' : 'Payment successful'),
      amountKobo: -(txn['amount'] as int),
      message: successMessage ?? (txn['status'] == 'pending' ? 'We are waiting for the provider to confirm. We will notify you in a moment.' : '${txn['title']} is done.'),
      txn: txn,
      nextLabel: nextLabel,
      onNext: () => Navigator.of(context).pushReplacement(KRoute(TransactionDetailScreen(txnId: txn['id'] as String))),
    )));
  } catch (e) {
    if (context.mounted) showApiError(context, e);
  }
}

/// Shows the wallet balance under a purchase form.
class BalanceLine extends StatelessWidget {
  const BalanceLine({super.key});
  @override
  Widget build(BuildContext context) => ApiView(
    skeleton: const Skeleton(height: 14, width: 160),
    load: (api) => api.call((s, t) => s.wallet(t!)),
    builder: (_, w, _) => Text('Wallet balance ${F.ngnExact(w['available'] as int)}', style: const TextStyle(fontSize: 12, color: Color(0xFF9B9BA7))),
  );
}
