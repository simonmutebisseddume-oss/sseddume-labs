import 'dart:math';

import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

class AppConfig {
  static const supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://fvunvoezjnwpemnonksx.supabase.co',
  );
  static const supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue: '',
  );
  // Must match WORKER_EMAIL_DOMAIN in the worker-admin edge function.
  static const workerEmailDomain = String.fromEnvironment(
    'WORKER_EMAIL_DOMAIN',
    defaultValue: 'w.sseddume.app',
  );
  static const platformName = 'SSEDDUME LABS';
  static bool get isConfigured => supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;
}

const _uuid = Uuid();
String newId() => _uuid.v4();
String nowIso() => DateTime.now().toUtc().toIso8601String();

final _ugx = NumberFormat('#,##0', 'en_US');
String fmtUgx(num v) => 'UGX ${_ugx.format(v)}';

/// True when an exception just means "no internet right now" (so we fall back to offline mode).
bool isNetworkError(Object e) {
  final s = '${e.runtimeType} $e';
  return s.contains('SocketException') ||
      s.contains('ClientException') ||
      s.contains('TimeoutException') ||
      s.contains('RetryableFetch') ||
      s.contains('Failed host lookup') ||
      s.contains('Network is unreachable') ||
      s.contains('Connection');
}

const _alphabet = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ'; // 32 chars, no 0/O/1/I look-alikes

/// Unique in-house SKU for unlabeled market goods. 32^10 combinations: devices can mint these offline
/// without ever colliding.
String generateInternalCode() {
  final r = Random.secure();
  return 'SL${List.generate(10, (_) => _alphabet[r.nextInt(32)]).join()}';
}
