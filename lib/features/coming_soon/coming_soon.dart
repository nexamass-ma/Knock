import 'package:material_ui/material_ui.dart';

import '../../api/api.dart';
import '../../app/app_controller.dart';
import '../../core/format.dart';
import '../../design/tokens.dart';
import '../../design/widgets/kit.dart';

/// Shared "Notify me" block: records explicit consent with the waitlist.
class NotifyMe extends StatefulWidget {
  const NotifyMe({super.key, required this.product, required this.consentText});
  final String product;
  final String consentText;
  @override
  State<NotifyMe> createState() => _NotifyMeState();
}

class _NotifyMeState extends State<NotifyMe> {
  bool _consent = false;
  bool _busy = false;

  Future<void> _join() async {
    setState(() => _busy = true);
    try {
      final r = await context.api.call((s, t) => s.joinWaitlist(t!, widget.product, consent: _consent));
      if (!mounted) return;
      context.app.poke();
      toast(context, "You're on the list (#${r['position']}). We'll tell you first.");
    } catch (e) {
      if (mounted) showApiError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ApiView(
      load: (api) => api.call((s, t) => s.waitlistStatus(t!, widget.product)),
      builder: (context, d, _) {
        if (d['joined'] == true) {
          return KnockCard(
            key: ValueKey('waitlist-joined-${widget.product}'),
            color: KnockColors.greenSoft,
            child: Row(children: [
              const Icon(Icons.check_circle_rounded, color: KnockColors.greenBright),
              const SizedBox(width: 10),
              Expanded(child: Text("You're on the list since ${F.date(d['joinedAt'] as String)}. We'll notify you when it launches.", style: KnockText.body)),
            ]),
          );
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          CheckboxListTile(
            key: ValueKey('waitlist-consent-${widget.product}'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _consent,
            onChanged: (v) => setState(() => _consent = v == true),
            title: Text(widget.consentText, style: KnockText.caption),
          ),
          KnockButton(key: ValueKey('waitlist-join-${widget.product}'), label: 'Notify me', icon: Icons.notifications_active_outlined, loading: _busy, onPressed: _consent && !_busy ? _join : null),
        ]);
      },
    );
  }
}
