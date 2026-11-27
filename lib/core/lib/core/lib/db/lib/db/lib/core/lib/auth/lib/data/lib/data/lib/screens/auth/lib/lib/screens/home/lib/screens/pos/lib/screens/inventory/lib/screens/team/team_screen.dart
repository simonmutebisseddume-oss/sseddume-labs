import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../auth/auth_service.dart';
import '../../core/util.dart';
import '../../data/schema.dart';

class TeamScreen extends StatefulWidget {
  const TeamScreen({super.key});
  @override
  State<TeamScreen> createState() => _TeamScreenState();
}

class _TeamScreenState extends State<TeamScreen> {
  static const Map<String, String> _permLabels = {
    'make_sales': 'Make sales (POS)',
    'edit_stock': 'Restock & adjust stock',
    'manage_products': 'Create & edit products',
    'approve_credit': 'Approve credit sales',
    'view_profit': 'View profit & cost prices',
  };

  List> _loadMembers(AuthService auth) {
    final db = auth.db;
    final s = auth.session;
    if (db == null || s == null) return const [];
    return db
        .select(
          'SELECT * FROM business_users WHERE business_id = ? AND deleted_at IS NULL ORDER BY full_name COLLATE NOCASE',
          [s.businessId],
        )
        .map((r) => Map<String, Object?>.from(r))
        .toList();
  }

  Set<String> _parsePerms(Object? raw) {
    if (raw == null) return const {};
    if (raw is List) return raw.map((e) => '$e').toSet();
    final str = '$raw'.trim();
    if (str.isEmpty) return const {};
    try {
      final decoded = jsonDecode(str);
      if (decoded is List) return decoded.map((e) => '$e').toSet();
      if (decoded is Map) {
        return decoded.entries
            .where((e) => e.value == true || e.value == 1)
            .map((e) => '${e.key}')
            .toSet();
      }
    } catch (_) {
      return str
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toSet();
    }
    return const {};
  }

  void _logAudit(AuthService auth, String action, String? entityId, Map<String, Object?> details) {
    final db = auth.db;
    final s = auth.session;
    if (db == null || s == null) return;
    final now = nowIso();
    db.upsert(
      kAuditLogs,
      {
        'id': newId(),
        'business_id': s.businessId,
        'user_id': s.userId,
        'action': action,
        'entity': 'team_member',
        'entity_id': entityId,
        'details': jsonEncode(details),
        'created_at': now,
      },
      dirty: true,
    );
  }

  Future<void> _openAddWorkerDialog(BuildContext context, AuthService auth) async {
    final nameCtrl = TextEditingController();
    final workerIdCtrl = TextEditingController();
    final passCtrl = TextEditingController();
    final perms = <String>{'make_sales', 'edit_stock'};
    String? err;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModal) => AlertDialog(
          title: const Text('Add worker'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(labelText: 'Full name *'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: workerIdCtrl,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'Worker ID *',
                    helperText: 'Example: john or cashier1',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: passCtrl,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Password (6+ chars) *',
                  ),
                ),
                const SizedBox(height: 12),
                const Text('Permissions', style: TextStyle(fontWeight: FontWeight.w600)),
                for (final entry in _permLabels.entries)
                  CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: perms.contains(entry.key),
                    title: Text(entry.value),
                    onChanged: (checked) {
                      setModal(() {
                        if (checked == true) {
                          perms.add(entry.key);
                        } else {
                          perms.remove(entry.key);
                        }
                      });
                    },
                  ),
                if (err != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(err!, style: const TextStyle(color: Colors.red)),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                final fullName = nameCtrl.text.trim();
                final workerId = workerIdCtrl.text.trim().toLowerCase();
                final password = passCtrl.text;
                if (fullName.isEmpty || workerId.isEmpty) {
                  setModal(() => err = 'Full name and Worker ID are required.');
                  return;
                }
                if (password.length < 6) {
                  setModal(() => err = 'Password must be at least 6 characters.');
                  return;
                }
                final s = auth.session!;
                final db = auth.db!;
                final existing = db.select(
                  'SELECT id FROM business_users WHERE business_id = ? AND LOWER(worker_code) = ? AND deleted_at IS NULL',
                  [s.businessId, workerId],
                );
                if (existing.isNotEmpty) {
                  setModal(() => err = 'That Worker ID is already used in this business.');
                  return;
                }

                final memberId = newId();
                final now = nowIso();
                db.tx(() {
                  db.upsert(
                    kBusinessUsers,
                    {
                      'id': memberId,
                      'business_id': s.businessId,
                      'full_name': fullName,
                      'worker_code': workerId,
                      'login_id': auth.workerLoginId(s.businessCode, workerId),
                      'role': 'worker',
                      'permissions': jsonEncode(perms.toList()),
                      'is_active': 1,
                      'deleted_at': null,
                      'created_at': now,
                      'updated_at': now,
                    },
                    dirty: true,
                  );
                  _logAudit(auth, 'team.worker_add', memberId, {
                    'name': fullName,
                    'worker_code': workerId,
                    'permissions': perms.toList(),
                  });
                });
                Navigator.pop(ctx);
              },
              child: const Text('Save worker'),
            ),
          ],
        ),
      ),
    );

    nameCtrl.dispose();
    workerIdCtrl.dispose();
    passCtrl.dispose();
  }

  Future<void> _openPermissionsDialog(
    BuildContext context,
    AuthService auth,
    Map<String, Object?> member,
  ) async {
    final perms = _parsePerms(member['permissions']).toSet();
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModal) => AlertDialog(
          title: Text('Permissions · ${member['full_name'] ?? 'Worker'}'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final entry in _permLabels.entries)
                  CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: perms.contains(entry.key),
                    title: Text(entry.value),
                    onChanged: (checked) {
                      setModal(() {
                        if (checked == true) {
                          perms.add(entry.key);
                        } else {
                          perms.remove(entry.key);
                        }
                      });
                    },
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                final id = member['id'] as String;
                auth.db!.tx(() {
                  auth.db!.patch(kBusinessUsers, id, {
                    'permissions': jsonEncode(perms.toList()),
                  });
                  _logAudit(auth, 'team.permissions_update', id, {
                    'name': member['full_name'],
                    'permissions': perms.toList(),
                  });
                });
                Navigator.pop(ctx);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  void _toggleActive(AuthService auth, Map<String, Object?> member) {
    final id = member['id'] as String;
    final currentlyActive = (member['is_active'] ?? 1) == 1;
    final nextActive = currentlyActive ? 0 : 1;
    auth.db!.tx(() {
      auth.db!.patch(kBusinessUsers, id, {'is_active': nextActive});
      _logAudit(auth, nextActive == 1 ? 'team.activate' : 'team.suspend', id, {
        'name': member['full_name'],
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();
    final s = auth.session!;

    if (!s.isOwner) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('Only the business owner can manage team members.'),
        ),
      );
    }

    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openAddWorkerDialog(context, auth),
        icon: const Icon(Icons.person_add_alt_1),
        label: const Text('Add worker'),
      ),
      body: ListenableBuilder(
        listenable: auth.db!,
        builder: (context, _) {
          final members = _loadMembers(auth);
          if (members.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('No workers added yet.\nTap "Add worker" to create a worker login.'),
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.only(top: 8, bottom: 90),
            itemCount: members.length,
            itemBuilder: (_, i) {
              final m = members[i];
              final role = '${m['role'] ?? 'worker'}';
              final isMemberOwner = role == 'owner';
              final active = (m['is_active'] ?? 1) == 1;
              final workerCode = '${m['worker_code'] ?? ''}';
              final perms = _parsePerms(m['permissions']);

              return Card(
                child: ListTile(
                  leading: CircleAvatar(
                    child: Icon(isMemberOwner ? Icons.admin_panel_settings : Icons.badge_outlined),
                  ),
                  title: Text(
                    '${m['full_name'] ?? 'Unnamed'}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    isMemberOwner
                        ? 'Owner · Full access'
                        : '${workerCode.isEmpty ? '' : 'ID: $workerCode · '}${active ? 'Active' : 'Suspended'} · ${perms.length} perms',
                  ),
                  trailing: isMemberOwner
                      ? const Chip(label: Text('Owner'))
                      : PopupMenuButton<String>(
                          onSelected: (choice) {
                            if (choice == 'perms') {
                              _openPermissionsDialog(context, auth, m);
                            } else if (choice == 'toggle') {
                              _toggleActive(auth, m);
                            }
                          },
                          itemBuilder: (_) => [
                            const PopupMenuItem(value: 'perms', child: Text('Edit permissions')),
                            PopupMenuItem(
                              value: 'toggle',
                              child: Text(active ? 'Suspend worker' : 'Activate worker'),
                            ),
                          ],
                        ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
