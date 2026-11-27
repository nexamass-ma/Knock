import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/api.dart';
import '../../app/app_controller.dart';
import '../../design/tokens.dart';
import '../../design/widgets/kit.dart';
import '../auth/auth_common.dart';

/// Shows the sign-up step the backend says the account is on.
class OnboardingFlow extends StatelessWidget {
  const OnboardingFlow({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.appWatch;
    final step = app.me?['onboarding'] as String? ?? 'verify_email';
    final Widget page = switch (step) {
      'verify_email' => const VerifyEmailScreen(),
      'phone' => const PhoneScreen(),
      _ => const PersonaliseScreen(),
    };
    return AnimatedSwitcher(
      duration: KnockMotion.slow,
      switchInCurve: KnockMotion.curve,
      transitionBuilder: (c, a) => FadeTransition(opacity: a, child: SlideTransition(position: Tween(begin: const Offset(0.05, 0), end: Offset.zero).animate(a), child: c)),
      child: KeyedSubtree(key: ValueKey(step), child: page),
    );
  }
}

Future<void> _logoutConfirm(BuildContext context) async {
  if (await confirm(context, title: 'Leave sign-up?', message: 'You can log in later with your email and password to finish.', yes: 'Log out')) {
    if (context.mounted) await context.app.logout();
  }
}

class VerifyEmailScreen extends StatefulWidget {
  const VerifyEmailScreen({super.key});
  @override
  State<VerifyEmailScreen> createState() => _VerifyEmailScreenState();
}

class _VerifyEmailScreenState extends State<VerifyEmailScreen> {
  final _code = TextEditingController();
  String? _error;
  bool _busy = false;

  Future<void> _verify(String code) async {
    if (_busy || code.length != 6) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final app = context.app;
    try {
      final r = await app.api.call((s, t) => s.verifyEmail(t!, code));
      HapticFeedback.mediumImpact();
      app.onboardingDone(r['user'] as Json);
    } on ApiError catch (e) {
      setState(() => _error = e.message);
      _code.clear();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _changeEmail() async {
    final c = TextEditingController(text: context.app.me?['email'] as String?);
    final next = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (s) => Padding(
        padding: EdgeInsets.fromLTRB(24, 0, 24, 24 + MediaQuery.viewInsetsOf(s).bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Change email', style: KnockText.title),
          const SizedBox(height: 16),
          KField(label: 'Email', controller: c, keyboard: TextInputType.emailAddress, autofocus: true),
          KnockButton(label: 'Send new code', onPressed: () => Navigator.pop(s, c.text)),
        ]),
      ),
    );
    if (next == null || !mounted) return;
    final app = context.app;
    try {
      final r = await app.api.call((s, t) => s.changeUnverifiedEmail(t!, next));
      app.updateMe(r['user'] as Json);
      if (mounted) toast(context, 'We sent a new code to ${r['user']['email']}');
    } catch (e) {
      if (mounted) showApiError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final email = context.appWatch.me?['email'] as String? ?? '';
    return AuthScaffold(
      title: 'Check your email',
      subtitle: 'Enter the 6-digit code we sent to $email.',
      step: (2, 4),
      onBack: () => _logoutConfirm(context),
      bottom: KnockButton(key: const ValueKey('verify-email-submit'), label: 'Verify email', loading: _busy, onPressed: () => _verify(_code.text)),
      children: [
        CodeInput(controller: _code, onCompleted: _verify, error: _error),
        const SizedBox(height: 12),
        Row(children: [
          ResendButton(onResend: () async {
            try {
              await context.api.call((s, t) => s.resendCode(t!, 'verify_email'));
              return true;
            } catch (e) {
              if (mounted) showApiError(context, e);
              return false;
            }
          }),
          const Spacer(),
          TextButton(onPressed: _changeEmail, child: Text('Change email', style: KnockText.bodyStrong.copyWith(color: KnockColors.textSecondary))),
        ]),
        SandboxCodeHint(onUse: (c) => _code.text = c),
      ],
    );
  }
}

class PhoneScreen extends StatefulWidget {
  const PhoneScreen({super.key});
  @override
  State<PhoneScreen> createState() => _PhoneScreenState();
}

class _PhoneScreenState extends State<PhoneScreen> {
  final _number = TextEditingController();
  final _code = TextEditingController();
  String _country = 'NG';
  String? _sentTo;
  String? _error;
  bool _busy = false;

  Future<void> _send() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await context.api.call((s, t) => s.startPhoneVerification(t!, _country, _number.text));
      setState(() => _sentTo = r['phone'] as String);
    } on ApiError catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verify(String code) async {
    if (_busy || code.length != 6) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final app = context.app;
    try {
      final r = await app.api.call((s, t) => s.verifyPhone(t!, code));
      HapticFeedback.mediumImpact();
      app.onboardingDone(r['user'] as Json);
    } on ApiError catch (e) {
      setState(() => _error = e.message);
      _code.clear();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = countryByCode(_country);
    if (_sentTo != null) {
      return AuthScaffold(
        title: 'Verify your phone',
        subtitle: 'Enter the code we sent by SMS to $_sentTo.',
        step: (3, 4),
        onBack: () => setState(() {
          _sentTo = null;
          _code.clear();
        }),
        bottom: KnockButton(key: const ValueKey('verify-phone-submit'), label: 'Verify phone', loading: _busy, onPressed: () => _verify(_code.text)),
        children: [
          CodeInput(controller: _code, onCompleted: _verify, error: _error),
          const SizedBox(height: 12),
          Row(children: [
            ResendButton(onResend: () async {
              try {
                await context.api.call((s, t) => s.resendCode(t!, 'verify_phone'));
                return true;
              } catch (e) {
                if (mounted) showApiError(context, e);
                return false;
              }
            }),
            const Spacer(),
            TextButton(onPressed: () => setState(() => _sentTo = null), child: Text('Change number', style: KnockText.bodyStrong.copyWith(color: KnockColors.textSecondary))),
          ]),
          SandboxCodeHint(onUse: (v) => _code.text = v),
        ],
      );
    }
    return AuthScaffold(
      title: 'Add your phone number',
      subtitle: 'We use it to protect your account and send trade updates. It completes Tier 1 verification.',
      step: (3, 4),
      onBack: () => _logoutConfirm(context),
      bottom: KnockButton(key: const ValueKey('phone-send'), label: 'Send code', loading: _busy, onPressed: _send),
      children: [
        Text('Mobile number', style: KnockText.caption.copyWith(color: KnockColors.textPrimary, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Material(
              color: KnockColors.surfaceRaised,
              borderRadius: BorderRadius.circular(KnockRadius.md),
              child: InkWell(
                borderRadius: BorderRadius.circular(KnockRadius.md),
                onTap: () async {
                  final picked = await showModalBottomSheet<String>(
                    context: context,
                    builder: (s) => ListView(shrinkWrap: true, children: [
                      for (final x in countries)
                        ListTile(leading: Text(x.flag, style: const TextStyle(fontSize: 22)), title: Text(x.name, style: KnockText.body), trailing: Text(x.dial, style: KnockText.caption), onTap: () => Navigator.pop(s, x.code)),
                    ]),
                  );
                  if (picked != null) setState(() => _country = picked);
                },
                child: Padding(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 15), child: Text('${c.flag} ${c.dial}', style: KnockText.body)),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                key: const ValueKey('phone-number'),
                controller: _number,
                keyboardType: TextInputType.phone,
                autofillHints: const [AutofillHints.telephoneNumberNational],
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d ]'))],
                style: KnockText.body,
                decoration: InputDecoration(hintText: '801 234 5678', errorText: _error, errorMaxLines: 3),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class PersonaliseScreen extends StatefulWidget {
  const PersonaliseScreen({super.key});
  @override
  State<PersonaliseScreen> createState() => _PersonaliseScreenState();
}

class _PersonaliseScreenState extends State<PersonaliseScreen> {
  String _country = 'NG';
  String _currency = 'NGN';
  bool _marketing = false;
  bool _busy = false;

  Future<void> _finish() async {
    setState(() => _busy = true);
    final app = context.app;
    try {
      final r = await app.api.call((s, t) => s.personalise(t!, country: _country, currency: _currency, marketingConsent: _marketing));
      app.onboardingDone(r['user'] as Json);
    } catch (e) {
      if (mounted) showApiError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      title: 'Make Knock yours',
      subtitle: 'Choose where you are and how you would like to see your balance. You can change this any time in Settings.',
      step: (4, 4),
      bottom: KnockButton(key: const ValueKey('personalise-finish'), label: 'Go to my dashboard', loading: _busy, onPressed: _finish),
      children: [
        Text('Country', style: KnockText.headline),
        const SizedBox(height: 10),
        ChoiceWrap<String>(
          choices: [for (final c in countries) Choice(c.code, '${c.flag}  ${c.name}')],
          selected: _country,
          onSelected: (v) => setState(() {
            _country = v;
            _currency = countryByCode(v).currency;
            if (!displayCurrencies.any((c) => c.code == _currency)) _currency = 'NGN';
          }),
        ),
        const SizedBox(height: 24),
        Text('Display currency', style: KnockText.headline),
        const SizedBox(height: 4),
        Text('Your wallet settles in naira. We show an estimate in the currency you pick.', style: KnockText.caption),
        const SizedBox(height: 10),
        ChoiceWrap<String>(
          choices: [for (final c in displayCurrencies) Choice(c.code, '${c.symbol}  ${c.code}')],
          selected: _currency,
          onSelected: (v) => setState(() => _currency = v),
        ),
        const SizedBox(height: 24),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _marketing,
          onChanged: (v) => setState(() => _marketing = v),
          title: Text('Send me offers and rate tips', style: KnockText.bodyStrong),
          subtitle: Text('Optional. Turn it off any time in Settings.', style: KnockText.caption),
        ),
      ],
    );
  }
}
