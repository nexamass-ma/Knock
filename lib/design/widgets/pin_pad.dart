import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../tokens.dart';

/// Four-dot PIN entry with a native-feeling keypad.
class PinPad extends StatefulWidget {
  const PinPad({super.key, required this.onComplete, this.length = 4, this.error, this.busy = false, this.onBiometric});
  final Future<void> Function(String pin) onComplete;
  final int length;
  final String? error;
  final bool busy;
  final VoidCallback? onBiometric;

  @override
  State<PinPad> createState() => _PinPadState();
}

class _PinPadState extends State<PinPad> {
  String _pin = '';

  @override
  void didUpdateWidget(PinPad old) {
    super.didUpdateWidget(old);
    if (widget.error != null && widget.error != old.error) setState(() => _pin = '');
  }

  void _tap(String d) async {
    if (widget.busy || _pin.length >= widget.length) return;
    HapticFeedback.selectionClick();
    setState(() => _pin += d);
    if (_pin.length == widget.length) {
      final pin = _pin;
      await widget.onComplete(pin);
      if (mounted) setState(() => _pin = '');
    }
  }

  void _back() {
    if (_pin.isEmpty) return;
    HapticFeedback.selectionClick();
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  @override
  Widget build(BuildContext context) {
    Widget key(String d) => _Key(label: d, onTap: () => _tap(d));
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          label: '${_pin.length} of ${widget.length} digits entered',
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < widget.length; i++)
                AnimatedContainer(
                  duration: KnockMotion.fast,
                  margin: const EdgeInsets.symmetric(horizontal: 9),
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: i < _pin.length ? KnockColors.green : Colors.transparent,
                    border: Border.all(
                      color: widget.error != null ? KnockColors.loss : KnockColors.strokeStrong,
                      width: 1.5,
                    ),
                  ),
                ),
            ],
          ),
        ),
        SizedBox(
          height: 34,
          child: Center(
            child: widget.busy
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(widget.error ?? '', style: KnockText.caption.copyWith(color: KnockColors.loss)),
          ),
        ),
        for (final row in const [
          ['1', '2', '3'],
          ['4', '5', '6'],
          ['7', '8', '9'],
        ])
          Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [for (final d in row) key(d)]),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            widget.onBiometric == null
                ? const SizedBox(width: 72, height: 64)
                : _Key(icon: Icons.fingerprint_rounded, semantic: 'Use biometrics', onTap: widget.onBiometric!),
            key('0'),
            _Key(icon: Icons.backspace_outlined, semantic: 'Delete', onTap: _back),
          ],
        ),
      ],
    );
  }
}

class _Key extends StatelessWidget {
  const _Key({this.label, this.icon, this.semantic, required this.onTap});
  final String? label;
  final IconData? icon;
  final String? semantic;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semantic ?? label,
      excludeSemantics: true,
      child: InkResponse(
        onTap: onTap,
        radius: 36,
        child: SizedBox(
          width: 72,
          height: 64,
          child: Center(
            child: label != null
                ? Text(label!, style: KnockText.title.copyWith(fontWeight: FontWeight.w500))
                : Icon(icon, color: KnockColors.textSecondary),
          ),
        ),
      ),
    );
  }
}
