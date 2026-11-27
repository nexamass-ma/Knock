import 'package:material_ui/material_ui.dart';

import '../app/app_scope.dart';
import '../services/security/secure_store.dart';

/// Session and preferences. In production the session is a short-lived
/// access token plus a rotating refresh token, both in [SecureStore]. The
/// app locks after [idleTimeout] in the background.
class SessionStore extends ChangeNotifier {
  SessionStore(this._services);
  final AppServices _services;

  static const idleTimeout = Duration(minutes: 2);

  bool unlocked = false;
  bool hideBalances = false;
  bool biometricsEnabled = true;
  bool showUsd = false;
  final String firstName = 'Ada';
  final String fullName = 'Ada Okafor';
  final String phone = '0803 555 4412';
  final int kycTier = 1;
  DateTime? _backgroundedAt;

  bool get simulateErrors => _services.mockBackend?.simulateErrors ?? false;

  Future<void> unlock() async {
    await _services.secureStore.write(
      SecureStore.sessionTokenKey,
      'mock-session-${DateTime.now().millisecondsSinceEpoch}',
    );
    unlocked = true;
    notifyListeners();
  }

  Future<void> signOut() async {
    await _services.secureStore.delete(SecureStore.sessionTokenKey);
    unlocked = false;
    notifyListeners();
  }

  void didBackground() => _backgroundedAt = DateTime.now();

  void didResume() {
    final at = _backgroundedAt;
    _backgroundedAt = null;
    if (unlocked && at != null && DateTime.now().difference(at) > idleTimeout) {
      unlocked = false;
      notifyListeners();
    }
  }

  void toggleHideBalances() {
    hideBalances = !hideBalances;
    notifyListeners();
  }

  void setShowUsd(bool v) {
    showUsd = v;
    notifyListeners();
  }

  void setBiometrics(bool v) {
    biometricsEnabled = v;
    notifyListeners();
  }

  void setSimulateErrors(bool v) {
    _services.mockBackend?.simulateErrors = v;
    notifyListeners();
  }

  void resetMockData() {
    _services.mockBackend?.reset();
    notifyListeners();
  }
}
