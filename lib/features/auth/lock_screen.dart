import 'package:material_ui/material_ui.dart';

import '../../app/app_scope.dart';
import '../../design/tokens.dart';
import '../../design/widgets/pin_pad.dart';
import '../../design/widgets/surfaces.dart';
import 'wordmark.dart';

/// App unlock. Biometrics first, KNOCK PIN as fallback. In production the
/// unlock exchanges a device-bound credential for a fresh session token.
class LockScreen extends StatefulWidget {
  const LockScreen({super.key});

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  String? _error;
  bool _busy = false;
  bool _bioAvailable = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final app = context.app;
      final ok = await app.services.biometrics.isAvailable();
      if (!mounted) return;
      setState(() => _bioAvailable = ok && app.session.biometricsEnabled);
      if (_bioAvailable) _biometric();
    });
  }

  Future<void> _biometric() async {
    final app = context.app;
    final ok = await app.services.biometrics.verify('Unlock KNOCK');
    if (ok && mounted) await app.session.unlock();
  }

  Future<void> _pin(String pin) async {
    final app = context.app;
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = await app.services.pin.verify(pin);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = ok ? null : 'Incorrect PIN. Try again.';
    });
    if (ok) await app.session.unlock();
  }

  @override
  Widget build(BuildContext context) {
    final session = context.app.session;
    return Scaffold(
      body: Stack(
        children: [
          const Positioned(top: -160, left: -120, right: -120, height: 420, child: _Glow()),
          SafeArea(
            child: LayoutBuilder(
              builder: (context, c) => SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: c.maxHeight),
                  child: IntrinsicHeight(
                    child: Column(
                      children: [
                        const SizedBox(height: 56),
                        const KnockWordmark(size: 30),
                        const SizedBox(height: 28),
                        Text('Welcome back, ${session.firstName}', style: KnockText.title),
                        const SizedBox(height: 6),
                        Text('Enter your KNOCK PIN', style: KnockText.caption),
                        const SizedBox(height: 4),
                        Text(
                          'Prototype: any 4 digits except 0000',
                          style: KnockText.micro.copyWith(color: KnockColors.orange),
                        ),
                        const Spacer(),
                        PinPad(
                          onComplete: _pin,
                          error: _error,
                          busy: _busy,
                          onBiometric: _bioAvailable ? _biometric : null,
                        ),
                        const SizedBox(height: 12),
                        const MockBadge(label: 'PROTOTYPE · MOCK SERVICES'),
                        const SizedBox(height: 24),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Glow extends StatelessWidget {
  const _Glow();
  @override
  Widget build(BuildContext context) => const DecoratedBox(
    decoration: BoxDecoration(
      gradient: RadialGradient(
        colors: [Color(0x5500B03C), Color(0x224A3D6E), Color(0x000A0A0E)],
        stops: [0.0, 0.45, 1.0],
      ),
    ),
  );
}
