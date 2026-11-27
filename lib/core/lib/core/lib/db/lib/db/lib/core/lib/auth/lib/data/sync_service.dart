import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/util.dart';
import 'db.dart';
import 'schema.dart';

enum SyncState { idle, syncing, offline, error }

/// Offline-first sync.
///
///  PUSH  rows flagged dirty=1 are upserted to Supabase in parent-before-child order, then un-flagged.
///        Append-only tables use "ignore duplicates", so a retry after a dropped connection is harmless.
///  PULL  per table, "everything with server_updated_at after my cursor" (server clock, not phone clock),
///        with a 2s overlap to survive commit-order races. Applying a row twice is harmless.
///  LIVE  a Supabase Realtime channel only *nudges* a pull; the pull is the source of truth. If the socket
///        drops, a 45s timer and connectivity events catch up.
class SyncService extends ChangeNotifier {
  SyncService({
    required this.db,
    required this.client,
    required this.businessId,
    required this.ensureSession,
  });

  final AppDb db;
  final SupabaseClient client;
  final String businessId;

  /// Called when there is no Supabase session (e.g. we unlocked offline). Returns true if it got one.
  final Future<bool> Function() ensureSession;

  SyncState state = SyncState.idle;
  String? lastError;
  DateTime? lastSyncAt;
  int get pending => db.pendingCount();

  RealtimeChannel? _channel;
  Timer? _poll;
  Timer? _debounce;
  StreamSubscription<List<ConnectivityResult>>? _conn;
  bool _running = false;
  bool _again = false;
  bool _stopped = false;

  void start() {
    db.onLocalWrite = () => _kick(const Duration(milliseconds: 1500));
    _conn = Connectivity().onConnectivityChanged.listen((r) {
      if (r.contains(ConnectivityResult.none)) {
        _set(SyncState.offline);
      } else {
        _kick(const Duration(milliseconds: 300));
      }
    });
    _poll = Timer.periodic(const Duration(seconds: 45), (_) => syncNow());

    final ch = client.channel('biz:$businessId');
    for (final t in kTables) {
      ch.onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: t.name,
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: t.scopeCol,
          value: businessId,
        ),
        callback: (_) => _kick(const Duration(milliseconds: 400)),
      );
    }
    ch.subscribe();
    _channel = ch;
    syncNow();
  }

  Future<void> stop() async {
    _stopped = true;
    _debounce?.cancel();
    _poll?.cancel();
    await _conn?.cancel();
    db.onLocalWrite = null;
    if (_channel != null) await client.removeChannel(_channel!);
  }

  void _kick(Duration after) {
    _debounce?.cancel();
    _debounce = Timer(after, syncNow);
  }

  void _set(SyncState s) {
    if (_stopped) return;
    state = s;
    notifyListeners();
  }

  Future<void> syncNow() async {
    if (_stopped) return;
    if (_running) {
      _again = true;
      return;
    }
    _running = true;
    try {
      do {
        _again = false;
        if (client.auth.currentSession == null && !await ensureSession()) {
          _set(SyncState.offline);
          break;
        }
        _set(SyncState.syncing);
        await _push();
        await _pull();
        lastSyncAt = DateTime.now();
        lastError = null;
        _set(SyncState.idle);
      } while (_again && !_stopped);
    } catch (e) {
      if (isNetworkError(e)) {
        _set(SyncState.offline);
      } else {
        lastError = '$e';
        _set(SyncState.error);
      }
    } finally {
      _running = false;
    }
  }

  // ------------------------------------------------------------------ push

  Future<void> _push() async {
    for (final t in kTables.where((t) => t.push)) {
      while (true) {
        final rows = db.select('SELECT * FROM ${t.name} WHERE dirty = 1 ORDER BY rowid LIMIT 200');
        if (rows.isEmpty) break;
        final local = rows.map((r) => Map<String, Object?>.from(r)).toList();
        try {
          await client.from(t.name).upsert(
                local.map(t.toServer).toList(),
                ignoreDuplicates: t.appendOnly,
              );
          for (final r in local) {
            _markClean(t, r);
          }
        } on PostgrestException {
          // One bad row must not block the rest: retry individually.
          var progressed = false;
          for (final r in local) {
            try {
              await client.from(t.name).upsert(t.toServer(r), ignoreDuplicates: t.appendOnly);
              _markClean(t, r);
              progressed = true;
            } on PostgrestException catch (e) {
              lastError = '${t.name}: ${e.message}';
            }
          }
          if (!progressed) break; // leave poison rows dirty; they retry next cycle
        }
      }
    }
    notifyListeners();
  }

  void _markClean(TableSpec t, Map<String, Object?> r) {
    // Only un-flag if the row wasn't edited again while the upload was in flight.
    if (t.appendOnly) {
      db.exec('UPDATE ${t.name} SET dirty = 0 WHERE id = ?', [r['id']]);
    } else {
      db.exec(
        'UPDATE ${t.name} SET dirty = 0 WHERE id = ? AND updated_at = ?',
        [r['id'], r['updated_at']],
      );
    }
  }

  // ------------------------------------------------------------------ pull

  Future<void> _pull() async {
    for (final t in kTables) {
      final cursorKey = 'cursor:${t.name}';
      final saved = db.kv(cursorKey);
      String? from = saved == null
          ? null
          : DateTime.parse(saved).subtract(const Duration(seconds: 2)).toUtc().toIso8601String();

      while (true) {
        var q = client.from(t.name).select().eq(t.scopeCol, businessId);
        if (from != null) q = q.gt('server_updated_at', from);
        final List> page =
            await q.order('server_updated_at', ascending: true).limit(500);
        if (page.isEmpty) break;

        db.tx(() {
          for (final raw in page) {
            final row = t.fromServer(raw);
            if (!t.appendOnly && _localIsNewer(t, row)) continue; // our unsent edit wins; it will be pushed
            db.upsert(t, row, dirty: false);
          }
        });

        final last = t.fromServer(page.last)['server_updated_at'] as String?;
        if (last != null) {
          db.setKv(cursorKey, last);
          from = last;
        }
        if (page.length < 500) break;
      }
    }
  }

  bool _localIsNewer(TableSpec t, Map<String, Object?> incoming) {
    if (!t.push) return false;
    final r = db.select('SELECT dirty, updated_at FROM ${t.name} WHERE id = ?', [incoming['id']]);
    if (r.isEmpty || r.first['dirty'] != 1) return false;
    final localAt = DateTime.tryParse('${r.first['updated_at']}');
    final remoteAt = DateTime.tryParse('${incoming['updated_at']}');
    if (localAt == null || remoteAt == null) return false;
    return !localAt.isBefore(remoteAt);
  }
}
