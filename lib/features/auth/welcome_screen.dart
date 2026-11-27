import 'package:material_ui/material_ui.dart';

import '../../app/app_controller.dart';
import '../../design/tokens.dart';
import '../../design/widgets/brand.dart';
import '../../design/widgets/kit.dart';
import 'login_screen.dart';
import 'signup_screen.dart';

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final message = context.appWatch.sessionMessage;
    return Scaffold(
      body: Stack(
        children: [
          const Positioned.fill(child: _Glow()),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(KnockSpace.gutter, 16, KnockSpace.gutter, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(children: [KnockWordmark(size: 20), Spacer(), SandboxPill()]),
                  const Spacer(),
                  TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: 1),
                    duration: const Duration(milliseconds: 700),
                    curve: KnockMotion.curve,
                    builder: (_, v, child) => Opacity(opacity: v, child: Transform.translate(offset: Offset(0, 24 * (1 - v)), child: child)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Money moves.\nMake yours count.', style: KnockText.display.copyWith(fontSize: 42)),
                        const SizedBox(height: 14),
                        Text('Sell gift cards and crypto, pay bills and send gifts. Your money moves when you do.',
                            style: KnockText.body.copyWith(color: KnockColors.textSecondary, fontSize: 16)),
                      ],
                    ),
                  ),
                  if (message != null) ...[const SizedBox(height: 20), Note(message, icon: Icons.lock_clock_outlined)],
                  const SizedBox(height: 32),
                  KnockButton(key: const ValueKey('welcome-create'), label: 'Create Account', onPressed: () => go(context, const SignupScreen())),
                  const SizedBox(height: 10),
                  KnockButton(key: const ValueKey('welcome-login'), label: 'Log In', style: KnockButtonStyle.ghost, onPressed: () => go(context, const LoginScreen())),
                  const SizedBox(height: 14),
                  Center(child: Text('Prototype running on a sandbox. No real money moves.', style: KnockText.micro.copyWith(fontWeight: FontWeight.w400))),
                ],
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
        center: Alignment(0.8, -0.7),
        radius: 1.3,
        colors: [Color(0x5500B03C), Color(0x22FF5001), KnockColors.background],
        stops: [0, 0.45, 1],
      ),
    ),
  );
}
