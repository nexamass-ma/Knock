import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../design/widgets/kit.dart';

const supportPhoneDisplay = '+44 7575 895007';
const supportPhoneE164 = '+447575895007';
const supportWhatsApp = 'https://wa.me/447575895007';

Future<void> openExternal(BuildContext context, Uri uri, {String? fallbackCopy}) async {
  var ok = false;
  try {
    ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {}
  if (!ok && context.mounted) {
    if (fallbackCopy != null) {
      await Clipboard.setData(ClipboardData(text: fallbackCopy));
      if (context.mounted) toast(context, 'Could not open it here. Copied $fallbackCopy');
    } else {
      toast(context, 'Could not open that on this device.', error: true);
    }
  }
}

Future<void> callSupport(BuildContext context) => openExternal(context, Uri.parse('tel:$supportPhoneE164'), fallbackCopy: supportPhoneDisplay);

Future<void> whatsAppSupport(BuildContext context, {String? message}) =>
    openExternal(context, Uri.parse(message == null ? supportWhatsApp : '$supportWhatsApp?text=${Uri.encodeComponent(message)}'), fallbackCopy: supportPhoneDisplay);

Future<void> whatsAppShare(BuildContext context, String text) =>
    openExternal(context, Uri.parse('https://wa.me/?text=${Uri.encodeComponent(text)}'), fallbackCopy: text);
