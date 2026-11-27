import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Keychain (iOS, this device only) / Keystore (Android) wrapper for the
/// session token and device id. Falls back to memory if the platform store
/// is unavailable (tests, some emulators). Never holds PINs, passwords,
/// card codes, BVN or NIN.
class SecureStore {
  SecureStore() : _store = const FlutterSecureStorage(
          iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
        );
  SecureStore.memory() : _store = null;

  final FlutterSecureStorage? _store;
  final _mem = <String, String>{};

  Future<String?> read(String key) async {
    if (_store == null) return _mem[key];
    try {
      return await _store.read(key: key).timeout(const Duration(seconds: 2));
    } catch (_) {
      return _mem[key];
    }
  }

  Future<void> write(String key, String value) async {
    _mem[key] = value;
    if (_store == null) return;
    try {
      await _store.write(key: key, value: value).timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  Future<void> delete(String key) async {
    _mem.remove(key);
    if (_store == null) return;
    try {
      await _store.delete(key: key).timeout(const Duration(seconds: 2));
    } catch (_) {}
  }
}
