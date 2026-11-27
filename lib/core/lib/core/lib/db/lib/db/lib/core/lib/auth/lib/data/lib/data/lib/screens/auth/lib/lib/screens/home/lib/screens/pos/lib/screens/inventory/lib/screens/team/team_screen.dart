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

  List> _loadProfiles(AuthService auth) {
    final db = auth.db;
    final s = auth.session;
    if (db == null || s == null) return const [];
    return db
        .select(
          'SELECT * FROM profiles WHERE business_id = ? AND deleted_at IS NULL ORDER BY full_name COLLATE NOCASE',
          [s.businessId],
        )
        .map((r) => Map<String, Object?>.from(r))
        .toList();
  }

  Map<String, bool> _parsePermMap(Object? raw) {
    final out = <String, bool>{for (final k in _permLabels.keys) k: false};
    if (raw == null) return out;
    dynamic decoded = raw;
    if (raw is String && raw.trim().isNotEmpty) {
      try {
        decoded = jsonDecode(raw);
      } catch (_) {
        for (final part in raw.split(',').map((e) => e.trim())) {
          if (out.containsKey(part)) out[part] = true;
        }
        return out;
      }
    }
    if (decoded is Map) {
      for (final k in out.keys) {
        final v = decoded[k];
        out[k] = v == true || v == 1;
      }
    } else if (decoded is List) {
      for (final item in decoded) {
        final key = '$item';
        if (out.containsKey(key)) out[key] = true;
      }
    }
    return out;
  }

  void _logAudit(AuthService auth, String action, String? entityId, Map<String, Object?> details) {
    final db = auth.db;
    final s = auth.session;
    if (db == null || s == null) return;
    db.upsert(
      kAuditLogs,
      {
        'id': newId(),
        'business_id': s.businessId,
        'user_id': s.userId,
        'action': action,
        'entity': 'profile',
        'entity_id': entityId,
        'details': jsonEncode(details),
        'created_at': nowIso(),
      },
      dirty: true,
    );
  }

  Future<void> _openPermissionsDialog(
    BuildContext context,
    AuthService auth,
    Map<String, Object?> member,
  ) async {
    final permMap = _parsePermMap(member['permissions']);
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModal) => AlertDialog(
          title: Text('Permissions · ${member['full_name'] ?? 'Team member'}'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final entry in _permLabels.entries)
                  CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: permMap[entry.key] ?? false,
                    title: Text(entry.value),
                    onChanged: (checked) {
                      setModal(() => permMap[entry.key] = checked == true);
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
                  auth.db!.patch(kProfiles, id, {
                    'permissions': jsonEncode(permMap),
                  });
                  _logAudit(auth, 'team.permissions_update', id, {
                    'name': member['full_name'],
                    'permissions': permMap,
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

  void _toggleStatus(AuthService auth, Map<String, Object?> member) {
    final id = member['id'] as String;
    final currentStatus = '${member['status'] ?? 'active'}';
    final nextStatus = currentStatus == 'active' ? 'suspended' : 'active';
    auth.db!.tx(() {
      auth.db!.patch(kProfiles, id, {'status': nextStatus});
      _logAudit(auth, nextStatus == 'active' ? 'team.activate' : 'team.suspend', id, {
        'name': member['full_name'],
        'status': nextStatus,
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

    return ListenableBuilder(
      listenable: auth.db!,
      builder: (context, _) {
        final members = _loadProfiles(auth);
        if (members.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text('No team profiles found yet.\nSync with Supabase or create worker accounts via auth.'),
            ),
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.only(top: 8, bottom: 24),
          itemCount: members.length,
          itemBuilder: (_, i) {
            final m = members[i];
            final role = '${m['role'] ?? 'worker'}';
            final isMemberOwner = role == 'owner';
            final status = '${m['status'] ?? 'active'}';
            final isActive = status == 'active';
            final username = '${m['username'] ?? ''}';
            final perms = _parsePermMap(m['permissions']);
            final enabledCount = perms.values.where((v) => v).length;

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
                      : '${username.isEmpty ? '' : '@$username · '}$status · $enabledCount perms',
                ),
                trailing: isMemberOwner
                    ? const Chip(label: Text('Owner'))
                    : PopupMenuButton<String>(
                        onSelected: (choice) {
                          if (choice == 'perms') {
                            _openPermissionsDialog(context, auth, m);
                          } else if (choice == 'toggle') {
                            _toggleStatus(auth, m);
                          }
                        },
                        itemBuilder: (_) => [
                          const PopupMenuItem(value: 'perms', child: Text('Edit permissions')),
                          PopupMenuItem(
                            value: 'toggle',
                            child: Text(isActive ? 'Suspend worker' : 'Activate worker'),
                          ),
                        ],
                      ),
              ),
            );
          },
        );
      },
    );
  }
}
