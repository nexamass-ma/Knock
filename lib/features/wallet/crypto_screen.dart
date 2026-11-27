import 'dart:math';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../../api/api.dart';
import '../../app/app_controller.dart';
import '../../core/format.dart';
import '../../design/tokens.dart';
import '../../design/widgets/kit.dart';
import '../common/pin_sheet.dart';
import '../common/success_screen.dart';
import '../history/transaction_detail_screen.dart';
import 'money_screens.dart';

class CryptoScreen extends StatefulWidget {
  const CryptoScreen({super.key, this.initialSide = 'sell', this.symbol});
  final String initialSide;
  final String? symbol;
  @override
  State<CryptoScreen> createState() => _CryptoScreenState();
}

class _CryptoScreenState extends State<CryptoScreen> {
  late String _side = widget.initialSide;
  late String _symbol = widget.symbol ?? 'USDT';
  final _amount = TextEditingController();
  Json? _quote;
  bool _busy = false;
  String? _error;
  String _idem = KnockApi.newIdempotencyKey();

  CryptoAsset get _asset => cryptoAssets.firstWhere((a) => a.symbol == _symbol);

  Future<void> _getQuote(Json wallet) async {
    setState(() {
      _error = null;
      _busy = true;
    });
    try {
      int? units;
      int? kobo;
      if (_side == 'buy') {
        kobo = parseNaira(_amount.text);
        if (kobo == null) throw ApiError('bad', 'Enter how much you want to spend.');
      } else {
        final q = double.tryParse(_amount.text.trim());
        if (q == null || q <= 0) throw ApiError('bad', 'Enter how much $_symbol to sell.');
        units = (q * pow(10, _asset.decimals)).round();
      }
      final r = await context.api.call((s, t) => s.cryptoQuote(t!, side: _side, symbol: _symbol, amountKobo: kobo, units: units));
      setState(() => _quote = r['quote'] as Json);
    } on ApiError catch (e) {
      if (e.code == 'tier_required') {
        if (mounted) showApiError(context, e);
      } else {
        setState(() => _error = e.message);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _execute() async {
    final q = _quote!;
    final api = context.api;
    try {
      final r = await withPin<Json>(context, title: q['side'] == 'buy' ? 'Confirm purchase' : 'Confirm sale', subtitle: '${(q['quantity'] as num).toStringAsFixed(6)} $_symbol for ${F.ngnExact(q['ngnKobo'] as int)}', action: (pin) {
        final sec = api.security();
        return api.call((s, t) => s.cryptoExecute(t!, quoteId: q['id'] as String, pin: pin, idempotencyKey: _idem, nonce: sec.nonce, sentAt: sec.sentAt));
      });
      if (r == null || !mounted) return;
      final txn = r['txn'] as Json;
      context.app.poke();
      await Navigator.of(context).pushReplacement(KRoute(ResultScreen(
        title: q['side'] == 'buy' ? 'You bought $_symbol' : 'Sale complete',
        amountKobo: q['ngnKobo'] as int,
        message: q['side'] == 'buy' ? '${txn['subtitle']} is in your crypto wallet.' : 'The naira is already in your wallet.',
        txn: txn,
        nextLabel: 'View details',
        onNext: () => Navigator.of(context).pushReplacement(KRoute(TransactionDetailScreen(txnId: txn['id'] as String))),
      )));
    } on ApiError catch (e) {
      if (e.code == 'quote_expired') {
        setState(() {
          _quote = null;
          _idem = KnockApi.newIdempotencyKey();
          _error = e.message;
        });
      } else if (mounted) {
        showApiError(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Crypto'), actions: [
        TextButton(key: const ValueKey('crypto-receive'), onPressed: () => go(context, CryptoReceiveScreen(symbol: _symbol)), child: Text('Receive', style: KnockText.bodyStrong.copyWith(color: KnockColors.greenBright))),
      ]),
      body: ApiView(
        load: (api) async {
          final r = await Future.wait([api.call((s, t) => s.cryptoMarkets(t!)), api.call((s, t) => s.wallet(t!))]);
          return {'m': r[0], 'w': r[1]};
        },
        builder: (context, d, _) {
          final m = d['m'] as Json;
          final w = d['w'] as Json;
          final assets = (m['assets'] as List).cast<Json>();
          final a = assets.firstWhere((x) => x['symbol'] == _symbol);
          final held = (w['holdings'] as List).cast<Json>().where((h) => h['symbol'] == _symbol).firstOrNull;
          final q = _quote;
          return ListView(padding: const EdgeInsets.all(KnockSpace.gutter), children: [
            PillTabs<String>(
              values: const ['sell', 'buy'],
              selected: _side,
              labelOf: (s) => s == 'sell' ? 'Sell' : 'Buy',
              onChanged: (s) => setState(() {
                _side = s;
                _quote = null;
                _amount.clear();
              }),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 86,
              child: ListView(scrollDirection: Axis.horizontal, children: [
                for (final x in assets)
                  Padding(
                    padding: const EdgeInsets.only(right: 10),
                    child: SizedBox(
                      width: 124,
                      child: KnockCard(
                        key: ValueKey('crypto-${x['symbol']}'),
                        padding: const EdgeInsets.all(12),
                        color: x['symbol'] == _symbol ? KnockColors.greenSoft : KnockColors.surface,
                        onTap: () => setState(() {
                          _symbol = x['symbol'] as String;
                          _quote = null;
                        }),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(x['symbol'] as String, style: KnockText.bodyStrong),
                          Text('\$${Fmt2.money((x['usd'] as num).toDouble())}', style: KnockText.caption),
                          ChangeText((x['change24h'] as num).toDouble()),
                        ]),
                      ),
                    ),
                  ),
              ]),
            ),
            const SizedBox(height: 12),
            KnockCard(child: Column(children: [
              KeyValue('${_side == 'buy' ? 'Buy' : 'Sell'} price', '${F.ngn(_side == 'buy' ? a['buyNgn'] as int : a['sellNgn'] as int)} per $_symbol'),
              KeyValue('You hold', held == null ? '0 $_symbol' : '${(held['quantity'] as num).toStringAsFixed(6)} $_symbol'),
              KeyValue('Naira wallet', F.ngnExact(w['available'] as int)),
              KeyValue('Updated', F.ago(a['updatedAt'] as String)),
            ])),
            const SizedBox(height: 16),
            KField(
              key: const ValueKey('crypto-amount'),
              label: _side == 'buy' ? 'Amount to spend (₦)' : 'Amount of $_symbol to sell',
              controller: _amount,
              keyboard: const TextInputType.numberWithOptions(decimal: true),
              formatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d.]'))],
              error: _error,
              onChanged: (_) => setState(() => _quote = null),
            ),
            if (_side == 'sell' && held != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(onPressed: () => _amount.text = (held['quantity'] as num).toString(), child: const Text('Sell all')),
              ),
            if (_side == 'sell' && held == null)
              Note('You have no $_symbol yet. Tap Receive to get your deposit address.', action: 'Receive $_symbol', onAction: () => go(context, CryptoReceiveScreen(symbol: _symbol))),
            const SizedBox(height: 12),
            if (q != null) ...[
              KnockCard(
                color: KnockColors.surfaceRaised,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Text('Your quote', style: KnockText.headline),
                    const Spacer(),
                    Countdown(
                      key: ValueKey(q['id']),
                      seconds: DateTime.parse(q['expiresAt'] as String).difference(context.api.server.now).inSeconds,
                      onDone: () => setState(() {}),
                      builder: (l) => Tag(l > 0 ? 'Locked · ${F.countdown(l)}' : 'Expired', color: l > 0 ? KnockColors.greenBright : KnockColors.loss),
                    ),
                  ]),
                  const SizedBox(height: 8),
                  KeyValue(q['side'] == 'buy' ? 'You receive' : 'You sell', '${(q['quantity'] as num).toStringAsFixed(6)} $_symbol', strong: true),
                  KeyValue(q['side'] == 'buy' ? 'You pay' : 'You receive', F.ngnExact(q['ngnKobo'] as int), strong: true),
                  KeyValue('Fee', F.ngnExact(q['fee'] as int)),
                  KeyValue('Rate', '₦${q['ngnPerUsd']}/\$ · \$${(q['usdPrice'] as num).toStringAsFixed(2)}'),
                ]),
              ),
              const SizedBox(height: 12),
              KnockButton(key: const ValueKey('crypto-confirm'), label: q['side'] == 'buy' ? 'Buy now' : 'Sell now', onPressed: _execute),
            ] else
              KnockButton(key: const ValueKey('crypto-quote'), label: 'Get quote', loading: _busy, onPressed: () => _getQuote(w)),
          ]);
        },
      ),
    );
  }
}

abstract final class Fmt2 {
  static String money(double v) => v >= 100 ? v.toStringAsFixed(0).replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',') : v.toStringAsFixed(2);
}

/// Deposit crypto, receive Naira. The address and every status come from
/// Knock's backend; the crypto partner behind it is never shown.
class CryptoReceiveScreen extends StatefulWidget {
  const CryptoReceiveScreen({super.key, required this.symbol});
  final String symbol;
  @override
  State<CryptoReceiveScreen> createState() => _CryptoReceiveScreenState();
}

class _CryptoReceiveScreenState extends State<CryptoReceiveScreen> {
  String? _assetId;
  Json? _address;
  bool _loadingAddress = false;
  String? _addressError;
  final _usd = TextEditingController(text: '25');

  Future<void> _loadAddress() async {
    final id = _assetId;
    if (id == null) return;
    setState(() {
      _loadingAddress = true;
      _addressError = null;
    });
    try {
      var a = await context.api.call((s, t) => s.cryptoDepositAddress(t!, id));
      if (mounted) setState(() => _address = a);
      // The first request takes a moment while the address is generated.
      for (var i = 0; i < 10 && a['status'] == 'Generating Address'; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 800));
        if (!mounted || _assetId != id) return;
        a = await context.api.call((s, t) => s.cryptoDepositAddress(t!, id));
        if (mounted) setState(() => _address = a);
      }
    } on ApiError catch (e) {
      if (!mounted) return;
      if (e.code == 'tier_required') {
        showApiError(context, e);
      }
      setState(() => _addressError = e.message);
    } finally {
      if (mounted) setState(() => _loadingAddress = false);
    }
  }

  Future<void> _simulate(String scenario) async {
    final usd = double.tryParse(_usd.text.trim());
    if (usd == null || usd <= 0) return toast(context, 'Enter a test amount in USD', error: true);
    try {
      await context.api.call((s, t) => s.sandboxCryptoDeposit(t!, _assetId!, scenario: scenario, usd: usd));
      if (!mounted) return;
      context.app.poke();
      toast(context, 'Test deposit sent. Watch its status below.');
    } catch (e) {
      if (mounted) showApiError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Deposit crypto')),
      body: ApiView(
        load: (api) async {
          final r = await Future.wait([api.call((s, t) => s.cryptoDepositOptions(t!)), api.call((s, t) => s.cryptoDeposits(t!))]);
          return {'o': r[0], 'd': r[1]};
        },
        builder: (context, data, _) {
          final o = data['o'] as Json;
          final assets = (o['assets'] as List).cast<Json>();
          if (_assetId == null) {
            _assetId = (assets.firstWhere((a) => a['symbol'] == widget.symbol, orElse: () => assets.first))['assetId'] as String;
            WidgetsBinding.instance.addPostFrameCallback((_) => _loadAddress());
          }
          final asset = assets.firstWhere((a) => a['assetId'] == _assetId);
          final deposits = ((data['d'] as Json)['items'] as List).cast<Json>();
          final addr = _address != null && _address!['assetId'] == _assetId ? _address : null;
          final ready = addr != null && addr['address'] != null;
          return ListView(padding: const EdgeInsets.all(KnockSpace.gutter), children: [
            Text('Send crypto to your Knock address. We convert it to Naira and add it to your wallet once it is confirmed.', style: KnockText.body.copyWith(color: KnockColors.textSecondary)),
            const SizedBox(height: 16),
            Text('Asset and network', style: KnockText.bodyStrong),
            const SizedBox(height: 8),
            ChoiceWrap<String>(
              choices: [for (final a in assets) Choice(a['assetId'] as String, a['network'] == '' ? a['symbol'] as String : '${a['symbol']} · ${a['network']}')],
              selected: _assetId,
              onSelected: (v) {
                setState(() {
                  _assetId = v;
                  _address = null;
                });
                _loadAddress();
              },
            ),
            const SizedBox(height: 16),
            KnockCard(
              key: const ValueKey('crypto-address-card'),
              child: Column(children: [
                if (_addressError != null)
                  Note(_addressError!, icon: Icons.error_outline_rounded, color: KnockColors.loss, action: 'Try again', onAction: _loadAddress)
                else if (!ready) ...[
                  const SizedBox(height: 24),
                  const CircularProgressIndicator(),
                  const SizedBox(height: 12),
                  Text(_loadingAddress || addr != null ? 'Generating your address…' : 'Loading…', style: KnockText.caption),
                  const SizedBox(height: 24),
                ] else ...[
                  Row(children: [
                    Text('Your ${asset['symbol']} address', style: KnockText.headline),
                    const Spacer(),
                    Tag(addr['status'] as String, color: KnockColors.greenBright),
                  ]),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(KnockRadius.md)),
                    child: QrImageView(
                      data: addr['address'] as String,
                      size: 170,
                      eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: Color(0xFF04120A)),
                      dataModuleStyle: const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.square, color: Color(0xFF04120A)),
                      semanticsLabel: 'QR code for your deposit address',
                    ),
                  ),
                  const SizedBox(height: 12),
                  KeyValue('Network', asset['networkName'] as String),
                  KeyValue('Address', addr['address'] as String, copy: true),
                  KeyValue('Minimum', '\$${(o['minimumUsd'] as num).toStringAsFixed(0)} worth'),
                  KeyValue('Confirmations', '${asset['confirmations']} needed'),
                  const SizedBox(height: 8),
                  Row(children: [
                    Expanded(child: KnockButton(key: const ValueKey('crypto-copy'), label: 'Copy', style: KnockButtonStyle.secondary, onPressed: () {
                      Clipboard.setData(ClipboardData(text: addr['address'] as String));
                      toast(context, 'Address copied');
                    })),
                    const SizedBox(width: 10),
                    Expanded(child: KnockButton(label: 'Share', style: KnockButtonStyle.secondary, onPressed: () {
                      SharePlus.instance.share(ShareParams(text: 'My ${asset['symbol']} (${asset['networkName']}) address: ${addr['address']}'));
                    })),
                  ]),
                ],
              ]),
            ),
            const SizedBox(height: 12),
            Note('Only send ${asset['symbol']} on ${asset['networkName']} to this address. Other assets or networks may be lost.', icon: Icons.warning_amber_rounded, color: KnockColors.orange),
            const SizedBox(height: 8),
            Note(o['note'] as String),
            const SizedBox(height: 8),
            const Note('Deposits below the minimum are held. Send a top-up to the same address and we credit the total once it reaches the minimum.'),
            SectionTitle('Your deposits'),
            if (deposits.isEmpty) Text('No crypto deposits yet.', style: KnockText.caption),
            for (final d in deposits) _DepositTile(d),
            const SizedBox(height: 24),
            KnockCard(
              color: KnockColors.surfaceRaised,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Row(children: [SandboxPill(), SizedBox(width: 8), Expanded(child: Text('Test-network deposits'))]),
                const SizedBox(height: 8),
                Text('No real crypto moves in this build. Send a test deposit to see each status.', style: KnockText.caption),
                const SizedBox(height: 8),
                KField(key: const ValueKey('crypto-sim-usd'), label: 'Test amount (USD)', controller: _usd, keyboard: const TextInputType.numberWithOptions(decimal: true)),
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final s in const [
                    ('completed', 'Confirms'),
                    ('confirming', 'Stays confirming'),
                    ('below_minimum', 'Below minimum'),
                    ('under_review', 'Review, then rejected'),
                    ('kyt_hold', 'Held for review'),
                    ('failed_on_chain', 'Fails on chain'),
                  ])
                    ActionChip(key: ValueKey('crypto-sim-${s.$1}'), label: Text(s.$2), onPressed: ready ? () => _simulate(s.$1) : null),
                ]),
              ]),
            ),
          ]);
        },
      ),
    );
  }
}

class _DepositTile extends StatelessWidget {
  const _DepositTile(this.d);
  final Json d;
  @override
  Widget build(BuildContext context) {
    final status = d['status'] as String;
    final chip = switch (status) { 'completed' => 'successful', 'failed' => 'failed', _ => 'pending' };
    final confs = d['confirmations'] as int;
    final need = d['requiredConfirmations'] as int;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: KnockCard(
        key: ValueKey('crypto-deposit-${d['id']}'),
        onTap: d['txnId'] == null ? null : () => go(context, TransactionDetailScreen(txnId: d['txnId'] as String)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text('${Fmt3.qty((d['cryptoAmount'] as num).toDouble())} ${d['symbol']}', style: KnockText.bodyStrong)),
            StatusChip(chip, label: d['customerStatus'] as String),
          ]),
          const SizedBox(height: 4),
          Text('${d['networkName']} · ${F.ago(d['createdAt'] as String)}', style: KnockText.caption),
          if (status == 'pending') ...[
            const SizedBox(height: 8),
            KProgress(need == 0 ? 0 : confs / need),
            const SizedBox(height: 4),
            Text('$confs of $need confirmations', style: KnockText.micro),
          ],
          if (status == 'completed' && (d['creditedKobo'] as int? ?? 0) > 0) ...[
            const SizedBox(height: 6),
            Text('${F.ngnExact(d['creditedKobo'] as int)} added to your wallet', style: KnockText.caption.copyWith(color: KnockColors.greenBright)),
          ],
          if (status != 'completed') ...[
            const SizedBox(height: 6),
            Text(d['message'] as String, style: KnockText.caption),
          ],
        ]),
      ),
    );
  }
}
