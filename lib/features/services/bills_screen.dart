import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/api.dart';
import '../../app/app_controller.dart';
import '../../core/format.dart';
import '../../design/tokens.dart';
import '../../design/widgets/kit.dart';
import '../shell/nav.dart';
import '../wallet/money_screens.dart';
import 'service_common.dart';

class BillsScreen extends StatelessWidget {
  const BillsScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final items = <(IconData, String, String, String)>[
      (Icons.phone_android_rounded, 'Airtime', 'All Nigerian networks', 'airtime'),
      (Icons.wifi_rounded, 'Data', 'Daily, weekly and monthly bundles', 'data'),
      (Icons.bolt_rounded, 'Electricity', 'Prepaid tokens', 'electricity'),
      (Icons.tv_rounded, 'Cable TV', 'DStv, GOtv, Startimes', 'cable'),
    ];
    return KPage(title: 'Bills', children: [
      for (final (icon, t, s, k) in items) ListRow(key: ValueKey('bills-$k'), icon: icon, title: t, subtitle: s, onTap: () => go(context, ServicePurchaseScreen(kind: k))),
      ListRow(icon: Icons.sports_soccer_rounded, title: 'Betting', subtitle: 'Fund your betting wallet', onTap: () => Nav.betting(context)),
      ListRow(icon: Icons.pin_outlined, title: 'E-pins', subtitle: 'Exam and recharge PINs', onTap: () => Nav.epins(context)),
      ListRow(icon: Icons.sim_card_outlined, title: 'eSIM & Data', subtitle: 'Travel data abroad', onTap: () => Nav.esim(context)),
    ]);
  }
}

/// Airtime, data, electricity and cable in one short form.
class ServicePurchaseScreen extends StatefulWidget {
  const ServicePurchaseScreen({super.key, required this.kind});
  final String kind;
  @override
  State<ServicePurchaseScreen> createState() => _ServicePurchaseScreenState();
}

class _ServicePurchaseScreenState extends State<ServicePurchaseScreen> {
  String? _biller;
  String? _plan;
  final _customer = TextEditingController();
  final _amount = TextEditingController();
  String? _customerName;
  String? _error;
  bool _busy = false;
  final _idem = KnockApi.newIdempotencyKey();

  String get _title => switch (widget.kind) { 'airtime' => 'Buy airtime', 'data' => 'Buy data', 'electricity' => 'Pay electricity', _ => 'Pay for cable TV' };

  @override
  void initState() {
    super.initState();
    if (widget.kind == 'airtime' || widget.kind == 'data') {
      final phone = context.app.me?['phone'] as String?;
      if (phone != null && phone.startsWith('+234')) _customer.text = '0${phone.substring(4)}';
      _biller = 'mtn';
    }
  }

  Future<void> _validate() async {
    if (_biller == null || _customer.text.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
      _customerName = null;
    });
    try {
      final r = await context.api.call((s, t) => s.validateCustomer(t!, kind: widget.kind, billerId: _biller!, customerId: _customer.text));
      setState(() => _customerName = r['customerName'] as String);
    } on ApiError catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pay(Json cat) async {
    final k = widget.kind;
    int? amount;
    String summary;
    if (_biller == null) return setState(() => _error = 'Choose a provider.');
    if (k == 'airtime' || k == 'electricity') {
      amount = parseNaira(_amount.text);
      if (amount == null) return setState(() => _error = 'Enter an amount.');
      summary = '${F.ngnExact(amount)} for ${_customer.text}';
    } else {
      if (_plan == null) return setState(() => _error = 'Choose a plan.');
      final plans = k == 'data' ? (cat['dataPlans'] as List) : ((cat['cable'] as List).firstWhere((b) => b['id'] == _biller)['plans'] as List);
      final p = plans.firstWhere((p) => p['id'] == _plan);
      summary = '${p['name']} · ${F.ngnExact(p['price'] as int)}';
    }
    if ((k == 'electricity' || k == 'cable') && _customerName == null) return setState(() => _error = 'Verify the ${k == 'cable' ? 'smartcard' : 'meter'} number first.');
    setState(() => _error = null);
    await payForService(context, kind: k, billerId: _biller!, planId: _plan, amountKobo: amount, customer: _customer.text.replaceAll(' ', ''), customerName: _customerName, idempotencyKey: _idem, summary: summary, nextLabel: k == 'electricity' ? 'Get my token' : 'View receipt');
  }

  @override
  Widget build(BuildContext context) {
    final k = widget.kind;
    return Scaffold(
      appBar: AppBar(title: Text(_title)),
      body: ApiView(
        live: false,
        load: (api) => api.call((s, t) => s.servicesCatalog(t!)),
        builder: (context, cat, _) {
          final billers = (switch (k) { 'electricity' => cat['discos'], 'cable' => cat['cable'], _ => cat['networks'] } as List).cast<Json>();
          final plans = k == 'data'
              ? (cat['dataPlans'] as List).cast<Json>()
              : k == 'cable' && _biller != null
                  ? ((billers.firstWhere((b) => b['id'] == _biller)['plans']) as List).cast<Json>()
                  : <Json>[];
          return ListView(padding: const EdgeInsets.all(KnockSpace.gutter), children: [
            Text(k == 'electricity' ? 'Electricity company' : k == 'cable' ? 'TV provider' : 'Network', style: KnockText.headline),
            const SizedBox(height: 10),
            ChoiceWrap<String>(choices: [for (final b in billers) Choice(b['id'] as String, b['name'] as String)], selected: _biller, onSelected: (v) => setState(() {
              _biller = v;
              _plan = null;
              _customerName = null;
            })),
            const SizedBox(height: 20),
            KField(
              key: const ValueKey('svc-customer'),
              label: switch (k) { 'electricity' => 'Meter number', 'cable' => 'Smartcard / IUC number', _ => 'Phone number' },
              controller: _customer,
              keyboard: TextInputType.number,
              formatters: [FilteringTextInputFormatter.digitsOnly],
              onChanged: (_) => setState(() => _customerName = null),
              suffix: (k == 'electricity' || k == 'cable') ? TextButton(onPressed: _busy ? null : _validate, child: const Text('Verify')) : null,
            ),
            if (_customerName != null) Padding(padding: const EdgeInsets.only(bottom: 12), child: Note('Account name: $_customerName', icon: Icons.check_circle_outline_rounded, color: KnockColors.greenBright)),
            if (k == 'airtime' || k == 'electricity') ...[
              KField(key: const ValueKey('svc-amount'), label: 'Amount (₦)', controller: _amount, keyboard: TextInputType.number, formatters: [FilteringTextInputFormatter.digitsOnly], helper: k == 'airtime' ? '₦50 to ₦50,000' : 'Minimum ₦1,000'),
              Wrap(spacing: 8, children: [
                for (final v in k == 'airtime' ? [100, 200, 500, 1000, 2000] : [2000, 5000, 10000, 20000])
                  ActionChip(label: Text(F.ngn(v * 100)), backgroundColor: KnockColors.surfaceRaised, onPressed: () => setState(() => _amount.text = '$v')),
              ]),
            ],
            if (plans.isNotEmpty) ...[
              Text(k == 'data' ? 'Data plan' : 'Package', style: KnockText.headline),
              const SizedBox(height: 10),
              for (final p in plans)
                RadioListTile<String>(
                  key: ValueKey('plan-${p['id']}'),
                  contentPadding: EdgeInsets.zero,
                  value: p['id'] as String,
                  groupValue: _plan,
                  onChanged: (v) => setState(() => _plan = v),
                  activeColor: KnockColors.green,
                  title: Text('${p['name']}${(p['detail'] as String).isNotEmpty ? ' · ${p['detail']}' : ''}', style: KnockText.body),
                  secondary: Text(F.ngn(p['price'] as int), style: KnockText.number),
                ),
            ],
            if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Note(_error!, color: KnockColors.loss, icon: Icons.error_outline_rounded)),
            const SizedBox(height: 20),
            KnockButton(key: const ValueKey('svc-pay'), label: 'Pay', loading: _busy, onPressed: () => _pay(cat)),
            const SizedBox(height: 10),
            const BalanceLine(),
            const SizedBox(height: 12),
            Text(cat['note'] as String, style: KnockText.micro.copyWith(color: KnockColors.orange, fontWeight: FontWeight.w400)),
          ]);
        },
      ),
    );
  }
}
