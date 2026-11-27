import 'package:material_ui/material_ui.dart';

import '../../api/api.dart';
import '../../app/app_controller.dart';
import '../../design/tokens.dart';
import '../../design/widgets/kit.dart';
import '../../sandbox/util.dart' show passwordStrength;
import '../settings/legal_screen.dart';
import 'auth_common.dart';

class SignupScreen extends StatefulWidget {
  const SignupScreen({super.key});
  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _referral = TextEditingController();
  bool _terms = false;
  bool _busy = false;
  bool _showReferral = false;
  final _errors = <String, String>{};

  int get _strength => passwordStrength(_password.text);

  Future<void> _submit() async {
    setState(() {
      _errors.clear();
      if (_name.text.trim().split(RegExp(r'\s+')).length < 2) _errors['name'] = 'Enter your first and last name.';
      if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(_email.text.trim())) _errors['email'] = 'Enter a valid email address.';
      if (_password.text.length < 8) _errors['password'] = 'Use at least 8 characters with letters and numbers.';
      if (!_terms) _errors['terms'] = 'Please accept the Terms and Privacy Policy to continue.';
    });
    if (_errors.isNotEmpty) return;
    setState(() => _busy = true);
    final app = context.app;
    try {
      final r = await app.api.call((s, _) => s.register(
            fullName: _name.text,
            email: _email.text,
            password: _password.text,
            acceptedTerms: _terms,
            deviceId: app.api.deviceId,
            deviceName: 'Knock app',
            referralCode: _referral.text.trim().isEmpty ? null : _referral.text,
          ));
      await app.signedIn(r['token'] as String, r['user'] as Json);
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    } on ApiError catch (e) {
      setState(() {
        switch (e.code) {
          case 'invalid_name':
            _errors['name'] = e.message;
          case 'invalid_email' || 'email_taken':
            _errors['email'] = e.message;
          case 'weak_password':
            _errors['password'] = e.message;
          case 'terms':
            _errors['terms'] = e.message;
          case 'invalid_referral':
            _errors['referral'] = e.message;
          default:
            showApiError(context, e);
        }
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      title: 'Create your account',
      subtitle: 'It takes about two minutes.',
      step: (1, 4),
      bottom: KnockButton(key: const ValueKey('signup-submit'), label: 'Create Account', loading: _busy, onPressed: _submit),
      children: [
        AutofillGroup(
          child: Column(
            children: [
              KField(key: const ValueKey('signup-name'), label: 'Full name', controller: _name, hint: 'Ada Okafor', error: _errors['name'], autofill: const [AutofillHints.name], capitalization: TextCapitalization.words, textInputAction: TextInputAction.next),
              KField(key: const ValueKey('signup-email'), label: 'Email', controller: _email, hint: 'you@example.com', keyboard: TextInputType.emailAddress, error: _errors['email'], autofill: const [AutofillHints.email], textInputAction: TextInputAction.next),
              KField(
                key: const ValueKey('signup-password'),
                label: 'Password',
                controller: _password,
                password: true,
                error: _errors['password'],
                autofill: const [AutofillHints.newPassword],
                onChanged: (_) => setState(() {}),
                helper: 'At least 8 characters, with letters and numbers.',
              ),
            ],
          ),
        ),
        if (_password.text.isNotEmpty) Padding(padding: const EdgeInsets.only(bottom: 14), child: PasswordMeter(_strength)),
        if (_showReferral)
          KField(label: 'Referral code (optional)', controller: _referral, error: _errors['referral'], capitalization: TextCapitalization.characters)
        else
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(onPressed: () => setState(() => _showReferral = true), child: Text('Have a referral code?', style: KnockText.bodyStrong.copyWith(color: KnockColors.greenBright))),
          ),
        const SizedBox(height: 8),
        InkWell(
          key: const ValueKey('signup-terms'),
          onTap: () => setState(() => _terms = !_terms),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Checkbox(value: _terms, onChanged: (v) => setState(() => _terms = v ?? false), activeColor: KnockColors.green),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Wrap(
                    children: [
                      Text('I agree to the ', style: KnockText.caption.copyWith(color: KnockColors.textPrimary)),
                      GestureDetector(onTap: () => go(context, const LegalScreen(kind: LegalKind.terms)), child: Text('Terms of Use', style: KnockText.caption.copyWith(color: KnockColors.greenBright, fontWeight: FontWeight.w600))),
                      Text(' and ', style: KnockText.caption.copyWith(color: KnockColors.textPrimary)),
                      GestureDetector(onTap: () => go(context, const LegalScreen(kind: LegalKind.privacy)), child: Text('Privacy Policy', style: KnockText.caption.copyWith(color: KnockColors.greenBright, fontWeight: FontWeight.w600))),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        if (_errors['terms'] != null) Padding(padding: const EdgeInsets.only(left: 12), child: Text(_errors['terms']!, style: KnockText.caption.copyWith(color: KnockColors.loss))),
      ],
    );
  }
}
