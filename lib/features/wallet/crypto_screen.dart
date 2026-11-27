import 'dart:math';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

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

class CryptoReceiveScreen extends StatelessWidget {
  const CryptoReceiveScreen({super.key, required this.symbol});
  final String symbol;
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Receive $symbol')),
      body: ApiView(
        live: false,
        load: (api) => api.call((s, t) => s.cryptoReceiveAddress(t!, symbol)),
        builder: (context, d, _) => ListView(padding: const EdgeInsets.all(KnockSpace.gutter), children: [
          KnockCard(child: Column(children: [
            KeyValue('Network', d['network'] as String),
            KeyValue('Address', d['address'] as String, copy: true),
          ])),
          const SizedBox(height: 12),
          const Note('Only send this asset on this network. Sending anything else may be lost.', icon: Icons.warning_amber_rounded, color: KnockColors.orange),
          const SizedBox(height: 12),
          SandboxNote(d['note'] as String),
          const SizedBox(height: 16),
          KnockButton(
            key: const ValueKey('crypto-sim-deposit'),
            label: 'Simulate a test-network deposit',
            style: KnockButtonStyle.secondary,
            onPressed: () async {
              try {
                await context.api.call((s, t) => s.simulateCryptoDeposit(t!, symbol));
                if (!context.mounted) return;
                context.app.poke();
                toast(context, '$symbol received on the test network');
                Navigator.pop(context);
              } catch (e) {
                if (context.mounted) showApiError(context, e);
              }
            },
          ),
        ]),
      ),
    );
  }
}
