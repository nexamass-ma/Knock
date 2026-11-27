import 'package:material_ui/material_ui.dart';

import '../../api/api.dart';
import '../../app/app_controller.dart';
import '../../design/tokens.dart';
import '../../design/widgets/kit.dart';
import '../../sandbox/util.dart' show passwordStrength;
import 'auth_common.dart';

class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key, this.email = ''});
  final String email;
  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  late final _email = TextEditingController(text: widget.email);
  final _code = TextEditingController();
  final _password = TextEditingController();
  bool _sent = false;
  bool _busy = false;
  String? _error;
  String? _info;

  Future<void> _send() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await context.api.call((s, _) => s.forgotPassword(_email.text));
      setState(() {
        _sent = true;
        _info = r['message'] as String;
      });
    } on ApiError catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reset() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.api.call((s, _) => s.resetPassword(email: _email.text, code: _code.text, newPassword: _password.text));
      if (!mounted) return;
      toast(context, 'Password updated. Please log in.');
      Navigator.of(context).pop();
    } on ApiError catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_sent) {
      return AuthScaffold(
        title: 'Reset your password',
        subtitle: 'Enter the email on your account and we will send you a reset code.',
        bottom: KnockButton(key: const ValueKey('forgot-send'), label: 'Send reset code', loading: _busy, onPressed: _send),
        children: [
          KField(key: const ValueKey('forgot-email'), label: 'Email', controller: _email, keyboard: TextInputType.emailAddress, autofill: const [AutofillHints.email]),
          if (_error != null) Note(_error!, color: KnockColors.loss, icon: Icons.error_outline_rounded),
        ],
      );
    }
    return AuthScaffold(
      title: 'Choose a new password',
      subtitle: _info,
      bottom: KnockButton(key: const ValueKey('forgot-reset'), label: 'Update password', loading: _busy, onPressed: _reset),
      children: [
        CodeInput(controller: _code, onCompleted: (_) {}),
        const SizedBox(height: 16),
        KField(key: const ValueKey('forgot-password'), label: 'New password', controller: _password, password: true, autofill: const [AutofillHints.newPassword], onChanged: (_) => setState(() {})),
        if (_password.text.isNotEmpty) PasswordMeter(passwordStrength(_password.text)),
        const SizedBox(height: 12),
        const Note('For your security, withdrawals and gift sends pause for 24 hours after a password reset, and every device is signed out.'),
        if (_error != null) ...[const SizedBox(height: 12), Note(_error!, color: KnockColors.loss, icon: Icons.error_outline_rounded)],
        Align(alignment: Alignment.centerLeft, child: ResendButton(onResend: () async {
          try {
            await context.api.call((s, _) => s.forgotPassword(_email.text));
            return true;
          } on ApiError catch (e) {
            if (mounted) showApiError(context, e);
            return false;
          }
        })),
        SandboxCodeHint(email: _email.text, onUse: (c) => _code.text = c),
      ],
    );
  }
}
