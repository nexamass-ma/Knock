import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/api.dart';
import '../../app/app_controller.dart';
import '../../design/tokens.dart';
import '../../design/widgets/kit.dart';

/// Layout shared by the sign-up and login screens.
class AuthScaffold extends StatelessWidget {
  const AuthScaffold({super.key, required this.title, this.subtitle, required this.children, this.bottom, this.step, this.onBack});
  final String title;
  final String? subtitle;
  final List<Widget> children;
  final Widget? bottom;
  final (int, int)? step;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final canPop = Navigator.of(context).canPop();
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leading: onBack != null || canPop
            ? IconButton(tooltip: 'Back', icon: const Icon(Icons.arrow_back_rounded), onPressed: onBack ?? () => Navigator.of(context).maybePop())
            : null,
        title: step == null ? null : _Steps(step!.$1, step!.$2),
        actions: const [Padding(padding: EdgeInsets.only(right: 16), child: SandboxPill())],
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(KnockSpace.gutter, 8, KnockSpace.gutter, 24),
          children: [
            Text(title, style: KnockText.title),
            if (subtitle != null) ...[const SizedBox(height: 8), Text(subtitle!, style: KnockText.body.copyWith(color: KnockColors.textSecondary))],
            const SizedBox(height: 24),
            ...children,
          ],
        ),
      ),
      bottomNavigationBar: bottom == null
          ? null
          : SafeArea(child: Padding(padding: const EdgeInsets.fromLTRB(KnockSpace.gutter, 8, KnockSpace.gutter, 12), child: bottom)),
    );
  }
}

class _Steps extends StatelessWidget {
  const _Steps(this.i, this.n);
  final int i, n;
  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Step $i of $n',
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var k = 1; k <= n; k++)
          AnimatedContainer(
            duration: KnockMotion.base,
            margin: const EdgeInsets.symmetric(horizontal: 3),
            width: k == i ? 22 : 8,
            height: 8,
            decoration: BoxDecoration(color: k <= i ? KnockColors.green : KnockColors.surfaceHigh, borderRadius: BorderRadius.circular(8)),
          ),
      ],
    ),
  );
}

/// Six-box code entry backed by one hidden text field.
class CodeInput extends StatefulWidget {
  const CodeInput({super.key, required this.controller, required this.onCompleted, this.error, this.length = 6});
  final TextEditingController controller;
  final ValueChanged<String> onCompleted;
  final String? error;
  final int length;

  @override
  State<CodeInput> createState() => _CodeInputState();
}

class _CodeInputState extends State<CodeInput> {
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  void _changed() {
    setState(() {});
    if (widget.controller.text.length == widget.length) widget.onCompleted(widget.controller.text);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = widget.controller.text;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Stack(
          children: [
            Row(
              children: [
                for (var i = 0; i < widget.length; i++) ...[
                  Expanded(
                    child: AnimatedContainer(
                      duration: KnockMotion.fast,
                      height: 58,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: KnockColors.surfaceRaised,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          width: 1.5,
                          color: widget.error != null
                              ? KnockColors.loss
                              : (i == text.length && _focus.hasFocus)
                                  ? KnockColors.green
                                  : KnockColors.stroke,
                        ),
                      ),
                      child: Text(i < text.length ? text[i] : '', style: KnockText.title),
                    ),
                  ),
                  if (i < widget.length - 1) const SizedBox(width: 8),
                ],
              ],
            ),
            Positioned.fill(
              child: Opacity(
                opacity: 0.011,
                child: TextField(
                  key: const ValueKey('code-field'),
                  controller: widget.controller,
                  focusNode: _focus,
                  autofillHints: const [AutofillHints.oneTimeCode],
                  keyboardType: TextInputType.number,
                  maxLength: widget.length,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  showCursor: false,
                  decoration: const InputDecoration(counterText: '', filled: false, border: InputBorder.none),
                ),
              ),
            ),
          ],
        ),
        if (widget.error != null) ...[
          const SizedBox(height: 8),
          Text(widget.error!, style: KnockText.caption.copyWith(color: KnockColors.loss)),
        ],
      ],
    );
  }
}

/// Resend button with a countdown.
class ResendButton extends StatefulWidget {
  const ResendButton({super.key, required this.onResend, this.initialSeconds = 60});
  final Future<bool> Function() onResend;
  final int initialSeconds;

  @override
  State<ResendButton> createState() => _ResendButtonState();
}

class _ResendButtonState extends State<ResendButton> {
  late int _left = widget.initialSeconds;
  Timer? _t;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  void _start() {
    _t?.cancel();
    _t = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _left = (_left - 1).clamp(0, 999));
      if (_left == 0) _t?.cancel();
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ready = _left == 0 && !_busy;
    return TextButton(
      onPressed: ready
          ? () async {
              setState(() => _busy = true);
              final ok = await widget.onResend();
              if (!mounted) return;
              setState(() {
                _busy = false;
                if (ok) {
                  _left = 60;
                  _start();
                }
              });
            }
          : null,
      child: Text(ready ? 'Resend code' : _busy ? 'Sending…' : 'Resend code in 0:${_left.toString().padLeft(2, '0')}',
          style: KnockText.bodyStrong.copyWith(color: ready ? KnockColors.greenBright : KnockColors.textTertiary)),
    );
  }
}

/// Sandbox-only helper that shows the newest code sent to this account, so
/// testers can finish verification without a real inbox. Never shown in
/// production builds.
class SandboxCodeHint extends StatefulWidget {
  const SandboxCodeHint({super.key, this.email, required this.onUse});
  final String? email;
  final ValueChanged<String> onUse;

  @override
  State<SandboxCodeHint> createState() => _SandboxCodeHintState();
}

class _SandboxCodeHintState extends State<SandboxCodeHint> {
  String? _code;
  String? _to;
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _poll();
    _t = Timer.periodic(const Duration(seconds: 2), (_) => _poll());
  }

  Future<void> _poll() async {
    final api = context.api;
    try {
      final r = widget.email != null
          ? await api.call((s, _) => s.sandboxInboxFor(widget.email!))
          : await api.call((s, t) => s.sandboxInbox(t!));
      final items = (r['items'] as List).cast<Map<String, dynamic>>();
      final m = items.where((m) => RegExp(r'\d{6}').hasMatch(m['body'] as String)).firstOrNull;
      if (!mounted) return;
      setState(() {
        _code = m == null ? null : RegExp(r'\d{6}').firstMatch(m['body'] as String)!.group(0);
        _to = m?['to'] as String?;
      });
    } catch (_) {}
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_code == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: KnockCard(
        color: KnockColors.orangeSoft,
        onTap: () => widget.onUse(_code!),
        child: Row(
          children: [
            const Icon(Icons.science_outlined, color: KnockColors.orange),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Sandbox inbox', style: KnockText.micro.copyWith(color: KnockColors.orange)),
                  const SizedBox(height: 2),
                  Text('Code sent to ${_to ?? 'you'}: $_code', style: KnockText.bodyStrong),
                  Text('Tap to fill. In the live app this arrives by email or SMS.', style: KnockText.caption),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class PasswordMeter extends StatelessWidget {
  const PasswordMeter(this.score, {super.key});
  final int score;

  @override
  Widget build(BuildContext context) {
    const labels = ['Too weak', 'Weak', 'Fair', 'Good', 'Strong'];
    final colors = [KnockColors.loss, KnockColors.loss, KnockColors.orange, KnockColors.greenBright, KnockColors.green];
    return Semantics(
      label: 'Password strength: ${labels[score]}',
      child: Row(
        children: [
          for (var i = 0; i < 4; i++) ...[
            Expanded(
              child: AnimatedContainer(
                duration: KnockMotion.base,
                height: 4,
                decoration: BoxDecoration(color: i < score ? colors[score] : KnockColors.surfaceHigh, borderRadius: BorderRadius.circular(4)),
              ),
            ),
            const SizedBox(width: 4),
          ],
          const SizedBox(width: 6),
          Text(labels[score], style: KnockText.micro.copyWith(color: colors[score])),
        ],
      ),
    );
  }
}
