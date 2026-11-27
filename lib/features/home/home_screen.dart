import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/api.dart';
import '../../app/app_controller.dart';
import '../../core/format.dart';
import '../../core/money.dart';
import '../../design/tokens.dart';
import '../../design/widgets/kit.dart';
import '../common/receipt.dart';
import '../history/txn_tile.dart';
import '../shell/nav.dart';
import '../shell/shell.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  static Future<Json> load(KnockApi api) async {
    final r = await Future.wait([
      api.call((s, t) => s.wallet(t!)),
      api.call((s, t) => s.suggestions(t!)),
      api.call((s, t) => s.welcomeBonus(t!)),
      api.call((s, t) => s.fireLoad(t!)),
      api.call((s, t) => s.transactions(t!, limit: 5)),
      api.call((s, t) => s.referrals(t!)),
    ]);
    return {'wallet': r[0], 'suggestions': r[1], 'bonus': r[2], 'campaigns': r[3], 'txns': r[4], 'referrals': r[5]};
  }

  @override
  Widget build(BuildContext context) {
    final app = context.appWatch;
    return Scaffold(
      body: ApiView(
        load: load,
        skeleton: const SafeArea(child: Padding(padding: EdgeInsets.all(20), child: SkeletonList())),
        builder: (context, d, reload) => RefreshIndicator(
          color: KnockColors.green,
          onRefresh: reload,
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
            slivers: [
              SliverToBoxAdapter(child: _Hero(wallet: d['wallet'] as Json, app: app)),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(KnockSpace.gutter, 8, KnockSpace.gutter, 32),
                sliver: SliverList.list(children: [
                  if (app.tier < 2) _VerifyNudge(tier: app.tier),
                  const SectionTitle('Quick actions', top: 16),
                  _QuickActions(suggestions: ((d['suggestions'] as Json)['items'] as List).cast<Json>()),
                  _WelcomeBonusCard(bonus: d['bonus'] as Json),
                  _Promos(items: ((d['campaigns'] as Json)['items'] as List).cast<Json>()),
                  _InviteCard(ref: d['referrals'] as Json),
                  const SectionTitle('Services'),
                  const _Services(),
                  SectionTitle('Recent transactions', trailing: TextButton(onPressed: () => Nav.tab(context, ShellTab.history), child: Text('See all', style: KnockText.bodyStrong.copyWith(color: KnockColors.greenBright)))),
                  ..._recent(context, ((d['txns'] as Json)['items'] as List).cast<Json>(), app.hideBalances),
                ]),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _recent(BuildContext context, List<Json> items, bool hidden) {
    if (items.isEmpty) {
      return [
        EmptyState(
          icon: Icons.receipt_long_outlined,
          title: 'No transactions yet',
          message: 'Your trades, payments and transfers will show up here.',
          action: 'Sell a gift card',
          onAction: () => Nav.sellGiftCard(context),
        ),
      ];
    }
    return [for (final t in items) TxnTile(t, hidden: hidden)];
  }
}

class _Hero extends StatelessWidget {
  const _Hero({required this.wallet, required this.app});
  final Json wallet;
  final AppController app;

  @override
  Widget build(BuildContext context) {
    final available = wallet['available'] as int;
    final bonus = wallet['bonus'] as int;
    final pending = wallet['pendingIn'] as int;
    final crypto = wallet['cryptoValue'] as int;
    final cur = app.currency;
    final shell = ShellScope.of(context);
    return Container(
      decoration: const BoxDecoration(
        gradient: KnockColors.cardGradient,
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(KnockRadius.xl)),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, KnockSpace.gutter, 22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const MenuButton(),
                const SizedBox(width: 4),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(Fmt.greeting(DateTime.now()), style: KnockText.caption.copyWith(color: Colors.white70)),
                    Text('Welcome back, ${app.firstName}', style: KnockText.headline, overflow: TextOverflow.ellipsis),
                  ]),
                ),
                BellButton(onTap: () => Nav.notifications(context)),
              ]),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 22, 0, 0),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(key: shell?.walletKey, children: [
                    Text('Available balance', style: KnockText.caption.copyWith(color: Colors.white70)),
                    const SizedBox(width: 6),
                    InkResponse(
                      key: const ValueKey('toggle-balance'),
                      radius: 18,
                      onTap: () {
                        HapticFeedback.selectionClick();
                        app.toggleHideBalances();
                      },
                      child: Icon(app.hideBalances ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 18, color: Colors.white70, semanticLabel: app.hideBalances ? 'Show balance' : 'Hide balance'),
                    ),
                  ]),
                  const SizedBox(height: 6),
                  BalanceText(F.display(available, cur), hidden: app.hideBalances, style: KnockText.display),
                  if (cur != 'NGN') Text('≈ settles as ${F.ngnExact(available)}', style: KnockText.caption.copyWith(color: Colors.white60)),
                  const SizedBox(height: 8),
                  Wrap(spacing: 8, runSpacing: 6, children: [
                    if (pending > 0) Tag('${app.hideBalances ? '•••' : F.ngn(pending)} incoming', color: KnockColors.orange, icon: Icons.schedule_rounded),
                    if (bonus > 0) Tag('${app.hideBalances ? '•••' : F.ngn(bonus)} bonus', color: KnockColors.greenBright, icon: Icons.card_giftcard_rounded),
                    if (crypto > 0) GestureDetector(onTap: () => Nav.crypto(context), child: Tag('${app.hideBalances ? '•••' : F.ngn(crypto)} in crypto', color: Colors.white70, icon: Icons.currency_bitcoin_rounded)),
                  ]),
                  const SizedBox(height: 18),
                  Row(children: [
                    Expanded(child: KnockButton(key: const ValueKey('home-deposit'), label: 'Deposit', icon: Icons.add_rounded, style: KnockButtonStyle.light, onPressed: () => Nav.deposit(context))),
                    const SizedBox(width: 10),
                    Expanded(child: KnockButton(key: const ValueKey('home-withdraw'), label: 'Withdraw', icon: Icons.north_east_rounded, style: KnockButtonStyle.secondary, onPressed: () => Nav.withdraw(context))),
                  ]),
                  const SizedBox(height: 10),
                  Row(children: [
                    Expanded(child: _Pill(icon: Icons.sell_outlined, label: 'Sell', onTap: () => Nav.tab(context, ShellTab.trade))),
                    const SizedBox(width: 10),
                    Expanded(child: _Pill(icon: Icons.shopping_bag_outlined, label: 'Buy crypto', onTap: () => Nav.crypto(context, side: 'buy'))),
                    const SizedBox(width: 10),
                    Expanded(child: _Pill(key: shell?.ratesKey, icon: Icons.trending_up_rounded, label: 'Current Rates', onTap: () => Nav.rates(context))),
                  ]),
                ]),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({super.key, required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Material(
    color: Colors.black.withValues(alpha: 0.22),
    borderRadius: BorderRadius.circular(KnockRadius.pill),
    child: InkWell(
      borderRadius: BorderRadius.circular(KnockRadius.pill),
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(icon, size: 16, color: Colors.white),
          const SizedBox(width: 6),
          Flexible(child: Text(label, style: KnockText.caption.copyWith(color: Colors.white, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis)),
        ]),
      ),
    ),
  );
}

class _VerifyNudge extends StatelessWidget {
  const _VerifyNudge({required this.tier});
  final int tier;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: KnockCard(
      onTap: () => Nav.verification(context),
      child: Row(children: [
        const Icon(Icons.verified_user_outlined, color: KnockColors.orange),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('You are on Tier $tier', style: KnockText.bodyStrong),
            Text(tier < 1 ? 'Verify your phone to start trading.' : 'Verify your BVN, NIN and bank to unlock withdrawals and higher limits.', style: KnockText.caption),
            const SizedBox(height: 8),
            KProgress(tier / 3, color: KnockColors.orange, height: 6),
          ]),
        ),
        const SizedBox(width: 8),
        Text('Upgrade', style: KnockText.caption.copyWith(color: KnockColors.greenBright, fontWeight: FontWeight.w700)),
      ]),
    ),
  );
}

class _QuickActions extends StatelessWidget {
  const _QuickActions({required this.suggestions});
  final List<Json> suggestions;

  @override
  Widget build(BuildContext context) {
    final actions = <(IconData, String, VoidCallback)>[
      (Icons.card_giftcard_rounded, 'Sell Gift Card', () => Nav.sellGiftCard(context)),
      (Icons.currency_bitcoin_rounded, 'Sell Crypto', () => Nav.crypto(context)),
      (Icons.phone_android_rounded, 'Buy Airtime', () => Nav.bills(context, kind: 'airtime')),
      (Icons.receipt_rounded, 'Pay Bills', () => Nav.billsHub(context)),
      (Icons.wifi_rounded, 'Buy Data', () => Nav.bills(context, kind: 'data')),
      (Icons.redeem_rounded, 'Send Gift Card', () => Nav.sendGift(context)),
      (Icons.trending_up_rounded, 'Check Current Rates', () => Nav.rates(context)),
      (Icons.auto_awesome_rounded, 'Knock AI', () => Nav.knockAi(context)),
    ];
    return Column(children: [
      if (suggestions.isNotEmpty) ...[
        SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              for (final s in suggestions)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ActionChip(
                    key: ValueKey('suggest-${s['brandId']}-${s['currency']}'),
                    avatar: const Icon(Icons.bolt_rounded, size: 16, color: KnockColors.greenBright),
                    label: Text('Sell ${s['brand']} ${s['currency']} again', style: KnockText.caption.copyWith(color: KnockColors.textPrimary)),
                    backgroundColor: KnockColors.surfaceRaised,
                    side: const BorderSide(color: KnockColors.stroke),
                    shape: const StadiumBorder(),
                    onPressed: () => Nav.sellGiftCard(context, brandId: s['brandId'] as String, currency: s['currency'] as String, cardType: s['cardType'] as String?, faceValue: s['faceValue'] as int?),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
      ],
      GridView.count(
        crossAxisCount: 4,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 14,
        crossAxisSpacing: 8,
        childAspectRatio: 0.78,
        children: [
          for (final (icon, label, onTap) in actions)
            Semantics(
              button: true,
              label: label,
              excludeSemantics: true,
              child: InkWell(
                key: ValueKey('qa-$label'),
                borderRadius: BorderRadius.circular(16),
                onTap: () {
                  HapticFeedback.selectionClick();
                  onTap();
                },
                child: Column(children: [
                  Container(
                    width: 54,
                    height: 54,
                    decoration: BoxDecoration(color: KnockColors.surfaceRaised, borderRadius: BorderRadius.circular(18), border: Border.all(color: KnockColors.stroke)),
                    child: Icon(icon, color: KnockColors.greenBright, size: 24),
                  ),
                  const SizedBox(height: 8),
                  Text(label, textAlign: TextAlign.center, maxLines: 2, style: KnockText.micro.copyWith(color: KnockColors.textPrimary, fontWeight: FontWeight.w500)),
                ]),
              ),
            ),
        ],
      ),
    ]);
  }
}

class _WelcomeBonusCard extends StatelessWidget {
  const _WelcomeBonusCard({required this.bonus});
  final Json bonus;
  @override
  Widget build(BuildContext context) {
    final status = bonus['status'] as String;
    if (status == 'credited' || status == 'blocked' || status == 'reversed') return const SizedBox.shrink();
    final steps = (bonus['steps'] as List).cast<Json>();
    final done = steps.where((s) => s['done'] == true).length;
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: KnockCard(
        gradient: const LinearGradient(colors: [Color(0xFF2A1A10), Color(0xFF14141A)]),
        onTap: () => Nav.rewards(context),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.card_giftcard_rounded, color: KnockColors.orange),
            const SizedBox(width: 10),
            Expanded(child: Text('Your ${F.ngn(bonus['amount'] as int)} welcome bonus', style: KnockText.bodyStrong)),
            StatusChip(status == 'in_progress' ? 'pending' : 'active', label: status == 'in_progress' ? 'Trade in review' : '$done of ${steps.length} done'),
          ]),
          const SizedBox(height: 8),
          Text('Complete your first gift card or crypto trade and we add it to your bonus balance. Bonus balance is not withdrawable.', style: KnockText.caption),
          const SizedBox(height: 10),
          KProgress(done / steps.length, color: KnockColors.orange, height: 6),
        ]),
      ),
    );
  }
}

class _Promos extends StatelessWidget {
  const _Promos({required this.items});
  final List<Json> items;
  @override
  Widget build(BuildContext context) {
    final live = items.where((c) => c['state'] == 'live').toList();
    if (live.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SectionTitle('Fire Load', trailing: TextButton(onPressed: () => Nav.fireLoad(context), child: Text('All campaigns', style: KnockText.bodyStrong.copyWith(color: KnockColors.greenBright)))),
      SizedBox(
        height: 132,
        child: PageView(
          controller: PageController(viewportFraction: live.length > 1 ? 0.9 : 1),
          padEnds: false,
          children: [
            for (final c in live)
              Padding(
                padding: const EdgeInsets.only(right: 10),
                child: KnockCard(
                  gradient: const LinearGradient(colors: [Color(0xFF3A1606), Color(0xFF0F2A19)]),
                  onTap: () => Nav.fireLoad(context),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      const Icon(Icons.local_fire_department_rounded, color: KnockColors.orange, size: 18),
                      const SizedBox(width: 6),
                      Expanded(child: Text(c['title'] as String, style: KnockText.bodyStrong, overflow: TextOverflow.ellipsis)),
                    ]),
                    const SizedBox(height: 6),
                    Text(c['subtitle'] as String? ?? '', style: KnockText.caption, maxLines: 2, overflow: TextOverflow.ellipsis),
                    const Spacer(),
                    Countdown(seconds: c['secondsLeft'] as int, builder: (l) => Text('Ends in ${F.countdown(l)}', style: KnockText.micro.copyWith(color: KnockColors.orange))),
                  ]),
                ),
              ),
          ],
        ),
      ),
    ]);
  }
}

class _InviteCard extends StatelessWidget {
  const _InviteCard({required this.ref});
  final Json ref;
  @override
  Widget build(BuildContext context) {
    final link = ref['link'] as String;
    final text = 'Join me on Knock and trade gift cards and crypto in minutes. Sign up with my code ${ref['code']}: $link';
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: KnockCard(
        child: Row(children: [
          const Icon(Icons.group_add_rounded, color: Color(0xFF7FA7FF)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Invite friends, earn ${F.ngn(ref['rewardPerReferral'] as int)}', style: KnockText.bodyStrong),
              Text('When each friend trades \$${ref['qualifyUsd']} in eligible volume.', style: KnockText.caption),
            ]),
          ),
          const SizedBox(width: 8),
          KnockButton(
            key: const ValueKey('home-invite'),
            label: 'Share',
            icon: Icons.ios_share_rounded,
            expand: false,
            onPressed: () async {
              context.api.call((s, t) => s.recordInvite(t!, 'share'));
              await shareText(context, text, subject: 'Join me on Knock');
            },
          ),
        ]),
      ),
    );
  }
}

class _Services extends StatelessWidget {
  const _Services();
  @override
  Widget build(BuildContext context) {
    final items = <(IconData, String, String, VoidCallback)>[
      (Icons.sports_soccer_rounded, 'Betting', 'Fund your wallet', () => Nav.betting(context)),
      (Icons.pin_outlined, 'E-pins', 'Recharge and exam pins', () => Nav.epins(context)),
      (Icons.sim_card_outlined, 'eSIM & Data', 'Travel data in 150+ countries', () => Nav.esim(context)),
      (Icons.bolt_rounded, 'Electricity', 'Prepaid and postpaid', () => Nav.bills(context, kind: 'electricity')),
      (Icons.tv_rounded, 'Cable TV', 'DStv, GOtv, Startimes', () => Nav.bills(context, kind: 'cable')),
      (Icons.flag_outlined, 'USA Account', 'Coming soon', () => Nav.usaAccount(context)),
    ];
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      childAspectRatio: 2.3,
      children: [
        for (final (icon, title, sub, onTap) in items)
          KnockCard(
            key: ValueKey('svc-$title'),
            padding: const EdgeInsets.all(12),
            onTap: onTap,
            child: Row(children: [
              Icon(icon, color: KnockColors.greenBright, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: KnockText.bodyStrong, overflow: TextOverflow.ellipsis),
                  Text(sub, style: KnockText.micro.copyWith(fontWeight: FontWeight.w400), maxLines: 1, overflow: TextOverflow.ellipsis),
                ]),
              ),
            ]),
          ),
      ],
    );
  }
}

