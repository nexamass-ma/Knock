import 'package:material_ui/material_ui.dart';

import '../../app/app_scope.dart';
import '../../design/tokens.dart';
import '../../design/widgets/surfaces.dart';
import '../../models/catalog.dart';
import '../../models/quote.dart';
import '../assistant/transaction_widgets.dart';
import 'gift_card_common.dart';

class BuyGiftCardScreen extends StatefulWidget {
  const BuyGiftCardScreen({super.key});

  @override
  State<BuyGiftCardScreen> createState() => _BuyGiftCardScreenState();
}

class _BuyGiftCardScreenState extends State<BuyGiftCardScreen> {
  String? _brand;
  String _region = 'US';
  int? _value;
  Quote? _quote;
  bool _loading = false;
  bool _done = false;
  String? _error;
  String _key = newIdempotencyKey();

  bool get _ready => _brand != null && _value != null;

  void _changed(VoidCallback f) => setState(() {
    f();
    _quote = null;
    _error = null;
    _done = false;
    _key = newIdempotencyKey();
  });

  Future<void> _getQuote() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final q = await context.app.services.quotes.requestQuote(
        QuoteRequest(TxFlow.buyGiftCard, {'brand': _brand!, 'value': '$_value', 'region': _region}),
      );
      setState(() => _quote = q);
    } on QuoteException catch (e) {
      setState(() => _error = [e.message, e.suggestion].whereType<String>().join(' '));
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Buy gift cards'),
        actions: const [
          MockBadge(label: 'MOCK'),
          SizedBox(width: 16),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(KnockSpace.gutter, 0, KnockSpace.gutter, 40),
        children: [
          Text('Delivered as an e-code in seconds, paid from your Naira wallet.', style: KnockText.caption),
          const StepLabel(1, 'Choose a card'),
          BrandGrid(selected: _brand, onSelect: (b) => _changed(() => _brand = b)),
          const StepLabel(2, 'Region'),
          ChoiceChips<String>(
            values: const ['US', 'UK', 'Canada'],
            selected: _region,
            labelOf: (v) => v,
            onSelect: (v) => _changed(() => _region = v),
          ),
          const StepLabel(3, 'Value'),
          ChoiceChips<int>(
            values: GiftCardCatalog.denominations,
            selected: _value,
            labelOf: (v) => '\$$v',
            onSelect: (v) => _changed(() => _value = v),
          ),
          const SizedBox(height: KnockSpace.xl),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(_error!, style: KnockText.caption.copyWith(color: KnockColors.orange)),
            ),
          AnimatedSwitcher(
            duration: KnockMotion.base,
            child: _quote == null
                ? KnockButton(
                    key: const ValueKey('get'),
                    label: 'Get quote',
                    loading: _loading,
                    onPressed: _ready ? _getQuote : null,
                  )
                : QuoteCard(
                    key: ValueKey(_quote!.id),
                    quote: _quote!,
                    used: _done,
                    onRefresh: _getQuote,
                    onConfirm: () async {
                      final ok = await authorizeAndExecute(context, _quote!, _key);
                      if (ok && mounted) setState(() => _done = true);
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
