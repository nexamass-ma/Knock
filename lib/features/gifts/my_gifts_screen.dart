import 'package:material_ui/material_ui.dart';

import '../../api/api.dart';
import '../../core/format.dart';
import '../../design/tokens.dart';
import '../../design/widgets/kit.dart';
import '../shell/nav.dart';
import '../shell/shell.dart';
import 'claim_gift_sheet.dart';
import 'gift_art.dart';

class MyGiftsScreen extends StatefulWidget {
  const MyGiftsScreen({super.key});
  @override
  State<MyGiftsScreen> createState() => _MyGiftsScreenState();
}

class _MyGiftsScreenState extends State<MyGiftsScreen> {
  String _filter = 'all';
  String _q = '';

  static const _filters = [('all', 'All'), ('received', 'Received'), ('sent', 'Sent'), ('unopened', 'Unopened'), ('redeemed', 'Redeemed'), ('expired', 'Expired')];

  bool _match(Json g) {
    final st = g['status'] as String;
    final ok = switch (_filter) {
      'received' => g['direction'] == 'received',
      'sent' => g['direction'] == 'sent',
      'unopened' => g['direction'] == 'received' && st == 'delivered',
      'redeemed' => st == 'redeemed' || st == 'traded',
      'expired' => st == 'expired',
      _ => true,
    };
    if (!ok) return false;
    if (_q.isEmpty) return true;
    return '${g['brand']} ${g['senderName']} ${g['recipientName']} ${g['reference']}'.toLowerCase().contains(_q.toLowerCase());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(leading: const MenuButton(), title: const Text('My Gifts'), actions: [
        TextButton(key: const ValueKey('gift-claim-link'), onPressed: () => showClaimGiftSheet(context), child: Text('Claim a link', style: KnockText.bodyStrong.copyWith(color: KnockColors.greenBright))),
      ]),
      floatingActionButton: FloatingActionButton.extended(
        key: const ValueKey('gift-send-fab'),
        backgroundColor: KnockColors.green,
        foregroundColor: KnockColors.onGreen,
        onPressed: () => Nav.sendGift(context),
        icon: const Icon(Icons.redeem_rounded),
        label: const Text('Send a Gift Card'),
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(KnockSpace.gutter, 0, KnockSpace.gutter, 8),
          child: TextField(onChanged: (v) => setState(() => _q = v), style: KnockText.body, decoration: const InputDecoration(hintText: 'Search gifts', prefixIcon: Icon(Icons.search_rounded, color: KnockColors.textSecondary))),
        ),
        SizedBox(
          height: 42,
          child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: KnockSpace.gutter), children: [
            for (final (v, l) in _filters)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(l),
                  selected: _filter == v,
                  showCheckmark: false,
                  selectedColor: KnockColors.greenSoft,
                  backgroundColor: KnockColors.surfaceRaised,
                  side: BorderSide(color: _filter == v ? KnockColors.green : KnockColors.stroke),
                  labelStyle: KnockText.caption.copyWith(color: KnockColors.textPrimary),
                  onSelected: (_) => setState(() => _filter = v),
                ),
              ),
          ]),
        ),
        Expanded(
          child: ApiView(
            load: (api) => api.call((s, t) => s.myGifts(t!)),
            builder: (context, d, reload) {
              final all = (d['items'] as List).cast<Json>();
              final items = all.where(_match).toList();
              if (all.isEmpty) {
                return EmptyState(icon: Icons.redeem_rounded, title: 'Gifts you send and receive', message: 'Send a gift card to someone you love. They get a gift to open, not a code in a text message.', action: 'Send a Gift Card', onAction: () => Nav.sendGift(context));
              }
              if (items.isEmpty) return const EmptyState(icon: Icons.filter_alt_off_outlined, title: 'No gifts here', message: 'Try another filter.');
              return RefreshIndicator(
                onRefresh: reload,
                color: KnockColors.green,
                child: ListView(padding: const EdgeInsets.fromLTRB(KnockSpace.gutter, 4, KnockSpace.gutter, 96), children: [
                  for (final g in items)
                    ListRow(
                      key: ValueKey('gift-${g['id']}'),
                      leading: Stack(clipBehavior: Clip.none, children: [
                        BrandBadge(glyph: g['glyph'] as String, color: g['color'] as int),
                        if (g['direction'] == 'received' && g['status'] == 'delivered')
                          Positioned(right: -2, top: -2, child: Container(width: 10, height: 10, decoration: const BoxDecoration(color: KnockColors.orange, shape: BoxShape.circle))),
                      ]),
                      title: '${g['brand']} ${F.face(g['currency'] as String, g['value'] as int)}',
                      subtitle: '${g['direction'] == 'received' ? 'From ${g['senderName']}' : 'To ${g['recipientName']}'} · ${F.date(g['createdAt'] as String)}',
                      trailing: StatusChip(_chip(g['status'] as String), label: giftStatusLabel(g['status'] as String).replaceFirst('Gift ', '')),
                      onTap: () => Nav.gift(context, g['id'] as String),
                    ),
                ]),
              );
            },
          ),
        ),
      ]),
    );
  }

  String _chip(String s) => switch (s) { 'delivered' || 'opened' || 'redeemed' => 'successful', 'expired' || 'failed' => 'failed', 'traded' => 'traded', _ => 'pending' };
}

// Keeps the Gifts tab reachable from other screens.
void openGiftsTab(BuildContext context) => ShellScope.of(context)?.goTab(ShellTab.gifts);
