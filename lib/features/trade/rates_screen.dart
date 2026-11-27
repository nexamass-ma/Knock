import 'package:material_ui/material_ui.dart';

import '../../api/api.dart';
import '../../app/app_controller.dart';
import '../../core/format.dart';
import '../../design/tokens.dart';
import '../../design/widgets/kit.dart';
import '../shell/nav.dart';

/// "Current Rates": every brand, currency and denomination, with movement,
/// fees and an estimated payout from the pricing engine.
class RatesScreen extends StatefulWidget {
  const RatesScreen({super.key, this.category});
  final String? category;
  @override
  State<RatesScreen> createState() => _RatesScreenState();
}

class _RatesScreenState extends State<RatesScreen> {
  late String? _category = widget.category;
  String _query = '';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Current Rates'), actions: [
        IconButton(tooltip: 'Rate watchlist', icon: const Icon(Icons.notifications_active_outlined), onPressed: () => Nav.watchlist(context)),
      ]),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(KnockSpace.gutter, 4, KnockSpace.gutter, 8),
          child: TextField(
            key: const ValueKey('rates-search'),
            onChanged: (v) => setState(() => _query = v),
            style: KnockText.body,
            decoration: const InputDecoration(hintText: 'Search brands', prefixIcon: Icon(Icons.search_rounded, color: KnockColors.textSecondary)),
          ),
        ),
        SizedBox(
          height: 42,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: KnockSpace.gutter),
            children: [
              for (final c in [null, ...giftCategories])
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(c ?? 'All'),
                    selected: _category == c,
                    onSelected: (_) => setState(() => _category = c),
                    selectedColor: KnockColors.greenSoft,
                    backgroundColor: KnockColors.surfaceRaised,
                    side: BorderSide(color: _category == c ? KnockColors.green : KnockColors.stroke),
                    labelStyle: KnockText.caption.copyWith(color: KnockColors.textPrimary),
                    showCheckmark: false,
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: ApiView(
            key: ValueKey('$_category|$_query'),
            load: (api) => api.call((s, t) => s.giftCardRates(t!, query: _query, category: _category)),
            builder: (context, d, reload) {
              final items = (d['items'] as List).cast<Json>();
              if (items.isEmpty) return EmptyState(icon: Icons.search_off_rounded, title: 'No matches', message: 'Try another brand or category.');
              return RefreshIndicator(
                onRefresh: reload,
                color: KnockColors.green,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(KnockSpace.gutter, 8, KnockSpace.gutter, 32),
                  children: [
                    Text('Updated ${F.ago(d['updatedAt'] as String)} · ${d['source']}', style: KnockText.micro.copyWith(fontWeight: FontWeight.w400)),
                    const SizedBox(height: 8),
                    for (final r in items) RateRow(r: r, onTap: () => showRateDetail(context, r)),
                  ],
                ),
              );
            },
          ),
        ),
      ]),
    );
  }
}

class RateRow extends StatelessWidget {
  const RateRow({super.key, required this.r, this.onTap});
  final Json r;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final mv = r['movement'] as String;
    final pct = (r['movementPct'] as num).toDouble();
    return ListRow(
      key: ValueKey('rate-${r['brandId']}-${r['currency']}'),
      leading: BrandBadge(glyph: r['glyph'] as String, color: r['color'] as int, size: 42),
      title: '${r['brand']} · ${r['currency']}',
      subtitle: '${r['mode'] == 'locked' ? 'Locks for ${r['lockMinutes']} min' : 'Indicative'} · ${F.ago(r['updatedAt'] as String)}${r['campaign'] != null ? ' · ${r['campaign']}' : ''}',
      trailing: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Text(F.rate(r['effectiveKobo'] as int, r['currency'] as String), style: KnockText.number),
        const SizedBox(height: 3),
        Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(mv == 'up' ? Icons.arrow_drop_up_rounded : mv == 'down' ? Icons.arrow_drop_down_rounded : Icons.remove_rounded, size: 18, color: mv == 'up' ? KnockColors.gain : mv == 'down' ? KnockColors.loss : KnockColors.textTertiary),
          Text('${pct.abs().toStringAsFixed(2)}%', style: KnockText.micro.copyWith(color: mv == 'up' ? KnockColors.gain : mv == 'down' ? KnockColors.loss : KnockColors.textTertiary)),
        ]),
      ]),
      onTap: onTap,
    );
  }
}

Future<void> showRateDetail(BuildContext context, Json r) => showModalBottomSheet<void>(context: context, isScrollControlled: true, builder: (_) => _RateDetail(r: r));

class _RateDetail extends StatefulWidget {
  const _RateDetail({required this.r});
  final Json r;
  @override
  State<_RateDetail> createState() => _RateDetailState();
}

class _RateDetailState extends State<_RateDetail> {
  int _value = 100;
  String _type = 'physical';
  Json? _est;
  String? _note;
  late bool _watched = widget.r['watched'] == true;

  @override
  void initState() {
    super.initState();
    _estimate();
  }

  Future<void> _estimate() async {
    final r = widget.r;
    try {
      final e = await context.api.call((s, t) => s.estimateGiftCard(t!, brandId: r['brandId'] as String, currency: r['currency'] as String, cardType: _type, faceValue: _value));
      if (mounted) {
        setState(() {
          _est = e['estimate'] as Json;
          _note = e['note'] as String;
        });
      }
    } catch (_) {}
  }

  Future<void> _toggleWatch() async {
    final r = widget.r;
    try {
      await context.api.call((s, t) => s.setWatch(t!, brandId: r['brandId'] as String, currency: r['currency'] as String, watch: !_watched));
      setState(() => _watched = !_watched);
      if (mounted) toast(context, _watched ? 'We will tell you when this rate moves.' : 'Removed from your watchlist.');
    } catch (e) {
      if (mounted) showApiError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.r;
    final cur = r['currency'] as String;
    final history = ((r['history'] as List?) ?? const []).cast<Map>();
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
        child: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              BrandBadge(glyph: r['glyph'] as String, color: r['color'] as int),
              const SizedBox(width: 12),
              Expanded(child: Text('${r['brand']} ${r['currency']}', style: KnockText.title)),
              IconButton(
                key: const ValueKey('rate-watch'),
                tooltip: _watched ? 'Stop watching' : 'Watch this rate',
                icon: Icon(_watched ? Icons.notifications_active_rounded : Icons.notifications_none_rounded, color: _watched ? KnockColors.greenBright : null),
                onPressed: _toggleWatch,
              ),
            ]),
            const SizedBox(height: 16),
            KeyValue('Rate (physical)', F.rate(r['effectiveKobo'] as int, cur), strong: true),
            KeyValue('Rate (e-code)', F.rate(r['effectiveEcodeKobo'] as int, cur)),
            if ((r['boostKobo'] as int) > 0) KeyValue('Campaign boost', '+${F.rate(r['boostKobo'] as int, cur)}', valueColor: KnockColors.greenBright),
            if ((r['vipKobo'] as int) > 0) KeyValue('VIP bonus', '+${F.rate(r['vipKobo'] as int, cur)}', valueColor: KnockColors.greenBright),
            KeyValue('Previous rate', '₦${r['previousRate']}/${currencySymbols[cur]}'),
            KeyValue('Last updated', F.dateTime(r['updatedAt'] as String)),
            KeyValue('Fees', r['feeRule'] as String),
            if (history.length > 1) ...[
              const SizedBox(height: 8),
              Text('Recent moves', style: KnockText.caption),
              const SizedBox(height: 4),
              Wrap(spacing: 6, runSpacing: 6, children: [for (final h in history.reversed.take(6)) Tag('₦${h['rate']} · ${F.ago(h['at'] as String)}')]),
            ],
            const SizedBox(height: 18),
            Text('Estimate your payout', style: KnockText.headline),
            const SizedBox(height: 10),
            ChoiceWrap<String>(choices: const [Choice('physical', 'Physical card'), Choice('ecode', 'E-code')], selected: _type, onSelected: (v) {
              setState(() => _type = v);
              _estimate();
            }),
            const SizedBox(height: 10),
            ChoiceWrap<int>(
              choices: [for (final v in [25, 50, 100, 200, 500]) Choice(v, F.face(cur, v))],
              selected: _value,
              onSelected: (v) {
                setState(() => _value = v);
                _estimate();
              },
            ),
            const SizedBox(height: 14),
            if (_est != null)
              KnockCard(
                color: KnockColors.surfaceRaised,
                child: Column(children: [
                  KeyValue('Card value', F.face(cur, _est!['faceValue'] as int)),
                  KeyValue('Before fees', F.ngnExact(_est!['grossKobo'] as int)),
                  KeyValue('Service fee', '−${F.ngnExact(_est!['feeKobo'] as int)}'),
                  KeyValue('Estimated payout', F.ngnExact(_est!['netKobo'] as int), strong: true, valueColor: KnockColors.greenBright),
                ]),
              ),
            if (_note != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_note!, style: KnockText.caption)),
            const SizedBox(height: 16),
            KnockButton(
              key: const ValueKey('rate-sell'),
              label: 'Sell ${r['brand']} card',
              onPressed: () {
                Navigator.pop(context);
                Nav.sellGiftCard(context, brandId: r['brandId'] as String, currency: cur, cardType: _type, faceValue: _value);
              },
            ),
          ]),
        ),
      ),
    );
  }
}
