import 'package:image_picker/image_picker.dart';
import 'package:local_auth/local_auth.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/api.dart';
import '../../sandbox/util.dart' show passwordStrength;
import '../../app/app_controller.dart';
import '../../core/format.dart';
import '../../design/tokens.dart';
import '../../design/widgets/kit.dart';
import '../auth/auth_common.dart';
import '../common/pin_sheet.dart';
import '../onboarding/guide.dart';
import '../shell/nav.dart';
import 'delete_account_screen.dart';
import 'legal_screen.dart';
import 'sandbox_tools_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.appWatch;
    final me = app.me ?? {};
    return KPage(title: 'Settings', children: [
      KnockCard(
        onTap: () => go(context, const ProfileScreen()),
        child: Row(children: [
          Avatar(name: me['fullName'] as String? ?? 'You'),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(me['fullName'] as String? ?? '', style: KnockText.bodyStrong),
            Text('@${me['username'] ?? ''} · Tier ${me['tier']} · ${(me['vip'] as String? ?? 'silver').toUpperCase()}', style: KnockText.caption),
          ])),
          const Icon(Icons.chevron_right_rounded, color: KnockColors.textTertiary),
        ]),
      ),
      const SectionTitle('Account'),
      ListRow(key: const ValueKey('set-profile'), icon: Icons.person_outline_rounded, title: 'Personal information', subtitle: 'Name, username, photo, email and phone', onTap: () => go(context, const ProfileScreen())),
      ListRow(icon: Icons.verified_user_outlined, title: 'Verification', subtitle: 'Tier ${me['tier']} · limits and upgrades', onTap: () => Nav.verification(context)),
      ListRow(key: const ValueKey('set-delete'), icon: Icons.delete_outline_rounded, title: 'Delete account', danger: true, onTap: () => go(context, const DeleteAccountScreen())),
      const SectionTitle('Security'),
      ListRow(key: const ValueKey('set-security'), icon: Icons.lock_outline_rounded, title: 'Password, PIN and 2FA', onTap: () => go(context, const SecurityScreen())),
      ListRow(icon: Icons.devices_rounded, title: 'Devices and sessions', onTap: () => Nav.devices(context)),
      const SectionTitle('Preferences'),
      ListRow(key: const ValueKey('set-notifs'), icon: Icons.notifications_none_rounded, title: 'Notifications', onTap: () => go(context, const NotificationPrefsScreen())),
      ListRow(icon: Icons.visibility_off_outlined, title: 'Privacy', onTap: () => go(context, const PrivacyScreen())),
      ListRow(key: const ValueKey('set-prefs'), icon: Icons.language_rounded, title: 'Language and currency', subtitle: 'English · ${me['currency']}', onTap: () => go(context, const PreferencesScreen())),
      SwitchListTile(
        key: const ValueKey('set-guide'),
        contentPadding: EdgeInsets.zero,
        secondary: const Icon(Icons.tips_and_updates_outlined),
        title: Text('Show the guide', style: KnockText.body),
        subtitle: Text('Tips and the walkthrough for new features', style: KnockText.caption),
        value: me['guideEnabled'] != false,
        onChanged: (v) => updateSettings(context, guideEnabled: v),
      ),
      ListRow(icon: Icons.replay_rounded, title: 'Replay the welcome guide', onTap: () => go(context, GuideScreen(onDone: () => Navigator.of(context).pop()))),
      const SectionTitle('Help and legal'),
      ListRow(icon: Icons.support_agent_rounded, title: 'Contact support', onTap: () => Nav.support(context)),
      ListRow(icon: Icons.quiz_outlined, title: 'FAQ', onTap: () => Nav.faq(context)),
      ListRow(icon: Icons.description_outlined, title: 'Terms and conditions', onTap: () => go(context, const LegalScreen(kind: LegalKind.terms))),
      ListRow(icon: Icons.privacy_tip_outlined, title: 'Privacy policy', onTap: () => go(context, const LegalScreen(kind: LegalKind.privacy))),
      ListRow(icon: Icons.photo_outlined, title: 'Credits', onTap: () => go(context, const LegalScreen(kind: LegalKind.credits))),
      if (devToolsEnabled) const SectionTitle('Developer'),
      if (devToolsEnabled)
        ListRow(key: const ValueKey('set-sandbox'), icon: Icons.science_outlined, iconColor: KnockColors.orange, title: 'Developer tools', subtitle: 'Debug builds only', onTap: () => go(context, const SandboxToolsScreen())),
      const SizedBox(height: 20),
      KnockButton(
        key: const ValueKey('set-logout'),
        label: 'Log out',
        style: KnockButtonStyle.secondary,
        icon: Icons.logout_rounded,
        onPressed: () async {
          if (await confirm(context, title: 'Log out?', message: 'You will need your password to log back in.', yes: 'Log out') && context.mounted) {
            await context.app.logout();
          }
        },
      ),
      const SizedBox(height: 12),
      Center(child: Text('Knock prototype · sandbox build', style: KnockText.micro)),
    ]);
  }
}

Future<bool> updateSettings(BuildContext context, {Json? prefs, Json? privacy, bool? guideEnabled, bool? biometrics, bool? marketingConsent, String? currency}) async {
  try {
    final r = await context.api.call((s, t) => s.updateSettings(t!, prefs: prefs, privacy: privacy, guideEnabled: guideEnabled, biometrics: biometrics, marketingConsent: marketingConsent, currency: currency));
    if (context.mounted) context.app.updateMe(r['user'] as Json);
    return true;
  } catch (e) {
    if (context.mounted) showApiError(context, e);
    return false;
  }
}

Future<String?> askPassword(BuildContext context, {String title = 'Confirm your password', String? message}) {
  final c = TextEditingController();
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (s) => Padding(
      padding: EdgeInsets.fromLTRB(24, 0, 24, 24 + MediaQuery.viewInsetsOf(s).bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: KnockText.title),
        if (message != null) ...[const SizedBox(height: 6), Text(message, style: KnockText.caption)],
        const SizedBox(height: 16),
        KField(key: const ValueKey('reauth-password'), label: 'Password', controller: c, password: true, autofocus: true),
        KnockButton(key: const ValueKey('reauth-submit'), label: 'Continue', onPressed: () => Navigator.pop(s, c.text)),
      ]),
    ),
  );
}

// ---- Profile -----------------------------------------------------------------

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});
  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late final _me = context.app.me ?? {};
  late final _name = TextEditingController(text: _me['fullName'] as String? ?? '');
  late final _username = TextEditingController(text: _me['username'] as String? ?? '');
  bool _busy = false;

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      final r = await context.api.call((s, t) => s.updateProfile(t!, fullName: _name.text == _me['fullName'] ? null : _name.text, username: _username.text == _me['username'] ? null : _username.text));
      if (!mounted) return;
      context.app.updateMe(r['user'] as Json);
      toast(context, 'Profile saved');
    } catch (e) {
      if (mounted) showApiError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _photo() async {
    String? name;
    try {
      final x = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 512, imageQuality: 80);
      name = x?.name;
    } catch (_) {
      name = 'sandbox-avatar.jpg';
    }
    if (name == null || !mounted) return;
    try {
      final r = await context.api.call((s, t) => s.updateProfile(t!, avatar: name));
      if (mounted) {
        context.app.updateMe(r['user'] as Json);
        toast(context, 'Photo updated');
      }
    } catch (e) {
      if (mounted) showApiError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = context.appWatch.me ?? {};
    final locked = (me['tier'] as int? ?? 0) >= 2;
    return KPage(title: 'Personal information', bottom: KnockButton(key: const ValueKey('profile-save'), label: 'Save changes', loading: _busy, onPressed: _busy ? null : _save), children: [
      Center(
        child: Column(children: [
          Avatar(name: me['fullName'] as String? ?? ''),
          TextButton.icon(key: const ValueKey('profile-photo'), onPressed: _photo, icon: const Icon(Icons.photo_camera_outlined), label: Text(me['avatar'] == null ? 'Add photo' : 'Change photo')),
        ]),
      ),
      KField(label: 'Full name', controller: _name, enabled: !locked, helper: locked ? 'Locked to your verified identity. Contact support to change it.' : null),
      KField(key: const ValueKey('profile-username'), label: 'Username', controller: _username, prefix: const Text('@ '), helper: 'Friends can send you gifts with this.'),
      const SectionTitle('Contact'),
      ListRow(icon: Icons.mail_outline_rounded, title: me['email'] as String? ?? '', subtitle: 'Email · verified', trailing: const Text('Change'), onTap: () => go(context, const ChangeEmailScreen())),
      ListRow(icon: Icons.phone_iphone_rounded, title: me['phone'] as String? ?? 'Not added', subtitle: 'Phone${me['phoneVerified'] == true ? ' · verified' : ''}', trailing: const Text('Change'), onTap: () => go(context, const ChangePhoneScreen())),
      const SizedBox(height: 8),
      KeyValue('Member since', F.date(me['createdAt'] as String? ?? DateTime.now().toIso8601String())),
      KeyValue('Referral code', me['referralCode'] as String? ?? ''),
    ]);
  }
}

class ChangeEmailScreen extends StatefulWidget {
  const ChangeEmailScreen({super.key});
  @override
  State<ChangeEmailScreen> createState() => _ChangeEmailScreenState();
}

class _ChangeEmailScreenState extends State<ChangeEmailScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _code = TextEditingController();
  String? _sentTo;
  bool _busy = false;

  Future<void> _start() async {
    setState(() => _busy = true);
    try {
      final r = await context.api.call((s, t) => s.startEmailChange(t!, _password.text, _email.text));
      if (mounted) setState(() => _sentTo = r['email'] as String);
    } catch (e) {
      if (mounted) showApiError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirm(String code) async {
    try {
      final r = await context.api.call((s, t) => s.confirmEmailChange(t!, code));
      if (!mounted) return;
      context.app.updateMe(r['user'] as Json);
      toast(context, 'Email changed. Withdrawals are paused for 24 hours as a precaution.');
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) showApiError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_sentTo != null) {
      return KPage(title: 'Check your email', subtitle: 'We sent a 6-digit code to $_sentTo.', children: [
        CodeInput(controller: _code, onCompleted: _confirm),
        const SizedBox(height: 12),
        SandboxCodeHint(email: _sentTo, onUse: (c) {
          _code.text = c;
          _confirm(c);
        }),
      ]);
    }
    return KPage(title: 'Change email', bottom: KnockButton(label: 'Send code', loading: _busy, onPressed: _busy ? null : _start), children: [
      KField(label: 'New email', controller: _email, keyboard: TextInputType.emailAddress),
      KField(label: 'Current password', controller: _password, password: true),
      const Note('For your safety, withdrawals pause for 24 hours after you change your email. We also tell your old address.', icon: Icons.shield_outlined),
    ]);
  }
}

class ChangePhoneScreen extends StatefulWidget {
  const ChangePhoneScreen({super.key});
  @override
  State<ChangePhoneScreen> createState() => _ChangePhoneScreenState();
}

class _ChangePhoneScreenState extends State<ChangePhoneScreen> {
  final _phone = TextEditingController();
  final _code = TextEditingController();
  String? _sentTo;

  Future<void> _start() async {
    try {
      final r = await context.api.call((s, t) => s.startPhoneVerification(t!, 'NG', _phone.text));
      if (mounted) setState(() => _sentTo = r['phone'] as String);
    } catch (e) {
      if (mounted) showApiError(context, e);
    }
  }

  Future<void> _confirm(String code) async {
    try {
      final r = await context.api.call((s, t) => s.verifyPhone(t!, code));
      if (!mounted) return;
      context.app.updateMe(r['user'] as Json);
      toast(context, 'Phone number updated');
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) showApiError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_sentTo != null) {
      return KPage(title: 'Enter the code', subtitle: 'We sent a code by SMS to $_sentTo.', children: [
        CodeInput(controller: _code, onCompleted: _confirm),
        const SizedBox(height: 12),
        SandboxCodeHint(onUse: (c) {
          _code.text = c;
          _confirm(c);
        }),
      ]);
    }
    return KPage(title: 'Change phone', bottom: KnockButton(label: 'Send code', onPressed: _start), children: [
      KField(label: 'New mobile number', controller: _phone, keyboard: TextInputType.phone, prefix: const Text('+234 ')),
    ]);
  }
}

// ---- Security ------------------------------------------------------------------

class SecurityScreen extends StatelessWidget {
  const SecurityScreen({super.key});

  Future<void> _twoFactor(BuildContext context, bool v) async {
    final pw = await askPassword(context, message: v ? 'We will ask for an email code each time you log in.' : 'Two-step verification protects your account if your password leaks.');
    if (pw == null || !context.mounted) return;
    try {
      final r = await context.api.call((s, t) => s.setTwoFactor(t!, v, pw));
      if (context.mounted) context.app.updateMe(r['user'] as Json);
    } catch (e) {
      if (context.mounted) showApiError(context, e);
    }
  }

  Future<void> _biometrics(BuildContext context, bool v) async {
    if (v) {
      try {
        final auth = LocalAuthentication();
        final can = await auth.isDeviceSupported();
        if (!can) {
          if (context.mounted) toast(context, 'This device does not support biometrics.', error: true);
          return;
        }
        final ok = await auth.authenticate(localizedReason: 'Turn on biometric unlock for Knock');
        if (!ok) return;
      } catch (_) {
        if (context.mounted) toast(context, 'Biometrics are not available here. Turned on for testing.', error: false);
      }
    }
    if (context.mounted) await updateSettings(context, biometrics: v);
  }

  @override
  Widget build(BuildContext context) {
    final me = context.appWatch.me ?? {};
    return KPage(title: 'Security', children: [
      ListRow(key: const ValueKey('sec-password'), icon: Icons.password_rounded, title: 'Change password', subtitle: 'Signs out your other devices', onTap: () => go(context, const ChangePasswordScreen())),
      ListRow(
        key: const ValueKey('sec-pin'),
        icon: Icons.pin_outlined,
        title: me['hasPin'] == true ? 'Change transaction PIN' : 'Create transaction PIN',
        subtitle: 'Needed for every payment and to reveal codes',
        onTap: () async {
          final r = await createPin(context, change: me['hasPin'] == true);
          if (r != null && context.mounted) {
            await context.app.refreshMe();
            if (context.mounted) toast(context, 'PIN saved');
          }
        },
      ),
      SwitchListTile(
        key: const ValueKey('sec-2fa'),
        contentPadding: EdgeInsets.zero,
        secondary: const Icon(Icons.verified_user_outlined),
        title: Text('Two-step verification', style: KnockText.body),
        subtitle: Text('Email code at login', style: KnockText.caption),
        value: me['twoFactor'] == true,
        onChanged: (v) => _twoFactor(context, v),
      ),
      SwitchListTile(
        key: const ValueKey('sec-bio'),
        contentPadding: EdgeInsets.zero,
        secondary: const Icon(Icons.fingerprint_rounded),
        title: Text('Biometric unlock', style: KnockText.body),
        subtitle: Text('Unlock the app with Face ID or fingerprint. Payments still need your PIN.', style: KnockText.caption),
        value: me['biometrics'] == true,
        onChanged: (v) => _biometrics(context, v),
      ),
      ListRow(icon: Icons.devices_rounded, title: 'Devices and sessions', onTap: () => Nav.devices(context)),
      const SizedBox(height: 12),
      const Note('Knock will never ask for your password, PIN or gift card codes by phone, email or WhatsApp.', icon: Icons.shield_outlined),
    ]);
  }
}

class ChangePasswordScreen extends StatefulWidget {
  const ChangePasswordScreen({super.key});
  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> {
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _again = TextEditingController();
  String? _error;
  bool _busy = false;

  Future<void> _save() async {
    if (_next.text != _again.text) {
      setState(() => _error = 'The passwords do not match.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.api.call((s, t) => s.changePassword(t!, _current.text, _next.text));
      if (!mounted) return;
      toast(context, 'Password changed. Other devices were signed out.');
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) showApiError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return KPage(title: 'Change password', bottom: KnockButton(label: 'Save password', loading: _busy, onPressed: _busy ? null : _save), children: [
      KField(label: 'Current password', controller: _current, password: true),
      KField(label: 'New password', controller: _next, password: true, onChanged: (_) => setState(() {})),
      if (_next.text.isNotEmpty) PasswordMeter(passwordStrength(_next.text)),
      const SizedBox(height: 12),
      KField(label: 'Repeat new password', controller: _again, password: true, error: _error),
    ]);
  }
}

class DevicesScreen extends StatelessWidget {
  const DevicesScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return ApiView(
      load: (api) => api.call((s, t) => s.sessions(t!)),
      builder: (context, d, reload) {
        final list = (d['sessions'] as List).cast<Json>();
        return KPage(title: 'Devices and sessions', onRefresh: reload, children: [
          for (final s in list)
            ListRow(
              icon: Icons.phone_android_rounded,
              title: '${s['deviceName']}${s['current'] == true ? ' (this device)' : ''}',
              subtitle: 'Signed in ${F.date(s['createdAt'] as String)} · active ${F.ago(s['lastSeenAt'] as String? ?? s['createdAt'] as String)}',
              trailing: s['current'] == true
                  ? null
                  : TextButton(
                      onPressed: () async {
                        if (!await confirm(context, title: 'Sign out this device?', message: 'It will need the password to sign in again.', yes: 'Sign out', danger: true)) return;
                        if (!context.mounted) return;
                        try {
                          await context.api.call((x, t) => x.revokeSession(t!, s['id'] as String));
                          await reload();
                        } catch (e) {
                          if (context.mounted) showApiError(context, e);
                        }
                      },
                      child: const Text('Sign out'),
                    ),
            ),
          const SizedBox(height: 12),
          const Note('If you do not recognise a device, sign it out and change your password.', icon: Icons.shield_outlined),
        ]);
      },
    );
  }
}

// ---- Notifications, privacy, preferences -------------------------------------------

class NotificationPrefsScreen extends StatelessWidget {
  const NotificationPrefsScreen({super.key});

  static const _items = [
    ('transaction', 'Transactions', 'Trades, payments and receipts. Always on.', true),
    ('security', 'Security', 'Logins, password and device changes. Always on.', true),
    ('referral', 'Referrals', 'When friends join and qualify', false),
    ('reward', 'Rewards', 'Bonuses, points and badges', false),
    ('rate_alert', 'Rate alerts', 'When a watched rate hits your target', false),
    ('reminder', 'Reminders', 'Unfinished trades and drafts', false),
    ('campaign', 'Promotions', 'Fire Load and offers. Needs marketing consent.', false),
  ];

  @override
  Widget build(BuildContext context) {
    final me = context.appWatch.me ?? {};
    final prefs = (me['prefs'] as Map?) ?? {};
    return KPage(title: 'Notifications', children: [
      for (final (k, title, sub, locked) in _items)
        SwitchListTile(
          key: ValueKey('pref-$k'),
          contentPadding: EdgeInsets.zero,
          title: Text(title, style: KnockText.body),
          subtitle: Text(sub, style: KnockText.caption),
          value: locked || prefs[k] != false,
          onChanged: locked ? null : (v) => updateSettings(context, prefs: {k: v}),
        ),
      const SectionTitle('Channels'),
      SwitchListTile(contentPadding: EdgeInsets.zero, title: Text('Push notifications', style: KnockText.body), value: prefs['push'] != false, onChanged: (v) => updateSettings(context, prefs: {'push': v})),
      SwitchListTile(contentPadding: EdgeInsets.zero, title: Text('Email', style: KnockText.body), value: prefs['email'] != false, onChanged: (v) => updateSettings(context, prefs: {'email': v})),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text('"Hey Chief!" voice', style: KnockText.body),
        subtitle: Text('A friendly greeting on rate updates', style: KnockText.caption),
        value: prefs['heyChief'] != false,
        onChanged: (v) => updateSettings(context, prefs: {'heyChief': v}),
      ),
      const SectionTitle('Marketing'),
      SwitchListTile(
        key: const ValueKey('pref-marketing'),
        contentPadding: EdgeInsets.zero,
        title: Text('Marketing consent', style: KnockText.body),
        subtitle: Text('Allow Knock to send you offers. You can withdraw consent any time.', style: KnockText.caption),
        value: me['marketingConsent'] == true,
        onChanged: (v) => updateSettings(context, marketingConsent: v),
      ),
    ]);
  }
}

class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final me = context.appWatch.me ?? {};
    final p = (me['privacy'] as Map?) ?? {};
    return KPage(title: 'Privacy', children: [
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text('Let people find me by phone or email', style: KnockText.body),
        subtitle: Text('For receiving gifts', style: KnockText.caption),
        value: p['discoverable'] != false,
        onChanged: (v) => updateSettings(context, privacy: {'discoverable': v}),
      ),
      const SizedBox(height: 12),
      ListRow(icon: Icons.privacy_tip_outlined, title: 'Read our privacy policy', onTap: () => go(context, const LegalScreen(kind: LegalKind.privacy))),
    ]);
  }
}

class PreferencesScreen extends StatelessWidget {
  const PreferencesScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final me = context.appWatch.me ?? {};
    return KPage(title: 'Language and currency', children: [
      const SectionTitle('Language', top: 0),
      ChoiceWrap<String>(choices: const [Choice('en', 'English (UK)')], selected: 'en', onSelected: (_) {}),
      const SizedBox(height: 6),
      Text('More languages, including Pidgin, Yoruba, Hausa and Igbo, are planned.', style: KnockText.caption),
      const SectionTitle('Display currency'),
      ChoiceWrap<String>(
        key: const ValueKey('pref-currency'),
        choices: [for (final c in displayCurrencies) Choice(c.code, '${c.symbol} ${c.code}')],
        selected: me['currency'] as String? ?? 'NGN',
        onSelected: (c) => updateSettings(context, currency: c),
      ),
      const SizedBox(height: 8),
      const Note('Your wallet is always held in Naira. Other currencies are shown as estimates.'),
    ]);
  }
}
