import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/app_scope.dart';
import '../../design/tokens.dart';
import '../../design/widgets/surfaces.dart';
import '../../models/catalog.dart';
import '../../models/chat.dart';
import '../../models/quote.dart';
import '../assistant/transaction_widgets.dart';
import 'gift_card_common.dart';

/// Sell flow: pick brand, photograph the card, KNOCK identifies it, the
/// partner verifies, the backend quotes, the user confirms.
class SellGiftCardScreen extends StatefulWidget {
  const SellGiftCardScreen({super.key});

  @override
  State<SellGiftCardScreen> createState() => _SellGiftCardScreenState();
}

class _SellGiftCardScreenState extends State<SellGiftCardScreen> {
  String? _brand;
  String _type = 'Physical';
  Uint8List? _image;
  bool _scanning = false;
  GiftCardScanResult? _scan;
  int? _value;
  Quote? _quote;
  bool _quoting = false;
  bool _done = false;
  String? _error;
  String _key = newIdempotencyKey();

  void _reset() {
    _quote = null;
    _done = false;
    _error = null;
    _key = newIdempotencyKey();
  }

  Future<void> _pick(ImageSource source) async {
    try {
      final f = await ImagePicker().pickImage(source: source, maxWidth: 1600, imageQuality: 85);
      if (f == null) return;
      final bytes = await f.readAsBytes();
      if (!mounted) return;
      setState(() {
        _image = bytes;
        _scanning = true;
        _scan = null;
        _reset();
      });
      final scan = await context.app.services.recognition.recognize(bytes, hintBrandId: _brand);
      if (!mounted) return;
      setState(() {
        _scan = scan;
        _brand = scan.brandId;
        _value = scan.faceValueUsd;
        _scanning = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _getQuote() async {
    setState(() {
      _quoting = true;
      _error = null;
    });
    try {
      final q = await context.app.services.quotes.requestQuote(
        QuoteRequest(TxFlow.sellGiftCard, {
          'brand': _brand!,
          'value': '$_value',
          'cardType': _type,
          'region': _scan?.region ?? 'US',
        }),
      );
      setState(() => _quote = q);
    } on QuoteException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _quoting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ready = _brand != null && _value != null && _image != null && !_scanning;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sell gift cards'),
        actions: const [
          MockBadge(label: 'MOCK'),
          SizedBox(width: 16),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(KnockSpace.gutter, 0, KnockSpace.gutter, 40),
        children: [
          KnockCard(
            color: KnockColors.surfaceRaised,
            onTap: () {
              Navigator.of(context).pop();
              context.app.shell.openAssistant(TxFlow.sellGiftCard);
            },
            child: Row(
              children: [
                const KnockMarkBadge(),
                const SizedBox(width: 12),
                Expanded(
                  child: Text('Prefer to chat? Sell your card with KNOCK in conversation.', style: KnockText.caption),
                ),
                const Icon(Icons.chevron_right_rounded, color: KnockColors.textTertiary),
              ],
            ),
          ),
          const StepLabel(1, 'Which card?'),
          BrandGrid(
            selected: _brand,
            showRates: true,
            onSelect: (b) => setState(() {
              _brand = b;
              _reset();
            }),
          ),
          const StepLabel(2, 'Card type'),
          ChoiceChips<String>(
            values: const ['Physical', 'E-code'],
            selected: _type,
            labelOf: (v) => v,
            onSelect: (v) => setState(() {
              _type = v;
              _reset();
            }),
          ),
          const StepLabel(3, 'Photo of the card'),
          _PhotoBox(image: _image, scanning: _scanning, onPick: _pick),
          if (_scan != null) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                const Icon(Icons.verified_outlined, color: KnockColors.green, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Identified ${_scan!.brandName} · \$${_scan!.faceValueUsd} (${(_scan!.confidence * 100).round()}% match, mock scan)',
                    style: KnockText.caption.copyWith(color: KnockColors.textPrimary),
                  ),
                ),
              ],
            ),
          ],
          const StepLabel(4, 'Face value'),
          ChoiceChips<int>(
            values: GiftCardCatalog.denominations,
            selected: _value,
            labelOf: (v) => '\$$v',
            onSelect: (v) => setState(() {
              _value = v;
              _reset();
            }),
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
                    label: 'Verify and get rate',
                    loading: _quoting,
                    onPressed: ready ? _getQuote : null,
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
          if (!ready && _quote == null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                'Pick a card, add a photo and confirm the value to get a rate.',
                style: KnockText.micro.copyWith(fontWeight: FontWeight.w400),
                textAlign: TextAlign.center,
              ),
            ),
        ],
      ),
    );
  }
}

class KnockMarkBadge extends StatelessWidget {
  const KnockMarkBadge({super.key});
  @override
  Widget build(BuildContext context) => Container(
    width: 38,
    height: 38,
    decoration: const BoxDecoration(color: KnockColors.greenSoft, shape: BoxShape.circle),
    child: const Icon(Icons.chat_bubble_outline_rounded, size: 18, color: KnockColors.green),
  );
}

class _PhotoBox extends StatelessWidget {
  const _PhotoBox({required this.image, required this.scanning, required this.onPick});
  final Uint8List? image;
  final bool scanning;
  final ValueChanged<ImageSource> onPick;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 180,
      decoration: BoxDecoration(
        color: KnockColors.surface,
        borderRadius: BorderRadius.circular(KnockRadius.lg),
        border: Border.all(color: KnockColors.strokeStrong),
      ),
      clipBehavior: Clip.antiAlias,
      child: image == null
          ? Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.document_scanner_outlined, color: KnockColors.orange, size: 30),
                const SizedBox(height: 8),
                Text('Front of the card, code area visible', style: KnockText.caption),
                const SizedBox(height: 14),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    KnockButton(
                      label: 'Camera',
                      icon: Icons.photo_camera_outlined,
                      expand: false,
                      onPressed: () => onPick(ImageSource.camera),
                    ),
                    const SizedBox(width: 10),
                    KnockButton(
                      label: 'Photos',
                      icon: Icons.photo_library_outlined,
                      expand: false,
                      style: KnockButtonStyle.secondary,
                      onPressed: () => onPick(ImageSource.gallery),
                    ),
                  ],
                ),
              ],
            )
          : Stack(
              fit: StackFit.expand,
              children: [
                Image.memory(image!, fit: BoxFit.cover),
                if (scanning)
                  Container(
                    color: Colors.black54,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const CircularProgressIndicator(color: KnockColors.green),
                        const SizedBox(height: 10),
                        Text('Identifying card…', style: KnockText.caption.copyWith(color: Colors.white)),
                      ],
                    ),
                  ),
                if (!scanning)
                  Positioned(
                    right: 10,
                    bottom: 10,
                    child: KnockButton(
                      label: 'Retake',
                      expand: false,
                      style: KnockButtonStyle.light,
                      onPressed: () => onPick(ImageSource.gallery),
                    ),
                  ),
              ],
            ),
    );
  }
}
