import 'package:material_ui/material_ui.dart';

import '../design/theme.dart';
import '../design/tokens.dart';
import '../design/widgets/brand.dart';
import '../features/auth/lock_screen.dart';
import '../features/auth/welcome_screen.dart';
import '../features/onboarding/onboarding_flow.dart';
import '../features/shell/shell.dart';
import 'app_controller.dart';

class KnockApp extends StatefulWidget {
  const KnockApp({super.key, required this.controller});
  final AppController controller;
  @override
  State<KnockApp> createState() => _KnockAppState();
}

class _KnockAppState extends State<KnockApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.controller.phase == AppPhase.booting) widget.controller.boot();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) widget.controller.didBackground();
    if (state == AppLifecycleState.resumed) widget.controller.didResume();
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      controller: widget.controller,
      child: MaterialApp(
        title: 'Knock',
        debugShowCheckedModeBanner: false,
        theme: buildKnockTheme(),
        home: const _Root(),
      ),
    );
  }
}

class _Root extends StatelessWidget {
  const _Root();
  @override
  Widget build(BuildContext context) {
    final app = context.appWatch;
    final Widget child = switch (app.phase) {
      AppPhase.booting => const _Splash(),
      AppPhase.signedOut => const WelcomeScreen(),
      AppPhase.onboarding => const OnboardingFlow(),
      AppPhase.ready => const Shell(),
      AppPhase.locked => const LockScreen(),
    };
    return AnimatedSwitcher(
      duration: KnockMotion.slow,
      child: KeyedSubtree(key: ValueKey(app.phase), child: child),
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash();
  @override
  Widget build(BuildContext context) => const Scaffold(body: Center(child: KnockMark(size: 72)));
}
