import 'dart:convert';

/// Describes one synced table. The same spec drives: local CREATE TABLE, push (local -> Supabase)
/// and pull (Supabase -> local) value conversion. Keep it in step with supabase/migrations.
class TableSpec {
  TableSpec(
    this.name,
    this.columns, {
    this.scopeCol = 'business_id',
    this.push = true,
    this.appendOnly = false,
    this.bools = const {},
    this.jsons = const {},
    this.indexes = const [],
  });

  final String name;
  final Map<String, String> columns; // column -> SQLite declaration
  final String scopeCol; // which column holds the business id
  final bool push; // can this device write to it?
  final bool appendOnly; // rows are immutable after insert (no conflicts possible)
  final Set<String> bools; // INTEGER 0/1 locally, boolean on server
  final Set<String> jsons; // TEXT locally, jsonb on server
  final List<String> indexes; // e.g. 'product_id' or 'a,b'

  static const _timestamps = {'created_at', 'updated_at', 'deleted_at', 'server_updated_at'};

  List<String> ddl() => [
        'CREATE TABLE IF NOT EXISTS $name ('
            '${columns.entries.map((e) => '${e.key} ${e.value}').join(', ')}'
            '${push ? ', dirty INTEGER NOT NULL DEFAULT 0' : ''})',
        if (push) 'CREATE INDEX IF NOT EXISTS ${name}_dirty ON $name(dirty) WHERE dirty = 1',
        for (final ix in indexes)
          'CREATE INDEX IF NOT EXISTS ${name}_${ix.replaceAll(RegExp(r'[, ]+'), '_')} ON $name($ix)',
      ];

  /// Server JSON -> local row.
  Map<String, Object?> fromServer(Map<String, dynamic> r) {
    final out = <String, Object?>{};
    for (final c in columns.keys) {
      if (!r.containsKey(c)) continue;
      Object? v = r[c];
      if (v != null) {
        if (bools.contains(c)) {
          v = (v == true) ? 1 : 0;
        } else if (jsons.contains(c)) {
          v = v is String ? v : jsonEncode(v);
        } else if (_timestamps.contains(c)) {
          v = DateTime.parse(v as String).toUtc().toIso8601String();
        }
      }
      out[c] = v;
    }
    return out;
  }

  /// Local row -> JSON for upsert. (server_updated_at is server-owned; dirty is local-only.)
  Map<String, Object?> toServer(Map<String, Object?> row) {
    final out = <String, Object?>{};
    for (final c in columns.keys) {
      if (c == 'server_updated_at' || !row.containsKey(c)) continue;
      Object? v = row[c];
      if (v != null) {
        if (bools.contains(c)) {
          v = (v == 1 || v == true);
        } else if (jsons.contains(c)) {
          v = v is String ? jsonDecode(v) : v;
        }
      }
      out[c] = v;
    }
    return out;
  }
}

Map<String, String> _std([Map<String, String> extra = const {}]) => {
      ...extra,
      'created_at': 'TEXT NOT NULL',
      'updated_at': 'TEXT NOT NULL',
      'deleted_at': 'TEXT',
      'server_updated_at': 'TEXT',
    };

Map<String, String> _append([Map<String, String> extra = const {}]) => {
      ...extra,
      'created_at': 'TEXT NOT NULL',
      'server_updated_at': 'TEXT',
    };

const _pk = 'TEXT PRIMARY KEY';
const _biz = 'TEXT NOT NULL';

final kBusinesses = TableSpec('businesses', _std({
  'id': _pk, 'code': 'TEXT', 'name': 'TEXT NOT NULL', 'logo_url': 'TEXT', 'location': 'TEXT',
  'tin': 'TEXT', 'phone': 'TEXT', 'email': 'TEXT', 'currency': "TEXT NOT NULL DEFAULT 'UGX'",
}), scopeCol: 'id');

final kProfiles = TableSpec('profiles', _std({
  'id': _pk, 'business_id': _biz, 'username': 'TEXT NOT NULL', 'full_name': 'TEXT NOT NULL',
  'role': 'TEXT NOT NULL', 'status': "TEXT NOT NULL DEFAULT 'active'",
  'permissions': "TEXT NOT NULL DEFAULT '{}'", 'session_epoch': 'INTEGER NOT NULL DEFAULT 0',
}), push: false, jsons: {'permissions'});

final kCustomers = TableSpec('customers', _std({
  'id': _pk, 'business_id': _biz, 'name': 'TEXT NOT NULL', 'phone': 'TEXT', 'nin': 'TEXT', 'address': 'TEXT',
}), indexes: ['name']);

final kProducts = TableSpec('products', _std({
  'id': _pk, 'business_id': _biz, 'name': 'TEXT NOT NULL', 'barcode': 'TEXT', 'category': 'TEXT',
  'base_unit': 'TEXT NOT NULL', 'cost_per_base': 'REAL NOT NULL DEFAULT 0',
  'reorder_micro': 'INTEGER NOT NULL DEFAULT 0', 'expiry_date': 'TEXT',
  'track_stock': 'INTEGER NOT NULL DEFAULT 1', 'is_active': 'INTEGER NOT NULL DEFAULT 1',
}), bools: {'track_stock', 'is_active'}, indexes: ['barcode', 'name']);

final kProductUnits = TableSpec('product_units', _std({
  'id': _pk, 'business_id': _biz, 'product_id': 'TEXT NOT NULL', 'name': 'TEXT NOT NULL',
  'factor_micro': 'INTEGER NOT NULL', 'price': 'INTEGER NOT NULL',
  'allow_fraction': 'INTEGER NOT NULL DEFAULT 0', 'is_default': 'INTEGER NOT NULL DEFAULT 0',
}), bools: {'allow_fraction', 'is_default'}, indexes: ['product_id']);

final kSales = TableSpec('sales', _std({
  'id': _pk, 'business_id': _biz, 'receipt_no': 'TEXT NOT NULL', 'cashier_id': 'TEXT NOT NULL',
  'customer_id': 'TEXT', 'subtotal': 'INTEGER NOT NULL', 'discount': 'INTEGER NOT NULL DEFAULT 0',
  'total': 'INTEGER NOT NULL', 'total_cost': 'INTEGER NOT NULL DEFAULT 0',
  'status': "TEXT NOT NULL DEFAULT 'completed'", 'void_reason': 'TEXT', 'voided_by': 'TEXT',
}), indexes: ['created_at']);

final kSaleItems = TableSpec('sale_items', _append({
  'id': _pk, 'business_id': _biz, 'sale_id': 'TEXT NOT NULL', 'product_id': 'TEXT NOT NULL',
  'unit_id': 'TEXT', 'product_name': 'TEXT NOT NULL', 'unit_name': 'TEXT NOT NULL',
  'qty_micro': 'INTEGER NOT NULL', 'base_qty_micro': 'INTEGER NOT NULL', 'unit_price': 'INTEGER NOT NULL',
  'line_total': 'INTEGER NOT NULL', 'line_cost': 'INTEGER NOT NULL',
}), appendOnly: true, indexes: ['sale_id']);

final kSalePayments = TableSpec('sale_payments', _append({
  'id': _pk, 'business_id': _biz, 'sale_id': 'TEXT NOT NULL', 'method': 'TEXT NOT NULL',
  'amount': 'INTEGER NOT NULL', 'reference': 'TEXT',
}), appendOnly: true, indexes: ['sale_id']);

final kStockMovements = TableSpec('stock_movements', _append({
  'id': _pk, 'business_id': _biz, 'product_id': 'TEXT NOT NULL', 'kind': 'TEXT NOT NULL',
  'qty_micro': 'INTEGER NOT NULL', 'unit_cost': 'REAL', 'ref_id': 'TEXT', 'note': 'TEXT', 'created_by': 'TEXT',
}), appendOnly: true, indexes: ['product_id']);

final kCreditEntries = TableSpec('credit_entries', _append({
  'id': _pk, 'business_id': _biz, 'customer_id': 'TEXT NOT NULL', 'sale_id': 'TEXT',
  'kind': 'TEXT NOT NULL', 'amount': 'INTEGER NOT NULL', 'due_date': 'TEXT', 'note': 'TEXT', 'created_by': 'TEXT',
}), appendOnly: true, indexes: ['customer_id']);

final kSpecialOrders = TableSpec('special_orders', _std({
  'id': _pk, 'business_id': _biz, 'order_no': 'TEXT NOT NULL', 'customer_name': 'TEXT NOT NULL',
  'customer_phone': 'TEXT', 'description': 'TEXT NOT NULL', 'total_price': 'INTEGER NOT NULL DEFAULT 0',
  'deposit_paid': 'INTEGER NOT NULL DEFAULT 0', 'status': "TEXT NOT NULL DEFAULT 'pending'",
  'due_date': 'TEXT', 'created_by': 'TEXT',
}));

final kAuditLogs = TableSpec('audit_logs', _append({
  'id': _pk, 'business_id': _biz, 'user_id': 'TEXT', 'action': 'TEXT NOT NULL', 'entity': 'TEXT',
  'entity_id': 'TEXT', 'details': 'TEXT',
}), appendOnly: true, jsons: {'details'});

/// Order matters: parents before children, so pushes never hit a foreign-key wall.
final List<TableSpec> kTables = [
  kBusinesses, kProfiles, kCustomers, kProducts, kProductUnits, kSales, kSaleItems,
  kSalePayments, kStockMovements, kCreditEntries, kSpecialOrders, kAuditLogs,
];
