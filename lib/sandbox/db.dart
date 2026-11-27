import 'dart:convert';

/// A tiny document database for the sandbox backend.
///
/// Every table is a map of id -> JSON row. [transaction] snapshots the whole
/// store and restores it if the body throws, so a financial operation either
/// posts every ledger line or none (all-or-nothing, like a SQL transaction).
///
/// In production this is Postgres with real transactions, row locks and
/// constraints. See docs/ARCHITECTURE.md.
class SandboxDb {
  SandboxDb([Map<String, dynamic>? data]) {
    if (data != null) {
      for (final e in data.entries) {
        _tables[e.key] = {
          for (final r in (e.value as Map).entries) r.key as String: Map<String, dynamic>.from(r.value as Map),
        };
      }
    }
  }

  final Map<String, Map<String, Map<String, dynamic>>> _tables = {};
  int _depth = 0;

  /// Called after every committed write. Used to persist the sandbox.
  void Function()? onCommit;

  Map<String, Map<String, dynamic>> table(String name) => _tables.putIfAbsent(name, () => {});

  Map<String, dynamic>? get(String t, String id) => table(t)[id];

  Map<String, dynamic> insert(String t, Map<String, dynamic> row) {
    final id = row['id'] as String;
    if (table(t).containsKey(id)) throw StateError('Duplicate key $t/$id');
    table(t)[id] = row;
    _autocommit();
    return row;
  }

  void put(String t, Map<String, dynamic> row) {
    table(t)[row['id'] as String] = row;
    _autocommit();
  }

  void update(String t, String id, Map<String, dynamic> patch) {
    final row = table(t)[id];
    if (row == null) throw StateError('Missing $t/$id');
    row.addAll(patch);
    _autocommit();
  }

  void delete(String t, String id) {
    table(t).remove(id);
    _autocommit();
  }

  Iterable<Map<String, dynamic>> where(String t, bool Function(Map<String, dynamic>) test) =>
      table(t).values.where(test);

  Map<String, dynamic>? firstWhere(String t, bool Function(Map<String, dynamic>) test) {
    for (final r in table(t).values) {
      if (test(r)) return r;
    }
    return null;
  }

  /// Runs [body] atomically. Nested calls join the outer transaction.
  T transaction<T>(T Function() body) {
    if (_depth > 0) return body();
    final snapshot = jsonEncode(_tables);
    _depth++;
    try {
      final result = body();
      _depth--;
      onCommit?.call();
      return result;
    } catch (_) {
      _depth--;
      _tables
        ..clear()
        ..addAll(SandboxDb(jsonDecode(snapshot) as Map<String, dynamic>)._tables);
      rethrow;
    }
  }

  void _autocommit() {
    if (_depth == 0) onCommit?.call();
  }

  Map<String, dynamic> toJson() => _tables;
  String encode() => jsonEncode(_tables);
}
