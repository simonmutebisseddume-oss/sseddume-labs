import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth/auth_service.dart';
import 'core/util.dart';
import 'screens/auth/auth_screens.dart';
import 'screens/home/home_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!AppConfig.isConfigured) {
    runApp(const MaterialApp(
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Missing SUPABASE_URL / SUPABASE_ANON_KEY.\n'
              'Build with --dart-define (see README) or set the GitHub secrets.',
            ),
          ),
        ),
      ),
    ));
    return;
  }
  try {
    await Supabase.initialize(
      url: AppConfig.supabaseUrl,
      anonKey: AppConfig.supabaseAnonKey,
    );
  } catch (e) {
    debugPrint('Supabase init (offline start?): $e'); // the app must still open with no internet
  }
  final auth = AuthService();
  runApp(ChangeNotifierProvider.value(value: auth, child: const SseddumeApp()));
  auth.boot();
}

ThemeData _theme(Brightness b) {
  final dark = b == Brightness.dark;
  final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF00A884), brightness: b);
  return ThemeData(
    useMaterial3: true,
    colorScheme: dark ? scheme.copyWith(surface: Colors.black) : scheme,
    scaffoldBackgroundColor: dark ? Colors.black : const Color(0xFFF4F6F5),
    appBarTheme: AppBarTheme(
      backgroundColor: dark ? const Color(0xFF0B141A) : const Color(0xFF008069),
      foregroundColor: Colors.white,
      elevation: 0,
    ),
    cardTheme: CardThemeData(
      color: dark ? const Color(0xFF111B21) : Colors.white,
      elevation: dark ? 0 : 1,
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: dark ? const Color(0xFF0B141A) : Colors.white,
      indicatorColor: const Color(0xFF00A884).withValues(alpha: 0.25),
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
    ),
  );
}

class SseddumeApp extends StatelessWidget {
  const SseddumeApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'SSEDDUME POS',
        debugShowCheckedModeBanner: false,
        theme: _theme(Brightness.light),
        darkTheme: _theme(Brightness.dark),
        themeMode: ThemeMode.system,
        home: const _AuthGate(),
      );
}

class _AuthGate extends StatelessWidget {
  const _AuthGate();
  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();
    switch (auth.status) {
      case AuthStatus.booting:
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      case AuthStatus.signedOut:
        return const LoginScreen();
      case AuthStatus.needsBusiness:
        return const BusinessSetupScreen();
      case AuthStatus.ready:
        return const HomeShell();
    }
  }
}
