import 'package:material_ui/material_ui.dart';

import '../../api/api.dart';
import '../../app/app_controller.dart';
import '../../design/tokens.dart';
import '../../design/widgets/kit.dart';
import '../shell/nav.dart';
import '../shell/shell.dart';
import 'txn_tile.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});
  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  String _status = 'all';
  String? _type;
  String _query = '';

  static const _types = <(String?, String)>[
    (null, 'All types'),
    ('giftcards', 'Gift cards'),
    ('crypto', 'Crypto'),
    ('deposits', 'Deposits'),
    ('withdrawals', 'Withdrawals'),
    ('bills', 'Bills'),
    ('betting', 'Betting'),
    ('epins', 'E-pins'),
    ('esim', 'eSIM'),
    ('gifts', 'Gifts'),
    ('rewards', 'Rewards'),
    ('referrals', 'Referral payouts'),
  ];

  @override
  Widget build(BuildContext context) {
    final hidden = context.appWatch.hideBalances;
    return Scaffold(
      appBar: AppBar(leading: const MenuButton(), title: const Text('Transaction History')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(KnockSpace.gutter, 0, KnockSpace.gutter, 8),
          child: TextField(
            key: const ValueKey('history-search'),
            onChanged: (v) => setState(() => _query = v),
            style: KnockText.body,
            decoration: const InputDecoration(hintText: 'Search by name or reference', prefixIcon: Icon(Icons.search_rounded, color: KnockColors.textSecondary)),
          ),
        ),
        SizedBox(
          height: 42,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: KnockSpace.gutter),
            children: [
              for (final s in const ['all', 'successful', 'pending', 'failed', 'reversed'])
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    key: ValueKey('filter-$s'),
                    label: Text(s == 'all' ? 'All' : '${s[0].toUpperCase()}${s.substring(1)}'),
                    selected: _status == s,
                    showCheckmark: false,
                    selectedColor: KnockColors.greenSoft,
                    backgroundColor: KnockColors.surfaceRaised,
                    side: BorderSide(color: _status == s ? KnockColors.green : KnockColors.stroke),
                    labelStyle: KnockText.caption.copyWith(color: KnockColors.textPrimary),
                    onSelected: (_) => setState(() => _status = s),
                  ),
                ),
              PopupMenuButton<String?>(
                tooltip: 'Filter by type',
                onSelected: (v) => setState(() => _type = v),
                itemBuilder: (_) => [for (final (v, l) in _types) PopupMenuItem(value: v, child: Text(l))],
                child: Chip(
                  avatar: const Icon(Icons.tune_rounded, size: 16),
                  label: Text(_types.firstWhere((t) => t.$1 == _type).$2),
                  backgroundColor: KnockColors.surfaceRaised,
                  side: const BorderSide(color: KnockColors.stroke),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ApiView(
            key: ValueKey('$_status|$_type|$_query'),
            load: (api) => api.call((s, t) => s.transactions(t!, status: _status, type: _type, query: _query)),
            builder: (context, d, reload) {
              final items = (d['items'] as List).cast<Json>();
              if (items.isEmpty) {
                return EmptyState(
                  icon: Icons.receipt_long_outlined,
                  title: _status == 'all' && _type == null && _query.isEmpty ? 'No transactions yet' : 'Nothing here',
                  message: _status == 'all' && _type == null && _query.isEmpty ? 'When you trade, pay or get paid, it shows up here with a receipt.' : 'Try another filter.',
                  action: _status == 'all' && _type == null ? 'Start trading' : null,
                  onAction: () => Nav.tab(context, ShellTab.trade),
                );
              }
              return RefreshIndicator(
                color: KnockColors.green,
                onRefresh: reload,
                child: ListView(padding: const EdgeInsets.fromLTRB(KnockSpace.gutter, 4, KnockSpace.gutter, 24), children: [for (final t in items) TxnTile(t, hidden: hidden)]),
              );
            },
          ),
        ),
      ]),
    );
  }
}
