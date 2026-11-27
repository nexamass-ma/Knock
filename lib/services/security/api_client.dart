/// Blueprint for the production HTTP client. Not used by the prototype,
/// which runs entirely on mock services. Kept here so the integration
/// points are explicit when the backend is ready.
///
/// Rules the real client must follow:
///  * HTTPS only, with certificate (public key) pinning to KNOCK's API.
///  * Every request carries a short-lived access token from [SecureStore]
///    and a device ID; refresh tokens rotate on use.
///  * Every money-moving request carries an `Idempotency-Key` header, the
///    quote ID, and the signed [AuthorizationProof]. The server rejects a
///    reused quote or a mismatched proof.
///  * Device integrity (Play Integrity on Android, App Attest on iOS) is
///    attached at login and before high-risk actions.
///  * The client never sends a computed price, fee or balance. It sends
///    what the user chose; the server prices, validates limits (KYC tier),
///    runs fraud checks, posts double-entry ledger lines and settles.
///  * Responses are treated as display data. Balances on screen are always
///    the last server value, never a client-side running total.
library;

class ApiConfig {
  const ApiConfig({required this.baseUrl, required this.pinnedKeyHashes, this.timeout = const Duration(seconds: 20)});

  final Uri baseUrl;

  /// SHA-256 hashes of the API's SubjectPublicKeyInfo (current + backup).
  final List<String> pinnedKeyHashes;
  final Duration timeout;
}

/// Headers every authenticated request must send.
Map<String, String> secureHeaders({required String accessToken, required String deviceId, String? idempotencyKey}) => {
  'Authorization': 'Bearer $accessToken',
  'X-Device-Id': deviceId,
  'X-Client': 'knock-mobile',
  'Idempotency-Key': ?idempotencyKey,
};
