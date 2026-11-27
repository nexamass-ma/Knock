import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// Error returned by the Knock API. [code] is stable and machine readable;
/// [message] is written for customers.
class ApiError implements Exception {
  ApiError(this.code, this.message, {this.details});
  final String code;
  final String message;
  final Map<String, dynamic>? details;

  @override
  String toString() => 'ApiError($code): $message';
}

final _rand = Random.secure();

String randomToken([int bytes = 24]) {
  final b = List<int>.generate(bytes, (_) => _rand.nextInt(256));
  return base64Url.encode(b).replaceAll('=', '');
}

String newId(String prefix) => '${prefix}_${randomToken(9)}';

const _refAlphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

/// Customer-facing reference such as KNK-7QH2M9XA.
String newReference([String prefix = 'KNK']) =>
    '$prefix-${List.generate(8, (_) => _refAlphabet[_rand.nextInt(_refAlphabet.length)]).join()}';

String newOtp() => List.generate(6, (_) => _rand.nextInt(10)).join();

String sha256Hex(String s) => sha256.convert(utf8.encode(s)).toString();

/// PBKDF2-HMAC-SHA256. The sandbox uses fewer iterations so it stays fast on
/// a phone; production uses Argon2id or PBKDF2 with 600k iterations,
/// server-side only.
String hashPassword(String password, String salt, {int iterations = 1500}) {
  final hmac = Hmac(sha256, utf8.encode(password));
  var u = hmac.convert([...utf8.encode(salt), 0, 0, 0, 1]).bytes;
  final out = List<int>.from(u);
  for (var i = 1; i < iterations; i++) {
    u = hmac.convert(u).bytes;
    for (var j = 0; j < out.length; j++) {
      out[j] ^= u[j];
    }
  }
  return base64.encode(out);
}

bool constantTimeEquals(String a, String b) {
  if (a.length != b.length) return false;
  var r = 0;
  for (var i = 0; i < a.length; i++) {
    r |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return r == 0;
}

/// Authenticated encryption for secrets at rest (gift card codes).
/// Keystream = SHA-256(key | nonce | counter), tag = HMAC-SHA256.
/// Production uses AES-256-GCM with keys held in a KMS/HSM.
class SecretBox {
  SecretBox(this._key);
  final String _key;

  String seal(String plain) {
    final nonce = randomToken(12);
    final data = utf8.encode(plain);
    final ks = _keystream(nonce, data.length);
    final ct = [for (var i = 0; i < data.length; i++) data[i] ^ ks[i]];
    final body = '$nonce.${base64Url.encode(ct)}';
    final tag = Hmac(sha256, utf8.encode(_key)).convert(utf8.encode(body)).toString();
    return '$body.$tag';
  }

  String open(String sealed) {
    final parts = sealed.split('.');
    if (parts.length != 3) throw ApiError('crypto', 'Secret is corrupted.');
    final body = '${parts[0]}.${parts[1]}';
    final tag = Hmac(sha256, utf8.encode(_key)).convert(utf8.encode(body)).toString();
    if (!constantTimeEquals(tag, parts[2])) throw ApiError('crypto', 'Secret failed integrity check.');
    final ct = base64Url.decode(parts[1]);
    final ks = _keystream(parts[0], ct.length);
    return utf8.decode([for (var i = 0; i < ct.length; i++) ct[i] ^ ks[i]]);
  }

  List<int> _keystream(String nonce, int n) {
    final out = <int>[];
    var c = 0;
    while (out.length < n) {
      out.addAll(sha256.convert(utf8.encode('$_key|$nonce|${c++}')).bytes);
    }
    return out.sublist(0, n);
  }
}

String maskEmail(String email) {
  final at = email.indexOf('@');
  if (at < 1) return '***';
  final name = email.substring(0, at);
  return '${name[0]}${'*' * (name.length - 1).clamp(2, 6)}${email.substring(at)}';
}

String maskPhone(String phone) =>
    phone.length < 6 ? '***' : '${phone.substring(0, 4)}${'*' * (phone.length - 7)}${phone.substring(phone.length - 3)}';

String last4(String s) => s.length <= 4 ? s : s.substring(s.length - 4);

/// "Ada Okafor" -> "Ada O."
String publicName(String fullName) {
  final parts = fullName.trim().split(RegExp(r'\s+'));
  if (parts.length == 1) return parts.first;
  return '${parts.first} ${parts.last[0]}.';
}

final emailRe = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]{2,}$');

/// Strength 0..4. Rules match the client meter.
int passwordStrength(String p) {
  var s = 0;
  if (p.length >= 8) s++;
  if (p.length >= 12) s++;
  if (RegExp(r'[A-Z]').hasMatch(p) && RegExp(r'[a-z]').hasMatch(p)) s++;
  if (RegExp(r'\d').hasMatch(p)) s++;
  if (RegExp(r'[^A-Za-z0-9]').hasMatch(p)) s++;
  return s.clamp(0, 4);
}

String? passwordProblem(String p) {
  if (p.length < 8) return 'Use at least 8 characters.';
  if (!RegExp(r'[A-Za-z]').hasMatch(p) || !RegExp(r'\d').hasMatch(p)) {
    return 'Use a mix of letters and numbers.';
  }
  return null;
}

Map<String, dynamic> deepCopy(Map<String, dynamic> m) => jsonDecode(jsonEncode(m)) as Map<String, dynamic>;
