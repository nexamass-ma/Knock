import 'package:material_ui/material_ui.dart';

import '../../app/app_scope.dart';
import '../../design/tokens.dart';
import '../../design/widgets/surfaces.dart';
import '../shell/shell.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final s = app.session;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) => Scaffold(
        body: SafeArea(
          bottom: false,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(KnockSpace.gutter, 12, KnockSpace.gutter, kNavClearance + 16),
            children: [
              const Text('Profile', style: KnockText.title),
              const SizedBox(height: KnockSpace.lg),
              KnockCard(
                child: Row(
                  children: [
                    const CircleAvatar(
                      radius: 28,
                      backgroundColor: KnockColors.greenSoft,
                      child: Text(
                        'AO',
                        style: TextStyle(color: KnockColors.green, fontWeight: FontWeight.w700, fontSize: 18),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(s.fullName, style: KnockText.headline),
                          const SizedBox(height: 2),
                          Text(s.phone, style: KnockText.caption),
                          const SizedBox(height: 8),
                          Tag('Verification tier ${s.kycTier}', color: KnockColors.green, icon: Icons.verified_rounded),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              _Section('Account', [
                _Row(
                  Icons.badge_outlined,
                  'Verification level',
                  value: 'Tier ${s.kycTier}',
                  onTap: () => _showTiers(context),
                ),
                const _Row(Icons.person_outline_rounded, 'Personal details'),
                const _Row(Icons.account_balance_outlined, 'Bank accounts', value: '1 saved'),
              ]),
              _Section('Security', [
                _Toggle(
                  Icons.fingerprint_rounded,
                  'Biometric unlock and approval',
                  s.biometricsEnabled,
                  s.setBiometrics,
                ),
                const _Row(Icons.pin_outlined, 'Change transaction PIN'),
                const _Row(Icons.devices_other_rounded, 'Trusted devices', value: '1 device'),
                const _Row(Icons.timer_outlined, 'Auto-lock', value: 'After 2 min'),
              ]),
              _Section('Preferences', [
                _Toggle(Icons.visibility_off_outlined, 'Hide balances', s.hideBalances, (_) => s.toggleHideBalances()),
                _Toggle(Icons.attach_money_rounded, 'Show portfolio in USD', s.showUsd, s.setShowUsd),
                const _Row(Icons.notifications_none_rounded, 'Notifications'),
                const _Row(Icons.help_outline_rounded, 'Help and support'),
              ]),
              if (app.services.isMock)
                _Section('Prototype controls', [
                  const _Row(Icons.science_outlined, 'Data source', value: 'Mock services'),
                  _Toggle(Icons.wifi_off_rounded, 'Simulate network errors', s.simulateErrors, (v) {
                    s.setSimulateErrors(v);
                    app.wallet.load();
                  }),
                  _Row(
                    Icons.restart_alt_rounded,
                    'Reset sample data',
                    onTap: () {
                      s.resetMockData();
                      app.assistant.clear();
                      app.wallet.load();
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Sample data reset')));
                    },
                  ),
                ]),
              const SizedBox(height: KnockSpace.xl),
              KnockButton(
                label: 'Lock KNOCK',
                icon: Icons.lock_outline_rounded,
                style: KnockButtonStyle.ghost,
                onPressed: s.signOut,
              ),
              const SizedBox(height: 16),
              Text(
                'KNOCK prototype · v0.1.0',
                style: KnockText.micro.copyWith(fontWeight: FontWeight.w400),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showTiers(BuildContext context) {
    const tiers = [
      ('Tier 1', 'Phone + BVN', '₦5,000,000 daily', true),
      ('Tier 2', 'Government ID + selfie', '₦20,000,000 daily', false),
      ('Tier 3', 'Proof of address', 'Custom limits', false),
    ];
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(KnockSpace.gutter, 0, KnockSpace.gutter, KnockSpace.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Verification levels', style: KnockText.title),
              const SizedBox(height: 4),
              Text('Limits are placeholders until compliance signs them off.', style: KnockText.caption),
              const SizedBox(height: KnockSpace.md),
              for (final (name, req, limit, current) in tiers)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: KnockCard(
                    color: current ? KnockColors.greenSoft : KnockColors.surfaceRaised,
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(name, style: KnockText.bodyStrong),
                              Text(req, style: KnockText.caption),
                            ],
                          ),
                        ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(limit, style: KnockText.caption.copyWith(color: KnockColors.textPrimary)),
                            if (current)
                              const Text('Current', style: TextStyle(color: KnockColors.green, fontSize: 12)),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title, this.children);
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, KnockSpace.xl, 4, 8),
          child: Text(title.toUpperCase(), style: KnockText.micro),
        ),
        KnockCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              for (var i = 0; i < children.length; i++) ...[
                children[i],
                if (i < children.length - 1) const Divider(indent: 52),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.icon, this.label, {this.value, this.onTap});
  final IconData icon;
  final String label;
  final String? value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap ?? () {},
      leading: Icon(icon, color: KnockColors.textSecondary, size: 22),
      title: Text(label, style: KnockText.body),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (value != null) Text(value!, style: KnockText.caption),
          const Icon(Icons.chevron_right_rounded, color: KnockColors.textTertiary),
        ],
      ),
    );
  }
}

class _Toggle extends StatelessWidget {
  const _Toggle(this.icon, this.label, this.value, this.onChanged);
  final IconData icon;
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      value: value,
      onChanged: onChanged,
      secondary: Icon(icon, color: KnockColors.textSecondary, size: 22),
      title: Text(label, style: KnockText.body),
    );
  }
}
