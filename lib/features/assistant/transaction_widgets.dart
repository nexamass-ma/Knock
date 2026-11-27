import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/app_scope.dart';
import '../../core/money.dart';
import '../../design/tokens.dart';
import '../../design/widgets/pin_pad.dart';
import '../../design/widgets/surfaces.dart';
import '../../models/ledger.dart';
import '../../models/quote.dart';

/// Structured, server-issued quote. Shared by chat and the gift card
/// screens. Shows a live expiry countdown; an expired quote can only be
/// refreshed, never confirmed.
class QuoteCard extends StatefulWidget {
  const QuoteCard({
    super.key,
    required this.quote,
    required this.onConfirm,
    required this.onRefresh,
    this.used = false,
  });
  final Quote quote;
  final VoidCallback onConfirm;
  final VoidCallback onRefresh;
  final bool used;

  @override
  State<QuoteCard> createState() => _QuoteCardState();
}

class _QuoteCardState extends State<QuoteCard> {
  Timer? _timer;
  late Duration _left;

  @override
  void initState() {
    super.initState();
    _tick();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  void _tick() {
    final left = widget.quote.expiresAt.difference(DateTime.now());
    if (!mounted) return;
    setState(() => _left = left.isNegative ? Duration.zero : left);
    if (left.isNegative) _timer?.cancel();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = widget.quote;
    final expired = _left == Duration.zero;
    final secs = _left.inSeconds;
    final countdown = secs >= 60 ? '${_left.inMinutes}m ${(secs % 60).toString().padLeft(2, '0')}s' : '${secs}s';

    return Container(
      decoration: BoxDecoration(
        color: KnockColors.surface,
        borderRadius: BorderRadius.circular(KnockRadius.lg),
        border: Border.all(color: KnockColors.stroke),
        boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 24, offset: Offset(0, 12))],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(16, 14, 12, 12),
            decoration: const BoxDecoration(gradient: KnockColors.cardGradient),
            child: Row(
              children: [
                const Icon(Icons.receipt_long_rounded, size: 18, color: KnockColors.greenBright),
                const SizedBox(width: 8),
                Expanded(child: Text(q.title, style: KnockText.bodyStrong)),
                if (q.isMock) const MockBadge(label: 'MOCK'),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Column(
              children: [
                for (final l in q.lines)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 130),
                          child: Text(l.label, style: KnockText.caption),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: Text(
                              l.value,
                              textAlign: TextAlign.right,
                              style: KnockText.number.copyWith(fontSize: 14),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Divider()),
                Row(
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 130),
                      child: Text(q.totalLabel, style: KnockText.bodyStrong),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerRight,
                        child: Text(
                          q.total.format(),
                          style: KnockText.number.copyWith(fontSize: 18, color: KnockColors.greenBright),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 130),
                      child: Text(q.receiveLabel, style: KnockText.caption),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: Text(
                          q.receive,
                          textAlign: TextAlign.right,
                          style: KnockText.number.copyWith(fontSize: 14),
                        ),
                      ),
                    ),
                  ],
                ),
                if (q.note != null) ...[
                  const SizedBox(height: 10),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.info_outline_rounded, size: 14, color: KnockColors.textSecondary),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(q.note!, style: KnockText.micro.copyWith(fontWeight: FontWeight.w400)),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            child: widget.used
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(8),
                      child: Tag('Confirmed', color: KnockColors.green, icon: Icons.check_rounded),
                    ),
                  )
                : Column(
                    children: [
                      if (expired)
                        KnockButton(
                          label: 'Refresh quote',
                          icon: Icons.refresh_rounded,
                          onPressed: widget.onRefresh,
                          style: KnockButtonStyle.secondary,
                        )
                      else
                        KnockButton(
                          label: 'Confirm transaction',
                          icon: Icons.lock_outline_rounded,
                          onPressed: widget.onConfirm,
                        ),
                      const SizedBox(height: 8),
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          expired
                              ? 'Quote expired. Prices move, so get a fresh one.'
                              : 'Price held for $countdown · Ref ${q.id}',
                          style: KnockText.micro.copyWith(
                            fontWeight: FontWeight.w400,
                            color: expired ? KnockColors.orange : KnockColors.textTertiary,
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

/// Native confirmation step. Only this sheet can produce an
/// [AuthorizationProof]. The assistant has no way to call it on its own.
Future<AuthorizationProof?> showAuthorizeSheet(BuildContext context, Quote quote) {
  return showModalBottomSheet<AuthorizationProof>(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    builder: (_) => _AuthorizeSheet(quote: quote),
  );
}

class _AuthorizeSheet extends StatefulWidget {
  const _AuthorizeSheet({required this.quote});
  final Quote quote;
  @override
  State<_AuthorizeSheet> createState() => _AuthorizeSheetState();
}

class _AuthorizeSheetState extends State<_AuthorizeSheet> {
  bool _bio = false;
  bool _showPin = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final app = context.app;
      final ok = await app.services.biometrics.isAvailable();
      if (!mounted) return;
      setState(() {
        _bio = ok && app.session.biometricsEnabled;
        _showPin = !_bio;
      });
    });
  }

  AuthorizationProof _proof(String method) => AuthorizationProof(
    quoteId: widget.quote.id,
    method: method,
    signedChallenge: 'mock-sig-${widget.quote.id}-${DateTime.now().millisecondsSinceEpoch}',
    at: DateTime.now(),
  );

  Future<void> _useBiometrics() async {
    final ok = await context.app.services.biometrics.verify(
      'Confirm ${widget.quote.title} for ${widget.quote.total.format()}',
    );
    if (!mounted) return;
    if (ok) {
      HapticFeedback.mediumImpact();
      Navigator.of(context).pop(_proof('biometrics'));
    } else {
      setState(() => _showPin = true);
    }
  }

  Future<void> _pin(String pin) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = await context.app.services.pin.verify(pin);
    if (!mounted) return;
    if (ok) {
      HapticFeedback.mediumImpact();
      Navigator.of(context).pop(_proof('PIN'));
    } else {
      setState(() {
        _busy = false;
        _error = 'Incorrect PIN';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final q = widget.quote;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(KnockSpace.gutter, 0, KnockSpace.gutter, KnockSpace.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Authorise payment', style: KnockText.caption),
            const SizedBox(height: 6),
            Text(q.total.format(), style: KnockText.display.copyWith(fontSize: 34)),
            const SizedBox(height: 4),
            Text('${q.title} · ${q.receiveLabel}: ${q.receive}', style: KnockText.caption, textAlign: TextAlign.center),
            const SizedBox(height: KnockSpace.lg),
            if (_showPin) ...[
              Text('Enter your KNOCK PIN', style: KnockText.bodyStrong),
              const SizedBox(height: 4),
              Text('Prototype: any 4 digits except 0000', style: KnockText.micro.copyWith(color: KnockColors.orange)),
              const SizedBox(height: 14),
              PinPad(onComplete: _pin, error: _error, busy: _busy, onBiometric: _bio ? _useBiometrics : null),
            ] else ...[
              KnockButton(label: 'Confirm with biometrics', icon: Icons.fingerprint_rounded, onPressed: _useBiometrics),
              const SizedBox(height: 10),
              KnockButton(
                label: 'Use PIN instead',
                style: KnockButtonStyle.ghost,
                onPressed: () => setState(() => _showPin = true),
              ),
            ],
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.shield_outlined, size: 14, color: KnockColors.textTertiary),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    'Priced and settled by KNOCK servers. Nothing moves until you confirm.',
                    style: KnockText.micro.copyWith(color: KnockColors.textTertiary, fontWeight: FontWeight.w400),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class ReceiptCard extends StatelessWidget {
  const ReceiptCard({super.key, required this.receipt});
  final TransactionReceipt receipt;

  @override
  Widget build(BuildContext context) {
    final r = receipt.record;
    final review = r.status == TxStatus.inReview;
    final color = review ? KnockColors.orange : KnockColors.green;
    return Semantics(
      liveRegion: true,
      child: KnockCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(color: color.withValues(alpha: 0.15), shape: BoxShape.circle),
                  child: Icon(review ? Icons.hourglass_top_rounded : Icons.check_rounded, color: color, size: 20),
                ),
                const SizedBox(width: 10),
                Expanded(child: Text(receipt.headline, style: KnockText.headline)),
                Tag(r.status.label, color: color),
              ],
            ),
            const SizedBox(height: 10),
            Text(receipt.detail, style: KnockText.body.copyWith(color: KnockColors.textSecondary)),
            const SizedBox(height: 12),
            Row(
              children: [
                Text('Ref ${r.reference}', style: KnockText.micro),
                const Spacer(),
                Text('${r.isCredit ? '+' : '-'}${r.amount.format()}', style: KnockText.number),
              ],
            ),
            Text(Fmt.time(r.createdAt), style: KnockText.micro.copyWith(color: KnockColors.textTertiary)),
          ],
        ),
      ),
    );
  }
}
