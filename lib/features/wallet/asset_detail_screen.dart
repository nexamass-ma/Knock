import 'package:material_ui/material_ui.dart';

import '../../app/app_scope.dart';
import '../../core/money.dart';
import '../../design/tokens.dart';
import '../../design/widgets/charts.dart';
import '../../design/widgets/states.dart';
import '../../design/widgets/surfaces.dart';
import '../../models/asset.dart';
import '../../models/quote.dart';

class AssetDetailScreen extends StatefulWidget {
  const AssetDetailScreen({super.key, required this.holding});
  final Holding holding;

  @override
  State<AssetDetailScreen> createState() => _AssetDetailScreenState();
}

class _AssetDetailScreenState extends State<AssetDetailScreen> {
  ChartRange _range = ChartRange.week;
  List<double>? _series;
  String? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_series == null && _error == null) _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final s = await context.app.services.wallet.priceHistory(widget.holding.asset.ticker, _range);
      if (mounted) setState(() => _series = s);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  void _open(TxFlow flow) {
    final app = context.app;
    Navigator.of(context).pop();
    app.shell.openAssistant(flow, fields: {'asset': widget.holding.asset.ticker});
  }

  @override
  Widget build(BuildContext context) {
    final h = widget.holding;
    final a = h.asset;
    final hidden = context.app.session.hideBalances;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            GlyphAvatar(glyph: a.glyph, tint: a.tint, size: 28),
            const SizedBox(width: 8),
            Text(a.name),
          ],
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(KnockSpace.gutter, 8, KnockSpace.gutter, 120),
        children: [
          Row(
            children: [
              Text('${a.ticker} price', style: KnockText.caption),
              const Spacer(),
              const MockBadge(label: 'MOCK'),
            ],
          ),
          const SizedBox(height: 4),
          Text(Fmt.money(h.priceNgn, Currency.ngn), style: KnockText.display.copyWith(fontSize: 34)),
          const SizedBox(height: 4),
          Row(
            children: [
              ChangeText(h.change24h),
              const SizedBox(width: 6),
              Text('24h · ${Fmt.money(h.priceUsd, Currency.usd)}', style: KnockText.caption),
            ],
          ),
          const SizedBox(height: 20),
          if (_error != null)
            ErrorState(message: _error!, onRetry: _load)
          else if (_series == null)
            const Skeleton(height: 180)
          else
            AreaChart(
              values: _series!,
              height: 180,
              color: h.change24h >= 0 ? KnockColors.gain : KnockColors.loss,
              semanticLabel: '${a.name} price chart, ${_range.label}',
            ),
          const SizedBox(height: 14),
          PillTabs<ChartRange>(
            values: ChartRange.values,
            selected: _range,
            labelOf: (r) => r.label,
            dense: true,
            onChanged: (r) {
              setState(() {
                _range = r;
                _series = null;
              });
              _load();
            },
          ),
          const SizedBox(height: 24),
          KnockCard(
            child: Column(
              children: [
                _kv('You hold', hidden ? '••••' : '${Fmt.quantity(h.quantity)} ${a.ticker}'),
                const Divider(height: 22),
                _kv('Value', hidden ? '••••' : h.valueNgn.format()),
                const Divider(height: 22),
                _kv('Network', a.network),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(KnockSpace.gutter, 8, KnockSpace.gutter, 12),
        child: Row(
          children: [
            Expanded(
              child: KnockButton(label: 'Buy ${a.ticker}', onPressed: () => _open(TxFlow.buyCrypto)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: KnockButton(
                label: 'Sell ${a.ticker}',
                style: KnockButtonStyle.secondary,
                onPressed: h.quantity > 0 ? () => _open(TxFlow.sellCrypto) : null,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _kv(String k, String v) => Row(
    children: [
      Text(k, style: KnockText.caption),
      const Spacer(),
      Text(v, style: KnockText.number),
    ],
  );
}
