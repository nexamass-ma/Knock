import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../sandbox/db.dart';
import '../sandbox/server.dart';
import '../sandbox/util.dart';
import 'secure_store.dart';

export '../sandbox/util.dart' show ApiError;
export '../sandbox/server.dart';
export '../sandbox/catalog.dart';

enum ApiMode { sandbox, production }

/// The app's only way to reach Knock's backend.
///
/// In this prototype the backend is [KnockServer] running in-process
/// (sandbox mode). Every call still behaves like a network request: it is
/// asynchronous, has latency, can fail, returns copies, and carries the
/// session token plus replay-protection headers. Swapping to production
/// means replacing [_invoke] with HTTPS calls; screens do not change.
class KnockApi {
  KnockApi._(this.server, this._prefs, this.secure, this.deviceId, {this.latency = const Duration(milliseconds: 350)});

  static const mode = ApiMode.sandbox;
  static const _dbKey = 'knock.sandbox.db.v2';

  final KnockServer server;
  final SharedPreferences? _prefs;
  final SecureStore secure;
  final String deviceId;
  final Duration latency;

  String? token;
  Timer? _ticker;
  Timer? _saveDebounce;

  /// Prototype control: make every request fail to test error states.
  bool simulateOffline = false;

  final _ops = <String>[];
  String get opsToken {
    if (_ops.isEmpty) _ops.add(server.sandboxOpsToken());
    return _ops.first;
  }

  static Future<KnockApi> open({SecureStore? secure}) async {
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance().timeout(const Duration(seconds: 2));
    } catch (_) {
      prefs = null;
    }
    SandboxDb db;
    try {
      final raw = prefs?.getString(_dbKey);
      db = raw == null ? SandboxDb() : SandboxDb(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      db = SandboxDb();
    }
    final store = secure ?? SecureStore();
    var device = await store.read('knock.device');
    if (device == null) {
      device = 'dev_${randomToken(10)}';
      await store.write('knock.device', device);
    }
    final api = KnockApi._(KnockServer(db: db), prefs, store, device);
    db.onCommit = api._scheduleSave;
    api._scheduleSave();
    api.token = await store.read('knock.session');
    return api;
  }

  /// For tests: an in-memory API with no persistence and no latency.
  factory KnockApi.memory({KnockServer? server, Duration latency = Duration.zero}) {
    return KnockApi._(server ?? KnockServer(), null, SecureStore.memory(), 'test-device', latency: latency);
  }

  void startBackgroundJobs() {
    _ticker ??= Timer.periodic(const Duration(seconds: 2), (_) {
      try {
        server.tick();
      } catch (e) {
        debugPrint('sandbox tick failed: $e');
      }
    });
  }

  void dispose() {
    _ticker?.cancel();
    _saveDebounce?.cancel();
  }

  void _scheduleSave() {
    final prefs = _prefs;
    if (prefs == null) return;
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 400), () {
      prefs.setString(_dbKey, server.db.encode());
    });
  }

  Future<void> setToken(String? t) async {
    token = t;
    if (t == null) {
      await secure.delete('knock.session');
    } else {
      await secure.write('knock.session', t);
    }
  }

  /// Calls an endpoint. [fn] receives the server and the current session
  /// token, exactly like an authenticated HTTPS request.
  Future<Json> call(Json Function(KnockServer s, String? token) fn) async {
    if (latency > Duration.zero) await Future<void>.delayed(latency);
    if (simulateOffline) {
      throw ApiError('network', 'We could not reach Knock. Check your connection and try again.');
    }
    try {
      return fn(server, token);
    } on ApiError {
      rethrow;
    } on StateError catch (e) {
      debugPrint('server error: $e');
      throw ApiError('server', 'Something went wrong on our side. Please try again.');
    } on TypeError catch (e) {
      debugPrint('server error: $e');
      throw ApiError('server', 'Something went wrong on our side. Please try again.');
    }
  }

  /// Fresh replay-protection headers and an idempotency key for a money
  /// movement. Reuse the same [idempotencyKey] when retrying the same action.
  ({String nonce, String sentAt}) security() =>
      (nonce: randomToken(12), sentAt: server.now.toIso8601String());

  static String newIdempotencyKey() => 'idem_${randomToken(12)}';

  Future<void> resetSandbox() async {
    await _prefs?.remove(_dbKey);
    server.db.table('meta').clear();
    for (final t in server.db.toJson().keys.toList()) {
      server.db.table(t).clear();
    }
    seedSandbox(server);
    _ops.clear();
    await setToken(null);
  }
}
