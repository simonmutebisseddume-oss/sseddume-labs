/// Permission keys the Owner can grant to a worker. Must match ALLOWED_PERMS in the worker-admin function
/// and the has_perm(...) checks in the SQL policies.
const Map<String, String> kPermissionLabels = {
  'make_sales': 'Make sales',
  'view_profit': 'View profit margins',
  'approve_credit': 'Approve credit sales',
  'edit_stock': 'Edit stock / restock',
  'manage_products': 'Add & edit products',
  'process_refunds': 'Process refunds & voids',
  'view_reports': 'View reports',
};

class UserSession {
  const UserSession({
    required this.userId,
    required this.businessId,
    required this.businessName,
    required this.businessCode,
    required this.username,
    required this.fullName,
    required this.role,
    required this.permissions,
    required this.epoch,
  });

  final String userId;
  final String businessId;
  final String businessName;
  final String businessCode;
  final String username;
  final String fullName;
  final String role;
  final Map<String, dynamic> permissions;
  final int epoch;

  bool get isOwner => role == 'owner';
  bool can(String perm) => isOwner || permissions[perm] == true;
}
