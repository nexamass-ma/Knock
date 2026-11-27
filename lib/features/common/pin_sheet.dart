import 'package:material_ui/material_ui.dart';

import '../../api/api.dart';
import '../../app/app_controller.dart';
import '../../design/tokens.dart';
import '../../design/widgets/kit.dart';
import '../../design/widgets/pin_pad.dart';

/// Asks for the transaction PIN and runs [action] with it. Wrong PINs stay in
/// the sheet with the server's message. Any other error closes the sheet and
/// is rethrown to the caller. If the customer has no PIN yet, they create one
/// first. Returns null if they close the sheet.
Future<T?> withPin<T>(BuildContext context, {required String title, String? subtitle, required Future<T> Function(String pin) action}) async {
  final app = context.app;
  if (!app.hasPin) {
    final created = await createPin(context);
    if (created == null || !context.mounted) return null;
    return action(created);
  }
  Object? failure;
  final r = await showModalBottomSheet<_Box<T>>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _PinSheet<T>(title: title, subtitle: subtitle, action: action, onFailure: (e) => failure = e),
  );
  if (failure != null) throw failure!;
  return r?.value;
}

class _Box<T> {
  _Box(this.value);
  final T value;
}

class _PinSheet<T> extends StatefulWidget {
  const _PinSheet({required this.title, this.subtitle, required this.action, required this.onFailure});
  final String title;
  final String? subtitle;
  final Future<T> Function(String pin) action;
  final void Function(Object) onFailure;
  @override
  State<_PinSheet<T>> createState() => _PinSheetState<T>();
}

class _PinSheetState<T> extends State<_PinSheet<T>> {
  String? _error;
  bool _busy = false;

  Future<void> _run(String pin) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final v = await widget.action(pin);
      if (mounted) Navigator.pop(context, _Box(v));
    } on ApiError catch (e) {
      if (e.code == 'bad_pin') {
        setState(() => _error = e.message);
      } else {
        widget.onFailure(e);
        if (mounted) Navigator.pop(context);
      }
    } catch (e) {
      widget.onFailure(e);
      if (mounted) Navigator.pop(context);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.title, style: KnockText.headline, textAlign: TextAlign.center),
            if (widget.subtitle != null) ...[const SizedBox(height: 6), Text(widget.subtitle!, style: KnockText.caption, textAlign: TextAlign.center)],
            const SizedBox(height: 20),
            PinPad(onComplete: _run, error: _error, busy: _busy),
          ],
        ),
      ),
    );
  }
}

/// Create (or change) the 4-digit transaction PIN. Returns the new PIN.
Future<String?> createPin(BuildContext context, {bool change = false}) {
  return showModalBottomSheet<String>(context: context, isScrollControlled: true, builder: (_) => _CreatePin(change: change));
}

class _CreatePin extends StatefulWidget {
  const _CreatePin({required this.change});
  final bool change;
  @override
  State<_CreatePin> createState() => _CreatePinState();
}

class _CreatePinState extends State<_CreatePin> {
  String? _current;
  String? _first;
  String? _error;
  bool _busy = false;

  String get _title => widget.change && _current == null
      ? 'Enter your current PIN'
      : _first == null
          ? (widget.change ? 'Choose a new PIN' : 'Create your transaction PIN')
          : 'Confirm your PIN';

  Future<void> _step(String pin) async {
    if (widget.change && _current == null) {
      setState(() {
        _current = pin;
        _error = null;
      });
      return;
    }
    if (_first == null) {
      setState(() {
        _first = pin;
        _error = null;
      });
      return;
    }
    if (pin != _first) {
      setState(() {
        _first = null;
        _error = 'The PINs did not match. Try again.';
      });
      return;
    }
    setState(() => _busy = true);
    final app = context.app;
    try {
      final r = await app.api.call((s, t) => s.setPin(t!, pin, currentPin: _current));
      app.updateMe(r['user'] as Json);
      if (mounted) Navigator.pop(context, pin);
    } on ApiError catch (e) {
      setState(() {
        _first = null;
        if (e.code == 'bad_pin' && widget.change) _current = null;
        _error = e.message;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(_title, style: KnockText.headline),
        const SizedBox(height: 6),
        Text('You will use it to approve payments and reveal codes. Avoid 1234 or repeated digits.', style: KnockText.caption, textAlign: TextAlign.center),
        const SizedBox(height: 20),
        PinPad(key: ValueKey(_title), onComplete: _step, error: _error, busy: _busy),
      ]),
    ),
  );
}

/// Ensures the account is on at least [tier]; otherwise explains and offers the upgrade.
bool requireTier(BuildContext context, int tier, String what) {
  if (context.app.tier >= tier) return true;
  showApiError(context, ApiError('tier_required', '$what needs Tier $tier verification. It only takes a few minutes.', details: {'tier': tier}));
  return false;
}

/// Small helper text for sandbox-only behaviour.
class SandboxNote extends StatelessWidget {
  const SandboxNote(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Note(text, icon: Icons.science_outlined, color: KnockColors.orange);
}
