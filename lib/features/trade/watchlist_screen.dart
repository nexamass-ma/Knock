import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/api.dart';
import '../../app/app_controller.dart';
import '../../core/format.dart';
import '../../design/tokens.dart';
import '../../design/widgets/kit.dart';
import 'rates_screen.dart';

class WatchlistScreen extends StatelessWidget {
  const WatchlistScreen({super.key});

  Future<void> _target(BuildContext context, Json w) async {
    final c = TextEditingController(text: w['targetRate']?.toString() ?? '');
    final v = await showModalBottomSheet<int?>(
      context: context,
      isScrollControlled: true,
      builder: (s) => Padding(
        padding: EdgeInsets.fromLTRB(24, 0, 24, 24 + MediaQuery.viewInsetsOf(s).bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Alert me at a target rate', style: KnockText.title),
          const SizedBox(height: 6),
          Text('Current base rate ₦${(w['rate'] as Map)['rate']}. We alert you when it reaches your target.', style: KnockText.caption),
          const SizedBox(height: 16),
          KField(label: 'Target rate (₦ per 1 ${w['currency']})', controller: c, keyboard: TextInputType.number, formatters: [FilteringTextInputFormatter.digitsOnly], autofocus: true),
          KnockButton(label: 'Save alert', onPressed: () => Navigator.pop(s, int.tryParse(c.text))),
        ]),
      ),
    );
    if (v == null || !context.mounted) return;
    try {
      await context.api.call((s, t) => s.setWatch(t!, brandId: w['brandId'] as String, currency: w['currency'] as String, watch: true, targetRate: v, direction: 'up'));
      if (context.mounted) {
        context.app.poke();
        toast(context, 'Alert saved');
      }
    } catch (e) {
      if (context.mounted) showApiError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Rate watchlist')),
      body: ApiView(
        load: (api) => api.call((s, t) => s.watchlist(t!)),
        builder: (context, d, reload) {
          final items = (d['items'] as List).cast<Json>();
          if (items.isEmpty) {
            return EmptyState(
              icon: Icons.notifications_active_outlined,
              title: 'Watch a rate',
              message: 'Tap the bell on any rate to get an alert when it moves or reaches your target.',
              action: 'Browse rates',
              onAction: () => Navigator.of(context).pushReplacement(KRoute(const RatesScreen())),
            );
          }
          return ListView(
            padding: const EdgeInsets.all(KnockSpace.gutter),
            children: [
              for (final w in items)
                KnockCard(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  child: Column(children: [
                    RateRow(r: w['rate'] as Json, onTap: () => showRateDetail(context, w['rate'] as Json)),
                    Row(children: [
                      Expanded(child: Text(w['targetRate'] == null ? 'Alerts on any move' : 'Target ₦${w['targetRate']}${w['lastAlertAt'] != null ? ' · last alert ${F.ago(w['lastAlertAt'] as String)}' : ''}', style: KnockText.caption)),
                      TextButton(onPressed: () => _target(context, w), child: const Text('Set target')),
                      TextButton(
                        onPressed: () async {
                          await context.api.call((s, t) => s.setWatch(t!, brandId: w['brandId'] as String, currency: w['currency'] as String, watch: false));
                          reload();
                        },
                        child: Text('Remove', style: TextStyle(color: KnockColors.loss.withValues(alpha: 0.9))),
                      ),
                    ]),
                  ]),
                ),
            ].expand((w) => [w, const SizedBox(height: 10)]).toList(),
          );
        },
      ),
    );
  }
}
