import 'package:material_ui/material_ui.dart';

import '../../api/api.dart';
import '../../app/app_controller.dart';
import '../../design/tokens.dart';
import '../../design/widgets/kit.dart';
import 'auth_common.dart';
import 'forgot_password_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final app = context.app;
    try {
      final r = await app.api.call((s, _) => s.login(email: _email.text, password: _password.text, deviceId: app.api.deviceId, deviceName: 'Knock app'));
      if (r['twoFactorRequired'] == true) {
        if (!mounted) return;
        await go(context, TwoFactorScreen(challenge: r['challenge'] as String, email: r['email'] as String, rawEmail: _email.text));
        return;
      }
      await app.signedIn(r['token'] as String, r['user'] as Json);
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    } on ApiError catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      title: 'Welcome back',
      subtitle: 'Log in to pick up where you left off.',
      bottom: KnockButton(key: const ValueKey('login-submit'), label: 'Log In', loading: _busy, onPressed: _submit),
      children: [
        AutofillGroup(
          child: Column(children: [
            KField(key: const ValueKey('login-email'), label: 'Email', controller: _email, keyboard: TextInputType.emailAddress, autofill: const [AutofillHints.email], textInputAction: TextInputAction.next),
            KField(key: const ValueKey('login-password'), label: 'Password', controller: _password, password: true, autofill: const [AutofillHints.password], onSubmitted: (_) => _submit()),
          ]),
        ),
        if (_error != null) Note(_error!, icon: Icons.error_outline_rounded, color: KnockColors.loss),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () => go(context, ForgotPasswordScreen(email: _email.text)),
            child: Text('Forgot password?', style: KnockText.bodyStrong.copyWith(color: KnockColors.greenBright)),
          ),
        ),
      ],
    );
  }
}

class TwoFactorScreen extends StatefulWidget {
  const TwoFactorScreen({super.key, required this.challenge, required this.email, required this.rawEmail});
  final String challenge;
  final String email;
  final String rawEmail;
  @override
  State<TwoFactorScreen> createState() => _TwoFactorScreenState();
}

class _TwoFactorScreenState extends State<TwoFactorScreen> {
  final _code = TextEditingController();
  String? _error;
  bool _busy = false;

  Future<void> _verify(String code) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final app = context.app;
    try {
      final r = await app.api.call((s, _) => s.completeTwoFactor(widget.challenge, code));
      await app.signedIn(r['token'] as String, r['user'] as Json);
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    } on ApiError catch (e) {
      setState(() => _error = e.message);
      _code.clear();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AuthScaffold(
    title: 'Two-step verification',
    subtitle: 'Enter the 6-digit code we sent to ${widget.email}.',
    bottom: KnockButton(label: 'Verify', loading: _busy, onPressed: () => _verify(_code.text)),
    children: [
      CodeInput(controller: _code, onCompleted: _verify, error: _error),
      SandboxCodeHint(email: widget.rawEmail, onUse: (c) => _code.text = c),
    ],
  );
}
