import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../auth/auth_service.dart';
import '../../core/util.dart';
import '../../data/sync_service.dart';
import '../inventory/inventory_screen.dart';
import '../pos/pos_screen.dart';
import '../team/team_screen.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _Tab {
  const _Tab(this.icon, this.label, this.page);
  final IconData icon;
  final String label;
  final Widget page;
}

class _HomeShellState extends State<HomeShell> {
  int _i = 0;

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();
    final s = auth.session!;
    final tabs = <_Tab>[
      const _Tab(Icons.dashboard_outlined, 'Home', _Dashboard()),
      if (s.can('make_sales')) const _Tab(Icons.point_of_sale, 'Sell', PosScreen()),
      const _Tab(Icons.inventory_2_outlined, 'Stock', InventoryScreen()),
      if (s.isOwner) const _Tab(Icons.groups_outlined, 'Team', TeamScreen()),
    ];
    if (_i >= tabs.length) _i = 0;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(s.businessName, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
            Text(
              '${s.fullName} · ${s.isOwner ? 'Owner' : 'Worker'}',
              style: const TextStyle(fontSize: 12, color: Colors.white70),
            ),
          ],
        ),
        actions: [
          _SyncBadge(sync: auth.sync!),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'out') auth.signOut();
              if (v == 'about') {
                showAboutDialog(
                  context: context,
                  applicationName: 'SSEDDUME POS',
                  applicationVersion: '0.1.0',
                  applicationLegalese: 'by ${AppConfig.platformName}',
                );
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'about', child: Text('About')),
              PopupMenuItem(value: 'out', child: Text('Sign out')),
            ],
          ),
        ],
      ),
      body: tabs[_i].page,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _i,
        onDestinationSelected: (v) => setState(() => _i = v),
        destinations: [for (final t in tabs) NavigationDestination(icon: Icon(t.icon), label: t.label)],
      ),
    );
  }
}

class _SyncBadge extends StatelessWidget {
  const _SyncBadge({required this.sync});
  final SyncService sync;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: sync,
        builder: (context, _) {
          final (icon, color, tip) = switch (sync.state) {
            SyncState.syncing => (Icons.cloud_sync, Colors.white, 'Syncing...'),
            SyncState.offline => (Icons.cloud_off, Colors.amber, 'Offline - saved on this phone'),
            SyncState.error => (Icons.cloud_off, Colors.redAccent, 'Sync problem: ${sync.lastError ?? ''}'),
            SyncState.idle => (Icons.cloud_done, Colors.lightGreenAccent, 'All synced'),
          };
          final n = sync.pending;
          return Tooltip(
            message: tip,
            child: InkWell(
              onTap: sync.syncNow,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: [
                    Icon(icon, color: color),
                    if (n > 0)
                      Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: Text(
                          '$n',
                          style: const TextStyle(color: Colors.amber, fontWeight: FontWeight.bold),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      );
}

// ---------------------------------------------------------------- dashboard (computed locally => works offline)

class _Dashboard extends StatelessWidget {
  const _Dashboard();

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();
    final s = auth.session!;
    return ListenableBuilder(
      listenable: auth.db!,
      builder: (context, _) {
        final d = auth.sales!.todaySummary();
        Widget tile(String label, String value, IconData icon, {Color? color}) => Card(
              child: ListTile(
                leading: Icon(icon, color: color ?? const Color(0xFF00A884)),
                title: Text(label),
                trailing: Text(value, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
              ),
            );
        return ListView(
          padding: const EdgeInsets.only(top: 8, bottom: 24),
          children: [
            tile("Today's sales (${d['count']})", fmtUgx(d['sales']!), Icons.receipt_long),
            if (s.can('view_profit')) tile('Gross profit today', fmtUgx(d['sales']! - d['cost']!), Icons.trending_up),
            tile('Cash received', fmtUgx(d['cash']!), Icons.payments_outlined),
            tile('Mobile money', fmtUgx(d['momo']!), Icons.phone_android),
            tile('Bank / card', fmtUgx(d['bank']!), Icons.credit_card),
            tile('Unpaid credit (all debtors)', fmtUgx(d['owed']!), Icons.menu_book_outlined, color: Colors.orange),
            if (s.can('view_profit')) tile('Stock value (at cost)', fmtUgx(d['stock_value']!), Icons.warehouse_outlined),
            if (s.isOwner)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.vpn_key_outlined),
                  title: const Text('Business code for workers'),
                  subtitle: const Text('Workers sign in with this code + their Worker ID'),
                  trailing: SelectableText(
                    s.businessCode,
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, letterSpacing: 2),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
