import 'package:material_ui/material_ui.dart';

import '../../api/api.dart';
import '../../app/app_controller.dart';
import '../../core/format.dart';
import '../../design/tokens.dart';
import '../../design/widgets/kit.dart';
import '../shell/nav.dart';
import '../shell/shell.dart';

class WalletScreen extends StatelessWidget {
  const WalletScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.appWatch;
    return Scaffold(
      appBar: AppBar(leading: const MenuButton(), title: const Text('Wallet')),
      body: ApiView(
        load: (api) => api.call((s, t) => s.wallet(t!)),
        builder: (context, w, reload) {
          final holdings = (w['holdings'] as List).cast<Json>();
          return RefreshIndicator(
            color: KnockColors.green,
            onRefresh: reload,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(KnockSpace.gutter, 8, KnockSpace.gutter, 32),
              children: [
                KnockCard(
                  gradient: KnockColors.cardGradient,
                  padding: const EdgeInsets.all(20),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Text('Naira wallet', style: KnockText.caption.copyWith(color: Colors.white70)),
                      const Spacer(),
                      IconButton(
                        tooltip: app.hideBalances ? 'Show balance' : 'Hide balance',
                        icon: Icon(app.hideBalances ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 20),
                        onPressed: app.toggleHideBalances,
                      ),
                    ]),
                    BalanceText(F.ngnExact(w['available'] as int), hidden: app.hideBalances, style: KnockText.display),
                    if (app.currency != 'NGN') Text('≈ ${F.display(w['available'] as int, app.currency)}', style: KnockText.caption.copyWith(color: Colors.white70)),
                    const SizedBox(height: 18),
                    Row(children: [
                      Expanded(child: KnockButton(key: const ValueKey('wallet-deposit'), label: 'Deposit', icon: Icons.add_rounded, style: KnockButtonStyle.light, onPressed: () => Nav.deposit(context))),
                      const SizedBox(width: 10),
                      Expanded(child: KnockButton(key: const ValueKey('wallet-withdraw'), label: 'Withdraw', icon: Icons.north_east_rounded, style: KnockButtonStyle.secondary, onPressed: () => Nav.withdraw(context))),
                    ]),
                  ]),
                ),
                const SizedBox(height: 12),
                KnockCard(
                  child: Column(children: [
                    KeyValue('Incoming (in review)', app.hideBalances ? '••••' : F.ngnExact(w['pendingIn'] as int)),
                    KeyValue('Bonus balance', app.hideBalances ? '••••' : F.ngnExact(w['bonus'] as int)),
                    Padding(padding: const EdgeInsets.only(top: 4), child: Text(w['bonusNote'] as String, style: KnockText.micro.copyWith(fontWeight: FontWeight.w400))),
                  ]),
                ),
                SectionTitle('Crypto', trailing: TextButton(onPressed: () => Nav.crypto(context), child: Text('Trade crypto', style: KnockText.bodyStrong.copyWith(color: KnockColors.greenBright)))),
                if (holdings.isEmpty)
                  KnockCard(
                    onTap: () => Nav.crypto(context, side: 'buy'),
                    child: Row(children: [
                      const Icon(Icons.currency_bitcoin_rounded, color: KnockColors.orange),
                      const SizedBox(width: 12),
                      Expanded(child: Text('No crypto yet. Buy, or receive crypto to sell it for naira.', style: KnockText.caption)),
                      const Icon(Icons.chevron_right_rounded),
                    ]),
                  )
                else
                  for (final h in holdings)
                    ListRow(
                      leading: Avatar(name: h['symbol'] as String),
                      title: h['name'] as String,
                      subtitle: '${(h['quantity'] as num).toStringAsFixed(6)} ${h['symbol']}',
                      trailing: BalanceText(F.ngn(h['valueKobo'] as int), hidden: app.hideBalances),
                      onTap: () => Nav.crypto(context, symbol: h['symbol'] as String),
                    ),
                const SectionTitle('Manage'),
                ListRow(icon: Icons.receipt_long_outlined, title: 'Transaction history', onTap: () => Nav.tab(context, ShellTab.history)),
                ListRow(icon: Icons.verified_user_outlined, title: 'Verification and limits', subtitle: 'You are on Tier ${app.tier}', onTap: () => Nav.verification(context)),
                ListRow(icon: Icons.flag_outlined, title: 'Get a USA Account', trailing: const Tag('Coming soon', color: KnockColors.orange), onTap: () => Nav.usaAccount(context)),
              ],
            ),
          );
        },
      ),
    );
  }
}
