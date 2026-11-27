import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';

/// Device-side user verification (Face ID, Touch ID, fingerprint, or the
/// device passcode). The result unlocks a device-bound signing key that
/// signs the server's challenge for a specific quote.
class BiometricAuthorizer {
  BiometricAuthorizer() : _auth = kIsWeb ? null : LocalAuthentication();
  final LocalAuthentication? _auth;

  /// Whether the device can do biometric or passcode verification at all.
  Future<bool> isAvailable() async {
    final auth = _auth;
    if (auth == null) return false;
    try {
      return await auth.isDeviceSupported();
    } catch (_) {
      return false;
    }
  }

  /// Returns true when the user verified. False on cancel or failure, so the
  /// caller can fall back to the KNOCK PIN.
  Future<bool> verify(String reason) async {
    final auth = _auth;
    if (auth == null) return false;
    try {
      return await auth.authenticate(localizedReason: reason);
    } catch (_) {
      return false;
    }
  }
}

/// The KNOCK transaction PIN. In production the PIN is sent over the
/// pinned TLS channel and checked by the backend with rate limiting and
/// lockout; it is never stored on the device.
class MockPinVerifier {
  const MockPinVerifier();

  /// Mock: any 4-digit PIN except 0000 succeeds.
  Future<bool> verify(String pin) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return pin.length == 4 && pin != '0000';
  }
}
