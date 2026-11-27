import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import '../core/util.dart';
import 'schema.dart';

/// Local SQLite database for Sseddume Labs (Android & Windows compatible).
///
/// UPGRADE RULES (this is how business data survives app updates):
///   1. Never edit an old migration. Append a new one to [_migrations].
///   2. The TableSpecs describe the LATEST schema, so fresh installs get it via CREATE TABLE IF NOT EXISTS.
///      Migrations for existing installs must be idempotent, e.g. addColumnIfMissing().
///   3. A copy of the database file is taken before any migration runs, and the migration runs in a
///      single transaction: it either fully applies or leaves the old data untouched.
class AppDb extends ChangeNotifier {
  AppDb._(this._db, this.path, this.dir);

  final Database _db;
  final String path;
  final Directory dir;

  /// SyncService hooks in here so a local write triggers a push shortly after.
  VoidCallback? onLocalWrite;

  int _depth = 0;
  bool _localWrite = false;

  // ------------------------------------------------------------------ open / migrate

  static Future<AppDb> openLocal() async {
    final dir = await getApplicationSupportDirectory();
    final file = p.join(dir.path, 'sseddume.db');

    final db = sqlite3.open(file);
    db.execute('PRAGMA journal_mode = WAL;');
    db.execute('PRAGMA synchronous = NORMAL;');
    db.execute('PRAGMA foreign_keys = ON;');

    final app = AppDb._(db, file, dir);
    app._migrate();
    app._dailyBackup();
    if (app.kv('device_id') == null) app.setKv('device_id', newId());
    return app;
  }

  static final List<List<String>> _migrations = [
    // v1
    [
      'CREATE TABLE IF NOT EXISTS kv (k TEXT PRIMARY KEY, v TEXT)',
      for (final t in kTables) ...t.ddl(),
    ],
    // v2+ : append here. Example:
    // ['ALTER TABLE products ADD COLUMN supplier TEXT'],
  ];

  void _migrate() {
    final current = _db.select('PRAGMA user_version').first.values.first as int;
    if (current > _migrations.length) {
      throw StateError('This database was created by a newer app version. Update the app.');
    }
    if (current == _migrations.length) return;
    if (current > 0) backup('pre-migration-v$current');

    _db.execute('BEGIN IMMEDIATE');
    try {
      for (var v = current; v < _migrations.length; v++) {
        for (final sql in _migrations[v]) {
          _db.execute(sql);
        }
        _db.execute('PRAGMA user_version = ${v + 1}');
      }
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Helper for idempotent column additions inside migrations.
  void addColumnIfMissing(String table, String column, String decl) {
    final has = _db.select('PRAGMA table_info($table)').any((r) => r['name'] == column);
    if (!has) _db.execute('ALTER TABLE $table ADD COLUMN $column $decl');
  }

  // ------------------------------------------------------------------ backups

  /// Copies the database file. Keeps the 10 newest.
  String backup(String label) {
    _db.execute('PRAGMA wal_checkpoint(TRUNCATE);');
    final bdir = Directory(p.join(dir.path, 'backups'))..createSync(recursive: true);
    final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
    final out = p.join(bdir.path, 'sseddume-$stamp-$label.db');
    File(path).copySync(out);
    final all = bdir.listSync().whereType<File>().toList()
      ..sort((a, b) => b.path.compareTo(a.path));
    for (final old in all.skip(10)) {
      old.deleteSync();
    }
    return out;
  }

  void _dailyBackup() {
    final last = DateTime.tryParse(kv('last_backup') ?? '');
    if (last == null || DateTime.now().difference(last) > const Duration(hours: 24)) {
      if (_db.select('SELECT count(*) c FROM sales').first['c'] as int > 0) backup('daily');
      setKv('last_backup', DateTime.now().toIso8601String());
    }
  }

  // ------------------------------------------------------------------ basic access

  ResultSet select(String sql, [List<Object?> args = const []]) => _db.select(sql, args);
  void exec(String sql, [List<Object?> args = const []]) => _db.execute(sql, args);

  String? kv(String k) {
    final r = _db.select('SELECT v FROM kv WHERE k = ?', [k]);
    return r.isEmpty ? null : r.first['v'] as String?;
  }

  void setKv(String k, String v) =>
      _db.execute('INSERT OR REPLACE INTO kv (k, v) VALUES (?, ?)', [k, v]);

  String get deviceCode =>
      (kv('device_id') ?? 'XXXX').replaceAll('-', '').substring(0, 3).toUpperCase();

  int nextSeq(String name) {
    final n = (int.tryParse(kv('seq:$name') ?? '') ?? 0) + 1;
    setKv('seq:$name', '$n');
    return n;
  }

  /// Runs [body] atomically. Re-entrant (an inner call just joins the outer transaction).
  T tx<T>(T Function() body) {
    if (_depth > 0) return body();
    _depth++;
    _db.execute('BEGIN IMMEDIATE');
    try {
      final r = body();
      _db.execute('COMMIT');
      _depth--;
      final wrote = _localWrite;
      _localWrite = false;
      notifyListeners();
      if (wrote) onLocalWrite?.call();
      return r;
    } catch (_) {
      try {
        _db.execute('ROLLBACK');
      } catch (_) {}
      _depth--;
      _localWrite = false;
      rethrow;
    }
  }

  /// Insert-or-replace a FULL row. [dirty] = true marks it for upload.
  void upsert(TableSpec t, Map<String, Object?> row, {required bool dirty}) {
    tx(() {
      final data = {...row};
      if (t.push) data['dirty'] = dirty ? 1 : 0;
      final cols = data.keys.toList();
      _db.execute(
        'INSERT OR REPLACE INTO ${t.name} (${cols.join(',')}) VALUES (${List.filled(cols.length, '?').join(',')})',
        cols.map((c) => data[c]).toList(),
      );
      if (dirty) _localWrite = true;
    });
  }

  /// Change some columns of an existing row (stamps updated_at, marks dirty).
  void patch(TableSpec t, String id, Map<String, Object?> changes) {
    tx(() {
      final rows = _db.select('SELECT * FROM ${t.name} WHERE id = ?', [id]);
      if (rows.isEmpty) throw StateError('${t.name} row $id not found');
      final row = Map<String, Object?>.from(rows.first)..addAll(changes);
      if (!t.appendOnly) row['updated_at'] = nowIso();
      upsert(t, row, dirty: true);
    });
  }

  Map<String, Object?>? byId(TableSpec t, String id) {
    final r = _db.select('SELECT * FROM ${t.name} WHERE id = ?', [id]);
    return r.isEmpty ? null : Map<String, Object?>.from(r.first);
  }

  int pendingCount() {
    final sql = kTables
        .where((t) => t.push)
        .map((t) => '(SELECT COUNT(*) FROM ${t.name} WHERE dirty = 1)')
        .join('+');
    return _db.select('SELECT $sql AS n').first['n'] as int;
  }

  Map<String, Object?>? business() {
    final bizId = kv('business_id');
    final r = bizId != null
        ? _db.select('SELECT * FROM businesses WHERE id = ? LIMIT 1', [bizId])
        : _db.select('SELECT * FROM businesses LIMIT 1');
    return r.isEmpty ? null : Map<String, Object?>.from(r.first);
  }

  /// A device only ever holds ONE business. If someone signs in to a different business on the same
  /// phone, the old local copy is cleared - unless it still has unsynced work, which we refuse to destroy.
  void bindBusiness(String businessId) {
    final cur = kv('business_id');
    if (cur != null && cur != businessId) {
      if (pendingCount() > 0) {
        throw StateError(
          'This phone still has unsynced data from another business. '
          'Connect to the internet and let it sync first.',
        );
      }
      tx(() {
        for (final t in kTables) {
          _db.execute('DELETE FROM ${t.name}');
        }
        _db.execute("DELETE FROM kv WHERE k LIKE 'cursor:%'");
      });
    }
    setKv('business_id', businessId);
  }

  void close() => _db.dispose();

  String debugSummary() => jsonEncode({
        for (final t in kTables) t.name: _db.select('SELECT COUNT(*) c FROM ${t.name}').first['c'],
      });
}
