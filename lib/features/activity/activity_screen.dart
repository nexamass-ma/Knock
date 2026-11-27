import 'package:material_ui/material_ui.dart';

import '../../app/app_scope.dart';
import '../../core/money.dart';
import '../../design/tokens.dart';
import '../../design/widgets/states.dart';
import '../../design/widgets/surfaces.dart';
import '../../models/ledger.dart';
import '../../state/wallet_store.dart';
import '../shell/shell.dart';

class ActivityScreen extends StatefulWidget {
  const ActivityScreen({super.key});

  @override
  State<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends State<ActivityScreen> {
  TxCategory? _filter;

  @override
  Widget build(BuildContext context) {
    final w = context.app.wallet;
    return ListenableBuilder(
      listenable: w,
      builder: (context, _) {
        final txs = w.transactions.where((t) => _filter == null || t.category == _filter).toList();
        final groups = <String, List<TransactionRecord>>{};
        for (final t in txs) {
          groups.putIfAbsent(Fmt.dayLabel(t.createdAt), () => []).add(t);
        }
        return Scaffold(
          body: SafeArea(
            bottom: false,
            child: RefreshIndicator(
              color: KnockColors.green,
              onRefresh: () => w.load(silent: true),
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(KnockSpace.gutter, 12, KnockSpace.gutter, 12),
                      child: Text('Activity', style: KnockText.title),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: SizedBox(
                      height: 40,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: KnockSpace.gutter),
                        children: [
                          for (final c in <TxCategory?>[null, ...TxCategory.values])
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: ChoiceChip(
                                label: Text(c?.label ?? 'All'),
                                selected: _filter == c,
                                onSelected: (_) => setState(() => _filter = c),
                                showCheckmark: false,
                                selectedColor: KnockColors.green,
                                backgroundColor: KnockColors.surface,
                                side: const BorderSide(color: KnockColors.stroke),
                                shape: const StadiumBorder(),
                                labelStyle: KnockText.caption.copyWith(
                                  fontWeight: FontWeight.w600,
                                  color: _filter == c ? KnockColors.onGreen : KnockColors.textPrimary,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  if (w.state == LoadState.error)
                    SliverToBoxAdapter(
                      child: ErrorState(message: w.error ?? '', onRetry: w.load),
                    )
                  else if (w.state != LoadState.ready)
                    const SliverToBoxAdapter(child: SkeletonList(rows: 6))
                  else if (txs.isEmpty)
                    SliverToBoxAdapter(
                      child: EmptyState(
                        icon: Icons.receipt_long_outlined,
                        title: 'Nothing here yet',
                        message: _filter == null
                            ? 'Your trades and payments will show up here.'
                            : 'No ${_filter!.label.toLowerCase()} activity yet.',
                      ),
                    )
                  else
                    for (final e in groups.entries) ...[
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(KnockSpace.gutter, 20, KnockSpace.gutter, 8),
                          child: Text(e.key.toUpperCase(), style: KnockText.micro),
                        ),
                      ),
                      SliverList.list(
                        children: [
                          for (final t in e.value)
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: KnockSpace.gutter, vertical: 4),
                              child: TxRow(tx: t, onTap: () => showTxDetail(context, t)),
                            ),
                        ],
                      ),
                    ],
                  const SliverToBoxAdapter(child: SizedBox(height: kNavClearance + 16)),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

IconData _iconFor(TxCategory c) => switch (c) {
  TxCategory.crypto => Icons.currency_bitcoin_rounded,
  TxCategory.giftCard => Icons.card_giftcard_rounded,
  TxCategory.bills => Icons.bolt_rounded,
  TxCategory.wallet => Icons.account_balance_outlined,
};

Color _statusColor(TxStatus s) => switch (s) {
  TxStatus.completed => KnockColors.green,
  TxStatus.pending || TxStatus.inReview => KnockColors.orange,
  TxStatus.failed => KnockColors.loss,
};

class TxRow extends StatelessWidget {
  const TxRow({super.key, required this.tx, this.onTap});
  final TransactionRecord tx;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final sign = tx.isCredit ? '+' : '-';
    return KnockCard(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      semanticLabel: '${tx.title}, ${tx.subtitle}, $sign${tx.amount.format()}, ${tx.status.label}',
      child: ExcludeSemantics(
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: const BoxDecoration(color: KnockColors.surfaceRaised, shape: BoxShape.circle),
              child: Icon(_iconFor(tx.category), size: 20, color: KnockColors.textPrimary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(tx.title, style: KnockText.bodyStrong, maxLines: 1, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Text(
                    '${tx.subtitle} · ${Fmt.time(tx.createdAt)}',
                    style: KnockText.caption,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '$sign${tx.amount.format(showDecimals: false)}',
                  style: KnockText.number.copyWith(color: tx.isCredit ? KnockColors.gain : KnockColors.textPrimary),
                ),
                const SizedBox(height: 3),
                if (tx.status != TxStatus.completed)
                  Text(tx.status.label, style: KnockText.micro.copyWith(color: _statusColor(tx.status)))
                else if (tx.secondaryAmount != null)
                  Text(tx.secondaryAmount!, style: KnockText.micro.copyWith(fontWeight: FontWeight.w400)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> showTxDetail(BuildContext context, TransactionRecord tx) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(KnockSpace.gutter, 0, KnockSpace.gutter, KnockSpace.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Column(
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    decoration: const BoxDecoration(color: KnockColors.surfaceRaised, shape: BoxShape.circle),
                    child: Icon(_iconFor(tx.category), color: KnockColors.textPrimary),
                  ),
                  const SizedBox(height: 10),
                  Text(tx.title, style: KnockText.headline),
                  const SizedBox(height: 4),
                  Text(
                    '${tx.isCredit ? '+' : '-'}${tx.amount.format()}',
                    style: KnockText.display.copyWith(fontSize: 30),
                  ),
                  const SizedBox(height: 8),
                  Tag(tx.status.label, color: _statusColor(tx.status)),
                ],
              ),
            ),
            const SizedBox(height: KnockSpace.lg),
            KnockCard(
              color: KnockColors.surfaceRaised,
              child: Column(
                children: [
                  _kv('Reference', tx.reference),
                  _kv('Details', tx.subtitle),
                  if (tx.secondaryAmount != null) _kv('Crypto', tx.secondaryAmount!),
                  _kv('Ledger', tx.ledger.label),
                  _kv('Date', '${Fmt.date(tx.createdAt)}, ${Fmt.time(tx.createdAt)}'),
                ],
              ),
            ),
            const SizedBox(height: KnockSpace.md),
            Text('AUDIT TRAIL', style: KnockText.micro),
            const SizedBox(height: 8),
            for (final (i, e) in tx.audit.indexed)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Column(
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        margin: const EdgeInsets.only(top: 4),
                        decoration: const BoxDecoration(color: KnockColors.green, shape: BoxShape.circle),
                      ),
                      if (i < tx.audit.length - 1) Container(width: 2, height: 22, color: KnockColors.stroke),
                    ],
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: Text(e.label, style: KnockText.body)),
                  Text(Fmt.time(e.at), style: KnockText.micro.copyWith(fontWeight: FontWeight.w400)),
                ],
              ),
            const SizedBox(height: 10),
            Text(
              'Records are append-only. Corrections are posted as new entries, never edits.',
              style: KnockText.micro.copyWith(color: KnockColors.textTertiary, fontWeight: FontWeight.w400),
            ),
          ],
        ),
      ),
    ),
  );
}

Widget _kv(String k, String v) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 6),
  child: Row(
    children: [
      Text(k, style: KnockText.caption),
      const SizedBox(width: 16),
      Expanded(
        child: Text(v, style: KnockText.body, textAlign: TextAlign.right),
      ),
    ],
  ),
);
