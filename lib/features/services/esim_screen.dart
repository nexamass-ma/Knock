import 'package:material_ui/material_ui.dart';

import '../../api/api.dart';
import '../../core/format.dart';
import '../../design/tokens.dart';
import '../../design/widgets/kit.dart';
import '../shell/nav.dart';
import 'service_common.dart';

class EsimScreen extends StatefulWidget {
  const EsimScreen({super.key});
  @override
  State<EsimScreen> createState() => _EsimScreenState();
}

class _EsimScreenState extends State<EsimScreen> {
  int _tab = 0;
  String? _region;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('eSIM & Data')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: KnockSpace.gutter),
          child: PillTabs<int>(values: const [0, 1, 2], selected: _tab, labelOf: (i) => const ['Buy', 'My eSIMs', 'How to install'][i], onChanged: (i) => setState(() => _tab = i)),
        ),
        Expanded(child: switch (_tab) { 0 => _buy(), 1 => _orders(), _ => const _Install() }),
      ]),
    );
  }

  Widget _buy() => ApiView(
    live: false,
    load: (api) => api.call((s, t) => s.servicesCatalog(t!)),
    builder: (context, cat, _) {
      final pkgs = (cat['esim'] as List).cast<Json>();
      final regions = <String, String>{for (final p in pkgs) p['region'] as String: p['flag'] as String};
      final shown = _region == null ? <Json>[] : pkgs.where((p) => p['region'] == _region).toList();
      return ListView(padding: const EdgeInsets.all(KnockSpace.gutter), children: [
        Text('Where are you going?', style: KnockText.headline),
        const SizedBox(height: 10),
        ChoiceWrap<String>(choices: [for (final e in regions.entries) Choice(e.key, '${e.value}  ${e.key}')], selected: _region, onSelected: (v) => setState(() => _region = v)),
        if (shown.isNotEmpty) ...[
          const SectionTitle('Packages'),
          for (final p in shown)
            KnockCard(
              key: ValueKey('esim-${p['id']}'),
              onTap: () => _confirm(p),
              child: Row(children: [
                Text(p['flag'] as String, style: const TextStyle(fontSize: 28)),
                const SizedBox(width: 12),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${p['dataGb'] == 0 ? 'Unlimited' : '${p['dataGb']}GB'} · ${p['days']} days', style: KnockText.bodyStrong),
                  Text('\$${p['usd']} · paid in naira', style: KnockText.caption),
                ])),
                Text(F.ngn(p['price'] as int), style: KnockText.number),
              ]),
            ),
        ] else
          Padding(padding: const EdgeInsets.only(top: 24), child: Text('Pick a destination to see data packages.', style: KnockText.caption)),
      ]);
    },
  );

  Future<void> _confirm(Json p) async {
    final ok = await confirm(context, title: '${p['region']} eSIM', message: '${p['dataGb'] == 0 ? 'Unlimited' : '${p['dataGb']}GB'} for ${p['days']} days. ${F.ngnExact(p['price'] as int)} from your wallet. Your phone must support eSIM.', yes: 'Buy eSIM');
    if (!ok || !mounted) return;
    await payForService(context, kind: 'esim', billerId: p['id'] as String, customer: 'self', idempotencyKey: KnockApi.newIdempotencyKey(), summary: '${p['region']} eSIM · ${F.ngnExact(p['price'] as int)}', successTitle: 'Your eSIM is ready', successMessage: 'Open the details to see your activation code and install steps.', nextLabel: 'Install my eSIM');
  }

  Widget _orders() => ApiView(
    load: (api) => api.call((s, t) => s.transactions(t!, type: 'esim')),
    builder: (context, d, _) {
      final items = (d['items'] as List).cast<Json>();
      if (items.isEmpty) return EmptyState(icon: Icons.sim_card_outlined, title: 'No eSIMs yet', message: 'Your eSIM orders and their activation codes appear here.', action: 'Buy an eSIM', onAction: () => setState(() => _tab = 0));
      return ListView(padding: const EdgeInsets.all(KnockSpace.gutter), children: [
        for (final t in items)
          ListRow(
            leading: Text((t['details'] as Map)['flag'] as String? ?? '📶', style: const TextStyle(fontSize: 26)),
            title: t['title'] as String,
            subtitle: '${t['subtitle']} · ${(t['details'] as Map)['esimStatus']}',
            onTap: () => Nav.txn(context, t['id'] as String),
          ),
      ]);
    },
  );
}

class _Install extends StatelessWidget {
  const _Install();
  @override
  Widget build(BuildContext context) => ListView(padding: const EdgeInsets.all(KnockSpace.gutter), children: [
    const SectionTitle('iPhone', top: 8),
    for (final s in const ['Open Settings → Mobile Service (or Cellular) → Add eSIM.', 'Choose "Use QR code", then "Enter details manually".', 'Enter the SM-DP+ address and activation code from your eSIM details.', 'Label the line "Travel" and turn on Data Roaming for it when you land.'])
      ListRow(icon: Icons.check_rounded, title: s, dense: true),
    const SectionTitle('Android'),
    for (final s in const ['Open Settings → Network & internet → SIMs → Add eSIM.', 'Choose "Enter code manually" or "Need help?".', 'Paste the LPA string from your eSIM details.', 'Turn on mobile data and roaming for the eSIM when you arrive.'])
      ListRow(icon: Icons.check_rounded, title: s, dense: true),
    const SizedBox(height: 12),
    const Note('Install your eSIM on Wi-Fi before you travel. Each eSIM can be installed once.'),
  ]);
}
