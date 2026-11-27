import 'package:material_ui/material_ui.dart';

import '../../api/api.dart';
import '../../core/format.dart';
import '../../design/tokens.dart';
import '../../design/widgets/kit.dart';
import 'service_common.dart';

class EpinsScreen extends StatefulWidget {
  const EpinsScreen({super.key});
  @override
  State<EpinsScreen> createState() => _EpinsScreenState();
}

class _EpinsScreenState extends State<EpinsScreen> {
  String? _product;
  int _qty = 1;
  final _idem = KnockApi.newIdempotencyKey();

  @override
  Widget build(BuildContext context) {
    final groups = <String, List<EpinProduct>>{};
    for (final e in epinProducts) {
      groups.putIfAbsent(e.group, () => []).add(e);
    }
    final p = _product == null ? null : epinProducts.firstWhere((e) => e.id == _product);
    return KPage(
      title: 'E-pins',
      bottom: KnockButton(
        key: const ValueKey('epin-pay'),
        label: p == null ? 'Choose a product' : 'Pay ${F.ngn(p.priceNgn * 100 * _qty)}',
        onPressed: p == null ? null : () => payForService(context, kind: 'epin', billerId: p.id, amountKobo: _qty, customer: 'self', idempotencyKey: _idem, summary: '${p.name} × $_qty', successTitle: 'Your PINs are ready', successMessage: 'Open the receipt and confirm your PIN to reveal the codes.', nextLabel: 'Reveal my PINs'),
      ),
      children: [
        for (final g in groups.entries) ...[
          SectionTitle(g.key, top: 8),
          for (final e in g.value)
            RadioListTile<String>(
              key: ValueKey('epin-${e.id}'),
              contentPadding: EdgeInsets.zero,
              value: e.id,
              groupValue: _product,
              onChanged: (v) => setState(() => _product = v),
              activeColor: KnockColors.green,
              title: Text(e.name, style: KnockText.body),
              subtitle: Text(e.detail, style: KnockText.caption),
              secondary: Text(F.ngn(e.priceNgn * 100), style: KnockText.number),
            ),
        ],
        if (p != null) ...[
          const SizedBox(height: 12),
          Row(children: [
            Text('Quantity', style: KnockText.bodyStrong),
            const Spacer(),
            IconButton(tooltip: 'Fewer', onPressed: _qty > 1 ? () => setState(() => _qty--) : null, icon: const Icon(Icons.remove_circle_outline)),
            Text('$_qty', style: KnockText.headline),
            IconButton(tooltip: 'More', onPressed: _qty < 10 ? () => setState(() => _qty++) : null, icon: const Icon(Icons.add_circle_outline)),
          ]),
        ],
        const SizedBox(height: 12),
        const Note('PIN codes are encrypted and only shown after you confirm your transaction PIN.', icon: Icons.lock_outline_rounded),
        const SizedBox(height: 10),
        const BalanceLine(),
      ],
    );
  }
}
