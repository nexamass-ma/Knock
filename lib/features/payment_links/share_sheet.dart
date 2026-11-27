import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../design/tokens.dart';
import '../../design/widgets/surfaces.dart';
import 'pl_models.dart';
import 'pl_split.dart';
import 'pl_widgets.dart';

String shareMessage(PaymentLink l) {
  final amount = l.amountMode == AmountMode.fixed ? ' ${PlFmt.money(l.fixedAmount!, l.asset)}' : '';
  return 'Pay$amount for "${l.title}" securely with Knock: ${l.url}';
}

Future<void> showShareSheet(BuildContext context, PaymentLink l) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: KnockColors.surfaceRaised,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(KnockRadius.xl))),
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(KnockSpace.gutter, KnockSpace.md, KnockSpace.gutter, KnockSpace.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(color: KnockColors.strokeStrong, borderRadius: BorderRadius.circular(2)),
            ),
            const SizedBox(height: KnockSpace.md),
            Text('Share "${l.title}"', style: KnockText.headline, textAlign: TextAlign.center),
            const SizedBox(height: KnockSpace.md),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(KnockRadius.md)),
              child: QrImageView(
                data: l.url,
                size: 180,
                eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: Color(0xFF04120A)),
                dataModuleStyle: const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.square, color: Color(0xFF04120A)),
                semanticsLabel: 'QR code for ${l.url}',
              ),
            ),
            const SizedBox(height: KnockSpace.sm),
            SelectableText(l.url, style: KnockText.caption, textAlign: TextAlign.center),
            const SizedBox(height: 4),
            Text(
              'Sandbox link: it opens the demo pay page inside this app only.',
              style: KnockText.micro.copyWith(color: KnockColors.orange),
            ),
            const SizedBox(height: KnockSpace.md),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _ShareAction(Icons.copy_rounded, 'Copy', () async {
                  await Clipboard.setData(ClipboardData(text: l.url));
                  if (ctx.mounted) plToast(ctx, 'Link copied');
                }),
                _ShareAction(
                  Icons.chat_rounded,
                  'WhatsApp',
                  () => _launch(ctx, Uri.parse('https://wa.me/?text=${Uri.encodeComponent(shareMessage(l))}')),
                ),
                _ShareAction(Icons.sms_outlined, 'SMS', () => _launch(ctx, Uri(scheme: 'sms', queryParameters: {'body': shareMessage(l)}))),
                _ShareAction(
                  Icons.mail_outline_rounded,
                  'Email',
                  () => _launch(
                    ctx,
                    Uri(
                      scheme: 'mailto',
                      query: 'subject=${Uri.encodeComponent('Payment request: ${l.title}')}&body=${Uri.encodeComponent(shareMessage(l))}',
                    ),
                  ),
                ),
                _ShareAction(
                  Icons.ios_share_rounded,
                  'More',
                  () => SharePlus.instance.share(ShareParams(text: shareMessage(l), subject: l.title)),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

Future<void> _launch(BuildContext context, Uri uri) async {
  final ok = await launchUrl(uri, mode: LaunchMode.externalApplication).catchError((_) => false);
  if (!ok && context.mounted) plToast(context, 'Could not open that app on this device.', error: true);
}

class _ShareAction extends StatelessWidget {
  const _ShareAction(this.icon, this.label, this.onTap);
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => CircleAction(icon: icon, label: label, onTap: onTap);
}
