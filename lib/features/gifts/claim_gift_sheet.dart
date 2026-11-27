import 'package:material_ui/material_ui.dart';

import '../../api/api.dart';
import '../../app/app_controller.dart';
import '../../design/tokens.dart';
import '../../design/widgets/kit.dart';
import '../shell/nav.dart';

Future<void> showClaimGiftSheet(BuildContext context) async {
  final c = TextEditingController();
  final link = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (s) => Padding(
      padding: EdgeInsets.fromLTRB(24, 0, 24, 24 + MediaQuery.viewInsetsOf(s).bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Claim a gift link', style: KnockText.title),
        const SizedBox(height: 6),
        Text('Paste the link someone sent you. Each link works once.', style: KnockText.caption),
        const SizedBox(height: 16),
        KField(key: const ValueKey('claim-field'), label: 'Gift link', controller: c, hint: 'https://knock.app/gift/…', autofocus: true),
        KnockButton(key: const ValueKey('claim-submit'), label: 'Claim gift', onPressed: () => Navigator.pop(s, c.text)),
      ]),
    ),
  );
  if (link == null || link.trim().isEmpty || !context.mounted) return;
  try {
    final r = await context.api.call((s, t) => s.claimGift(t!, link));
    if (!context.mounted) return;
    context.app.poke();
    await Nav.gift(context, (r['gift'] as Json)['id'] as String);
  } catch (e) {
    if (context.mounted) showApiError(context, e);
  }
}
