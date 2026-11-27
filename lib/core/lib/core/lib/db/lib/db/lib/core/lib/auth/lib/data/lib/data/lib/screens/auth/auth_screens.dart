import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../auth/auth_service.dart';
import '../../core/util.dart';

class _Shell extends StatelessWidget {
  const _Shell({required this.title, required this.children, this.appBar});
  final String title;
  final List<Widget> children;
  final PreferredSizeWidget? appBar;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: appBar,
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Icon(Icons.storefront_rounded, size: 56, color: Color(0xFF00A884)),
                    const SizedBox(height: 12),
                    Text(
                      title,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 24),
                    ...children,
                    const SizedBox(height: 32),
                    Text(
                      'Powered by ${AppConfig.platformName}',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Colors.grey),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  bool _owner = false, _busy = false, _hide = true;
  String? _error;
  final _code = TextEditingController();
  final _user = TextEditingController();
  final _email = TextEditingController();
  final _pass = TextEditingController();

  @override
  void dispose() {
    _code.dispose();
    _user.dispose();
    _email.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final auth = context.read<AuthService>();
    setState(() {
      _busy = true;
      _error = null;
    });
    final id = _owner ? _email.text.trim().toLowerCase() : auth.workerLoginId(_code.text, _user.text);
    final err = await auth.signIn(id, _pass.text);
    if (mounted) {
      setState(() {
        _busy = false;
        _error = err;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final notice = context.watch<AuthService>().notice;
    return _Shell(
      title: 'Sign in',
      children: [
        if (notice != null)
          Card(
            color: Colors.amber.shade100,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(notice, style: const TextStyle(color: Colors.black87)),
            ),
          ),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('Worker'), icon: Icon(Icons.badge_outlined)),
            ButtonSegment(
              value: true,
              label: Text('Owner'),
              icon: Icon(Icons.admin_panel_settings_outlined),
            ),
          ],
          selected: {_owner},
          onSelectionChanged: (s) => setState(() => _owner = s.first),
        ),
        const SizedBox(height: 16),
        if (_owner)
          TextField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(labelText: 'Owner email'),
          )
        else ...[
          TextField(
            controller: _code,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(labelText: 'Business code', helperText: 'Ask your owner'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _user,
            autocorrect: false,
            decoration: const InputDecoration(labelText: 'Worker ID'),
          ),
        ],
        const SizedBox(height: 12),
        TextField(
          controller: _pass,
          obscureText: _hide,
          onSubmitted: (_) => _submit(),
          decoration: InputDecoration(
            labelText: 'Password',
            suffixIcon: IconButton(
              icon: Icon(_hide ? Icons.visibility : Icons.visibility_off),
              onPressed: () => setState(() => _hide = !_hide),
            ),
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(_error!, style: const TextStyle(color: Colors.red)),
          ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Sign in'),
        ),
        if (_owner)
          TextButton(
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const RegisterScreen())),
            child: const Text('Register a new business'),
          ),
      ],
    );
  }
}

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});
  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _email = TextEditingController();
  final _pass = TextEditingController();
  bool _busy = false;
  String? _msg;

  @override
  void dispose() {
    _email.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _go() async {
    if (_pass.text.length < 8) {
      setState(() => _msg = 'Use a password of at least 8 characters.');
      return;
    }
    setState(() {
      _busy = true;
      _msg = null;
    });
    final err = await context.read<AuthService>().registerOwner(_email.text.trim().toLowerCase(), _pass.text);
    if (!mounted) return;
    if (err == null) {
      Navigator.pop(context); // the auth gate now shows business setup
    } else {
      setState(() {
        _busy = false;
        _msg = err;
      });
    }
  }

  @override
  Widget build(BuildContext context) => _Shell(
        title: 'Register your business',
        appBar: AppBar(title: const Text('New owner account')),
        children: [
          const Text('Only the owner registers a workspace. Workers are added later from the Team tab.'),
          const SizedBox(height: 16),
          TextField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(labelText: 'Owner email'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _pass,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Password (8+ characters)'),
          ),
          if (_msg != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_msg!)),
          const SizedBox(height: 20),
          FilledButton(onPressed: _busy ? null : _go, child: const Text('Continue')),
        ],
      );
}

class BusinessSetupScreen extends StatefulWidget {
  const BusinessSetupScreen({super.key});
  @override
  State<BusinessSetupScreen> createState() => _BusinessSetupScreenState();
}

class _BusinessSetupScreenState extends State<BusinessSetupScreen> {
  final _name = TextEditingController();
  final _owner = TextEditingController();
  final _loc = TextEditingController();
  final _tin = TextEditingController();
  final _phone = TextEditingController();
  final _email = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _owner.dispose();
    _loc.dispose();
    _tin.dispose();
    _phone.dispose();
    _email.dispose();
    super.dispose();
  }

  String? _n(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();

  Future<void> _save() async {
    if (_name.text.trim().isEmpty || _owner.text.trim().isEmpty) {
      setState(() => _error = 'Business name and your name are required.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await context.read<AuthService>().createBusiness(
          name: _name.text,
          ownerName: _owner.text,
          location: _n(_loc),
          tin: _n(_tin),
          phone: _n(_phone),
          email: _n(_email),
        );
    if (mounted) {
      setState(() {
        _busy = false;
        _error = err;
      });
    }
  }

  @override
  Widget build(BuildContext context) => _Shell(
        title: 'Set up your business',
        children: [
          const Text('These details appear on receipts, invoices, dashboards and printed labels.'),
          const SizedBox(height: 16),
          TextField(controller: _name, decoration: const InputDecoration(labelText: 'Business name *')),
          const SizedBox(height: 12),
          TextField(controller: _owner, decoration: const InputDecoration(labelText: 'Your full name *')),
          const SizedBox(height: 12),
          TextField(controller: _loc, decoration: const InputDecoration(labelText: 'Location')),
          const SizedBox(height: 12),
          TextField(controller: _tin, decoration: const InputDecoration(labelText: 'TIN (Tax Identification Number)')),
          const SizedBox(height: 12),
          TextField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(labelText: 'Contact phone'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(labelText: 'Business email'),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
          const SizedBox(height: 20),
          FilledButton(onPressed: _busy ? null : _save, child: const Text('Create workspace')),
          TextButton(onPressed: () => context.read<AuthService>().signOut(), child: const Text('Cancel')),
        ],
      );
}
