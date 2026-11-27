import 'package:material_ui/material_ui.dart';

import '../design/theme.dart';
import '../features/auth/lock_screen.dart';
import '../features/shell/shell.dart';
import 'app_scope.dart';

class KnockApp extends StatefulWidget {
  const KnockApp({super.key, required this.state});
  final AppState state;

  @override
  State<KnockApp> createState() => _KnockAppState();
}

class _KnockAppState extends State<KnockApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    final session = widget.state.session;
    if (s == AppLifecycleState.paused) session.didBackground();
    if (s == AppLifecycleState.resumed) session.didResume();
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: widget.state,
      child: MaterialApp(
        title: 'KNOCK',
        debugShowCheckedModeBanner: false,
        theme: buildKnockTheme(),
        themeMode: ThemeMode.dark,
        home: ListenableBuilder(
          listenable: widget.state.session,
          builder: (context, _) => AnimatedSwitcher(
            duration: const Duration(milliseconds: 380),
            child: widget.state.session.unlocked
                ? const Shell(key: ValueKey('shell'))
                : const LockScreen(key: ValueKey('lock')),
          ),
        ),
      ),
    );
  }
}
