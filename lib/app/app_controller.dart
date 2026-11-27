import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../api/api.dart';

enum AppPhase { booting, signedOut, onboarding, ready, locked }

/// App-wide session state. Holds only what the backend returned; never
/// computes balances or eligibility itself.
class AppController extends ChangeNotifier {
  AppController(this.api);

  final KnockApi api;

  AppPhase phase = AppPhase.booting;
  Json? me;
  Json? sync;
  int unread = 0;
  bool hideBalances = false;
  String? sessionMessage;

  /// Bumps whenever the backend reports something changed. Screens that
  /// show live data refetch when it changes.
  int dataVersion = 0;
  String _lastSync = '';
  Timer? _poll;
  DateTime? _backgroundedAt;

  String get firstName => (me?['firstName'] as String?) ?? '';
  int get tier => (me?['tier'] as int?) ?? 0;
  String get currency => (me?['currency'] as String?) ?? 'NGN';
  bool get hasPin => me?['hasPin'] == true;

  Future<void> boot() async {
    api.startBackgroundJobs();
    if (api.token == null) {
      _set(AppPhase.signedOut);
      return;
    }
    try {
      await refreshMe();
      _enter();
    } on ApiError catch (e) {
      await api.setToken(null);
      sessionMessage = e.code == 'session_expired' ? e.message : null;
      _set(AppPhase.signedOut);
    }
  }

  Future<void> refreshMe() async {
    final r = await api.call((s, t) => s.me(t!));
    me = r['user'] as Json;
    notifyListeners();
  }

  void _enter() {
    final onboarding = me?['onboarding'] as String?;
    if (onboarding != null && onboarding != 'done') {
      _set(AppPhase.onboarding);
    } else {
      _set(AppPhase.ready);
      _startPolling();
    }
  }

  Future<void> signedIn(String token, Json user) async {
    await api.setToken(token);
    me = user;
    sessionMessage = null;
    _enter();
  }

  void onboardingDone(Json user) {
    me = user;
    _enter();
  }

  void updateMe(Json user) {
    me = user;
    notifyListeners();
  }

  Future<void> logout({String? message}) async {
    _poll?.cancel();
    try {
      await api.call((s, t) => s.logout(t ?? ''));
    } catch (_) {}
    await api.setToken(null);
    me = null;
    sync = null;
    unread = 0;
    sessionMessage = message;
    _set(AppPhase.signedOut);
  }

  void _startPolling() {
    _poll?.cancel();
    _pollOnce();
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => _pollOnce());
  }

  Future<void> _pollOnce() async {
    if (phase != AppPhase.ready || api.token == null) return;
    try {
      final r = await api.call((s, t) => s.syncState(t!));
      sync = r;
      final key = '${r['last']}|${r['available']}|${r['bonus']}|${r['tier']}|${r['unread']}';
      if (key != _lastSync) {
        _lastSync = key;
        unread = r['unread'] as int;
        if (r['tier'] != tier) await refreshMe();
        dataVersion++;
        notifyListeners();
      }
    } on ApiError catch (e) {
      if (e.code == 'unauthenticated' || e.code == 'session_expired') {
        await logout(message: e.message);
      }
    }
  }

  bool get introSeen => api.introSeen;

  /// Called when the person finishes or skips the intro slides.
  Future<void> introDone() async {
    await api.markIntroSeen();
    notifyListeners();
  }

  /// Ask screens to refetch now (after the user did something).
  void poke() {
    _lastSync = '';
    _pollOnce();
  }

  void toggleHideBalances() {
    hideBalances = !hideBalances;
    notifyListeners();
  }

  void didBackground() => _backgroundedAt = DateTime.now();

  void didResume() {
    final at = _backgroundedAt;
    _backgroundedAt = null;
    if (at != null && phase == AppPhase.ready && hasPin && DateTime.now().difference(at) > const Duration(minutes: 2)) {
      _set(AppPhase.locked);
    }
  }

  void unlocked() => _set(AppPhase.ready);

  void _set(AppPhase p) {
    phase = p;
    notifyListeners();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }
}

class AppScope extends InheritedNotifier<AppController> {
  const AppScope({super.key, required AppController controller, required super.child}) : super(notifier: controller);

  static AppController of(BuildContext context, {bool listen = false}) {
    final scope = listen
        ? context.dependOnInheritedWidgetOfExactType<AppScope>()
        : context.getInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope missing');
    return scope!.notifier!;
  }
}

extension AppX on BuildContext {
  AppController get app => AppScope.of(this);
  AppController get appWatch => AppScope.of(this, listen: true);
  KnockApi get api => AppScope.of(this).api;
}
