import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Wraps the platform keystore: iOS Keychain (this-device-only, available
/// after first unlock) and Android Keystore-backed EncryptedSharedPreferences.
///
/// Only short-lived session tokens and the device key handle live here.
/// Private keys for crypto custody are never stored on the device; custody
/// sits with the backend's custody partner. PINs are never stored at all;
/// they are verified server-side.
class SecureStore {
  SecureStore()
    : _storage = const FlutterSecureStorage(
        iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
      );

  final FlutterSecureStorage _storage;
  final Map<String, String> _fallback = {};
  static const _timeout = Duration(seconds: 2);

  static const sessionTokenKey = 'knock.session.token';
  static const deviceIdKey = 'knock.device.id';

  Future<void> write(String key, String value) async {
    try {
      await _storage.write(key: key, value: value).timeout(_timeout);
    } catch (_) {
      // Web preview or a locked keystore: keep in memory only.
      _fallback[key] = value;
    }
  }

  Future<String?> read(String key) async {
    try {
      return await _storage.read(key: key).timeout(_timeout) ?? _fallback[key];
    } catch (_) {
      return _fallback[key];
    }
  }

  Future<void> delete(String key) async {
    _fallback.remove(key);
    try {
      await _storage.delete(key: key).timeout(_timeout);
    } catch (_) {}
  }
}
