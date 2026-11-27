import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/session.dart';
import '../core/util.dart';
import '../data/db.dart';
import '../data/repos.dart';
import '../data/schema.dart';
import '../data/sync_service.dart';

enum AuthStatus { booting, signedOut, needsBusiness, ready }

/// Sign-in model (MT5-style):
///   Owner  -> email + password (registers the business once)
///   Worker -> Business Code + Worker ID + password (created by the Owner; no self-registration)
///
/// Offline: after one successful online sign-in the credentials are kept in secure storage
/// (flutter_secure_storage), so the same person can unlock the app with no internet. A silent re-login
/// happens when the network returns; if the Owner changed the password meanwhile, that fails and the
/// device locks out.
///
/// Live revocation: we subscribe to our own profile row. Suspension, a password reset (session_epoch bump)
/// or changed permissions arrive within seconds; the first two lock the device out.
class AuthService extends ChangeNotifier {
  AuthStatus status = AuthStatus.booting;
  String? notice;
  UserSession? session;

  AppDb? db;
  SyncService? sync;
  CatalogRepo? catalog;
  SalesRepo? sales;

  final _secure = const FlutterSecureStorage();
  SupabaseClient get _c => Supabase.instance.client;
  RealtimeChannel? _meChannel;
  String? _activeLoginId;

  String workerLoginId(String code, String username) =>
      '${username.trim().toLowerCase()}@${code.trim().toLowerCase()}.${AppConfig.workerEmailDomain}';

  // ------------------------------------------------------------------ boot

  Future<void> boot() async {
    final s = _c.auth.currentSession;
    if (s == null) {
      _setStatus(AuthStatus.signedOut);
      return;
    }
    _activeLoginId = await _secure.read(key: 'last_login_id');
    try {
      await _enter(s.user.id);
    } catch (e) {
      notice = 'Could not open your workspace: $e';
      _setStatus(AuthStatus.signedOut);
    }
  }

  // ------------------------------------------------------------------ sign in / up

  /// Returns an error message, or null on success.
  Future<String?> signIn(String loginId, String password) async {
    if (loginId.isEmpty || password.isEmpty) return 'Enter your ID and password.';
    notice = null;
    try {
      final res = await _c.auth.signInWithPassword(email: loginId, password: password);
      final uid = res.user!.id;
      await _remember(loginId, password, uid);
      await _secure.delete(key: 'cache_$uid'); // fresh login resets the epoch baseline
      await _enter(uid);
      return null;
    } on AuthException catch (e) {
      if (isNetworkError(e)) return _offlineSignIn(loginId, password);
      final m = e.message.toLowerCase();
      if (m.contains('invalid login')) return 'Wrong ID or password.';
      if (m.contains('banned')) return 'This account has been suspended by the owner.';
      return e.message;
    } catch (e) {
      if (isNetworkError(e)) return _offlineSignIn(loginId, password);
      return '$e';
    }
  }

  Future<String?> registerOwner(String email, String password) async {
    try {
      final res = await _c.auth.signUp(email: email, password: password);
      if (res.session == null) {
        return 'Account created. Confirm your email, then sign in. '
            '(Tip: turn off "Confirm email" in Supabase Auth settings for instant setup.)';
      }
      await _remember(email, password, res.user!.id);
      await _enter(res.user!.id);
      return null;
    } on AuthException catch (e) {
      return e.message;
    } catch (e) {
      return isNetworkError(e) ? 'Registering a new business needs internet.' : '$e';
    }
  }

  Future<String?> createBusiness({
    required String name,
    required String ownerName,
    String? location,
    String? tin,
    String? phone,
    String? email,
  }) async {
    try {
      await _c.rpc('create_business', params: {
        'p_name': name,
        'p_owner_name': ownerName,
        'p_location': location,
        'p_tin': tin,
        'p_phone': phone,
        'p_email': email,
      });
      await _enter(_c.auth.currentUser!.id);
      return null;
    } on PostgrestException catch (e) {
      return e.message;
    } catch (e) {
      return isNetworkError(e) ? 'Setting up a business needs internet.' : '$e';
    }
  }

  Future<void> signOut() async {
    final id = _activeLoginId;
    await _teardown();
    if (id != null) await _secure.delete(key: 'cred_$id'); // shared phones: no offline unlock after sign-out
    try {
      await _c.auth.signOut();
    } catch (_) {}
    session = null;
    _setStatus(AuthStatus.signedOut);
  }

  // ------------------------------------------------------------------ internals

  Future<void> _remember(String loginId, String password, String uid) async {
    _activeLoginId = loginId;
    await _secure.write(key: 'cred_$loginId', value: password);
    await _secure.write(key: 'uid_$loginId', value: uid);
    await _secure.write(key: 'last_login_id', value: loginId);
  }

  Future<String?> _offlineSignIn(String loginId, String password) async {
    final saved = await _secure.read(key: 'cred_$loginId');
    final uid = await _secure.read(key: 'uid_$loginId');
    if (saved == null || uid == null) {
      return 'No internet. The first sign-in on a phone must be online.';
    }
    if (!_constEq(saved, password)) return 'Wrong ID or password.';
    _activeLoginId = loginId;
    try {
      await _enter(uid, offline: true);
      return null;
    } catch (e) {
      return '$e';
    }
  }

  bool _constEq(String a, String b) {
    if (a.length != b.length) return false;
    var d = 0;
    for (var i = 0; i < a.length; i++) {
      d |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return d == 0;
  }

  /// Loads profile + business (online, or from the secure cache when offline), opens the local DB,
  /// starts sync + live revocation.
  Future<void> _enter(String uid, {bool offline = false}) async {
    Map<String, dynamic>? profile;
    Map<String, dynamic>? biz;

    if (!offline) {
      try {
        profile = await _c.from('profiles').select().eq('id', uid).maybeSingle();
        if (profile == null) {
          _setStatus(AuthStatus.needsBusiness);
          return;
        }
        biz = await _c.from('businesses').select().eq('id', profile['business_id'] as String).single();

        final cachedRaw = await _secure.read(key: 'cache_$uid');
        if (cachedRaw != null) {
          final oldEpoch = (jsonDecode(cachedRaw)['profile']['session_epoch'] as num).toInt();
          if (oldEpoch != (profile['session_epoch'] as num).toInt()) {
            return _lockout('The owner changed your access. Please sign in again.');
          }
        }
        await _secure.write(key: 'cache_$uid', value: jsonEncode({'profile': profile, 'business': biz}));
      } catch (e) {
        if (!isNetworkError(e)) rethrow;
        offline = true;
      }
    }
    if (offline) {
      final raw = await _secure.read(key: 'cache_$uid');
      if (raw == null) throw StateError('No internet, and this phone has no saved workspace yet.');
      final m = jsonDecode(raw) as Map<String, dynamic>;
      profile = Map<String, dynamic>.from(m['profile'] as Map);
      biz = Map<String, dynamic>.from(m['business'] as Map);
    }

    if (profile!['status'] != 'active') {
      return _lockout('Your account has been suspended by the owner.');
    }

    await _teardown();
    final localDb = await AppDb.openLocal();
    localDb.bindBusiness(biz!['id'] as String);
    // Seed the local copy so the UI has names immediately, before the first pull finishes.
    localDb.upsert(kBusinesses, kBusinesses.fromServer(biz), dirty: false);
    localDb.upsert(kProfiles, kProfiles.fromServer(profile), dirty: false);

    session = _toSession(profile, biz);
    db = localDb;
    catalog = CatalogRepo(localDb, session!);
    sales = SalesRepo(localDb, session!);
    sync = SyncService(db: localDb, client: _c, businessId: biz['id'] as String, ensureSession: _silentReauth)..start();
    _watchProfile(uid);
    _setStatus(AuthStatus.ready);
  }

  UserSession _toSession(Map<String, dynamic> p, Map<String, dynamic> b) => UserSession(
        userId: p['id'] as String,
        businessId: p['business_id'] as String,
        businessName: b['name'] as String,
        businessCode: (b['code'] as String?) ?? '',
        username: p['username'] as String,
        fullName: p['full_name'] as String,
        role: p['role'] as String,
        permissions: Map<String, dynamic>.from((p['permissions'] as Map?) ?? const {}),
        epoch: (p['session_epoch'] as num).toInt(),
      );

  /// After an offline unlock we have no Supabase session; get one quietly when the network is back.
  Future<bool> _silentReauth() async {
    final id = _activeLoginId;
    if (id == null) return false;
    final pw = await _secure.read(key: 'cred_$id');
    if (pw == null) return false;
    try {
      await _c.auth.signInWithPassword(email: id, password: pw);
      return true;
    } on AuthException catch (e) {
      if (isNetworkError(e)) return false;
      await _lockout('Your password was changed by the owner. Please sign in again.');
      return false;
    } catch (_) {
      return false;
    }
  }

  void _watchProfile(String uid) {
    _meChannel = _c
        .channel('me:$uid')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'profiles',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'id', value: uid),
          callback: (payload) => _onProfileChanged(payload.newRecord),
        )
      ..subscribe();
  }

  Future<void> _onProfileChanged(Map<String, dynamic> rec) async {
    final cur = session;
    if (cur == null) return;
    if (rec['status'] != 'active') {
      return _lockout('Your account has been suspended by the owner.');
    }
    if ((rec['session_epoch'] as num).toInt() != cur.epoch) {
      return _lockout('The owner changed your password. Please sign in again.');
    }
    // Permissions changed: apply live, no restart needed.
    final updated = UserSession(
      userId: cur.userId, businessId: cur.businessId, businessName: cur.businessName,
      businessCode: cur.businessCode, username: cur.username, fullName: cur.fullName, role: cur.role,
      permissions: Map<String, dynamic>.from((rec['permissions'] as Map?) ?? const {}),
      epoch: cur.epoch,
    );
    session = updated;
    catalog = CatalogRepo(db!, updated);
    sales = SalesRepo(db!, updated);
    notifyListeners();
  }

  Future<void> _lockout(String reason) async {
    final id = _activeLoginId;
    await _teardown();
    if (id != null) await _secure.delete(key: 'cred_$id');
    final uid = _c.auth.currentUser?.id;
    if (uid != null) await _secure.delete(key: 'cache_$uid');
    try {
      await _c.auth.signOut();
    } catch (_) {}
    session = null;
    notice = reason;
    _setStatus(AuthStatus.signedOut);
  }

  Future<void> _teardown() async {
    if (_meChannel != null) {
      await _c.removeChannel(_meChannel!);
      _meChannel = null;
    }
    await sync?.stop();
    sync = null;
    db?.close();
    db = null;
    catalog = null;
    sales = null;
  }

  void _setStatus(AuthStatus s) {
    status = s;
    notifyListeners();
  }
}
