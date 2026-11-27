import 'package:local_auth/local_auth.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/api.dart';
import '../../app/app_controller.dart';
import '../../design/tokens.dart';
import '../../design/widgets/brand.dart';
import '../../design/widgets/pin_pad.dart';

/// Shown after the app has been in the background for more than two minutes.
class LockScreen extends StatefulWidget {
  const LockScreen({super.key});
  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (context.app.me?['biometrics'] == true) WidgetsBinding.instance.addPostFrameCallback((_) => _biometric());
  }

  Future<void> _biometric() async {
    try {
      final ok = await LocalAuthentication().authenticate(localizedReason: 'Unlock Knock');
      if (ok && mounted) context.app.unlocked();
    } catch (_) {
      // Biometrics unavailable: the PIN still works.
    }
  }

  Future<void> _check(String pin) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final app = context.app;
    try {
      await app.api.call((s, t) => s.checkPin(t!, pin));
      app.unlocked();
    } on ApiError catch (e) {
      if (e.code == 'unauthenticated' || e.code == 'session_expired') {
        await app.logout(message: e.message);
        return;
      }
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.appWatch;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(KnockSpace.gutter),
          child: Column(
            children: [
              const SizedBox(height: 24),
              const KnockMark(size: 56),
              const SizedBox(height: 20),
              Text('Welcome back, ${app.firstName}', style: KnockText.title, textAlign: TextAlign.center),
              const SizedBox(height: 6),
              Text('Enter your PIN to unlock', style: KnockText.caption),
              const Spacer(),
              PinPad(onComplete: _check, error: _error, busy: _busy, onBiometric: app.me?['biometrics'] == true ? _biometric : null),
              const SizedBox(height: 8),
              TextButton(onPressed: () => app.logout(), child: Text('Log out instead', style: KnockText.bodyStrong.copyWith(color: KnockColors.textSecondary))),
            ],
          ),
        ),
      ),
    );
  }
}
