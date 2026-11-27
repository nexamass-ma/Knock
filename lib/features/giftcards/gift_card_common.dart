import 'dart:math';

import 'package:material_ui/material_ui.dart';

import '../../app/app_scope.dart';
import '../../design/tokens.dart';
import '../../design/widgets/surfaces.dart';
import '../../models/catalog.dart';
import '../../models/quote.dart';
import '../assistant/transaction_widgets.dart';

class BrandGrid extends StatelessWidget {
  const BrandGrid({super.key, required this.selected, required this.onSelect, this.showRates = false});
  final String? selected;
  final ValueChanged<String> onSelect;
  final bool showRates;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final w = (c.maxWidth - 20) / 3;
        return Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final b in GiftCardCatalog.brands)
              SizedBox(
                width: w,
                child: Semantics(
                  selected: b.id == selected,
                  child: KnockCard(
                    onTap: () => onSelect(b.id),
                    radius: KnockRadius.md,
                    color: b.id == selected ? KnockColors.surfaceRaised : KnockColors.surface,
                    padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
                    child: AnimatedContainer(
                      duration: KnockMotion.fast,
                      child: Column(
                        children: [
                          Stack(
                            clipBehavior: Clip.none,
                            children: [
                              GlyphAvatar(glyph: b.glyph, tint: b.tint, size: 40),
                              if (b.id == selected)
                                const Positioned(
                                  right: -4,
                                  bottom: -4,
                                  child: CircleAvatar(
                                    radius: 9,
                                    backgroundColor: KnockColors.green,
                                    child: Icon(Icons.check_rounded, size: 12, color: KnockColors.onGreen),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            b.name,
                            style: KnockText.caption.copyWith(color: KnockColors.textPrimary),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (showRates)
                            Text(
                              '~₦${b.sellRateNgn.round()}/\$',
                              style: KnockText.micro.copyWith(fontWeight: FontWeight.w400),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class ChoiceChips<T> extends StatelessWidget {
  const ChoiceChips({
    super.key,
    required this.values,
    required this.selected,
    required this.labelOf,
    required this.onSelect,
  });
  final List<T> values;
  final T? selected;
  final String Function(T) labelOf;
  final ValueChanged<T> onSelect;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final v in values)
          ChoiceChip(
            label: Text(labelOf(v)),
            selected: v == selected,
            onSelected: (_) => onSelect(v),
            showCheckmark: false,
            labelStyle: KnockText.caption.copyWith(
              fontWeight: FontWeight.w600,
              color: v == selected ? KnockColors.onGreen : KnockColors.textPrimary,
            ),
            selectedColor: KnockColors.green,
            backgroundColor: KnockColors.surfaceRaised,
            side: const BorderSide(color: KnockColors.stroke),
            shape: const StadiumBorder(),
          ),
      ],
    );
  }
}

class StepLabel extends StatelessWidget {
  const StepLabel(this.n, this.text, {super.key});
  final int n;
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: KnockSpace.xl, bottom: KnockSpace.sm),
    child: Row(
      children: [
        CircleAvatar(
          radius: 11,
          backgroundColor: KnockColors.greenSoft,
          child: Text('$n', style: KnockText.micro.copyWith(color: KnockColors.green)),
        ),
        const SizedBox(width: 10),
        Text(text, style: KnockText.bodyStrong),
      ],
    ),
  );
}

/// Shared confirm-and-execute path for non-chat screens: native
/// authorisation, idempotent execution, ledger refresh, receipt.
Future<bool> authorizeAndExecute(BuildContext context, Quote quote, String idempotencyKey) async {
  final app = context.app;
  final proof = await showAuthorizeSheet(context, quote);
  if (proof == null || !context.mounted) return false;
  try {
    final receipt = await app.services.transactions.execute(quote: quote, proof: proof, idempotencyKey: idempotencyKey);
    await app.wallet.load(silent: true);
    if (!context.mounted) return true;
    await showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(KnockSpace.gutter, 0, KnockSpace.gutter, KnockSpace.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ReceiptCard(receipt: receipt),
              const SizedBox(height: KnockSpace.md),
              KnockButton(label: 'Done', onPressed: () => Navigator.of(ctx).pop()),
            ],
          ),
        ),
      ),
    );
    return true;
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
    return false;
  }
}

String newIdempotencyKey() {
  final r = Random.secure();
  return List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}
