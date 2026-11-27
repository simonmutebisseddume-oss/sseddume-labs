import 'dart:convert';

import 'package:intl/intl.dart';

import '../core/session.dart';
import '../core/units.dart';
import '../core/util.dart';
import 'db.dart';
import 'schema.dart';

// ====================================================================== models

class ProductUnit {
  ProductUnit({
    required this.id,
    required this.name,
    required this.factorMicro,
    required this.price,
    required this.allowFraction,
    required this.isDefault,
  });
  final String id;
  final String name;
  final int factorMicro; // base units in ONE of this unit, x1e6
  final int price; // UGX per ONE of this unit
  final bool allowFraction;
  final bool isDefault;

  factory ProductUnit.fromRow(Map<String, Object?> r) => ProductUnit(
        id: r['id'] as String,
        name: r['name'] as String,
        factorMicro: r['factor_micro'] as int,
        price: r['price'] as int,
        allowFraction: r['allow_fraction'] == 1,
        isDefault: r['is_default'] == 1,
      );
}

class Product {
  Product({
    required this.id,
    required this.name,
    required this.baseUnit,
    required this.costPerBase,
    required this.reorderMicro,
    required this.stockMicro,
    required this.units,
    this.barcode,
    this.category,
  });
  final String id;
  final String name;
  final String? barcode;
  final String? category;
  final String baseUnit;
  final double costPerBase;
  final int reorderMicro;
  final int stockMicro; // derived: SUM(stock_movements)
  final List<ProductUnit> units;

  ProductUnit get defaultUnit => units.firstWhere((u) => u.isDefault, orElse: () => units.first);
  bool get lowStock => reorderMicro > 0 && stockMicro <= reorderMicro;
  String get stockText => '${formatMicro(stockMicro)} $baseUnit';
}

class Customer {
  Customer(this.id, this.name, this.phone);
  final String id;
  final String name;
  final String? phone;
}

class CartLine {
  CartLine(this.product, this.unit, this.qtyMicro);
  final Product product;
  final ProductUnit unit;
  final int qtyMicro; // in the SELLING unit, x1e6

  int get baseMicro => toBaseMicro(qtyMicro, unit.factorMicro);
  int get total => lineTotalUgx(qtyMicro, unit.price);
  int get cost => lineCostUgx(baseMicro, product.costPerBase);
  String get qtyText => '${formatMicro(qtyMicro)} ${unit.name}';
}

class PaymentInput {
  PaymentInput(this.method, this.amount, [this.reference]);
  final String method; // cash | mtn_momo | airtel_money | bank_card | credit
  final int amount;
  final String? reference;
}

const Map<String, String> kPaymentLabels = {
  'cash': 'Cash',
  'mtn_momo': 'MTN MoMo',
  'airtel_money': 'Airtel Money',
  'bank_card': 'Bank / Card',
  'credit': 'Store credit (Debtor)',
};

// drafts used by the product form
class UnitDraft {
  UnitDraft({
    this.id,
    required this.name,
    required this.factorMicro,
    required this.price,
    this.allowFraction = false,
    this.isDefault = false,
  });
  String? id;
  String name;
  int factorMicro;
  int price;
  bool allowFraction;
  bool isDefault;
}

class ProductDraft {
  ProductDraft({
    this.id,
    required this.name,
    this.category,
    required this.baseUnit,
    required this.barcode,
    required this.costPerBase,
    this.reorderMicro = 0,
    this.openingStockMicro = 0,
    required this.units,
  });
  String? id;
  String name;
  String? category;
  String baseUnit;
  String barcode;
  double costPerBase;
  int reorderMicro;
  int openingStockMicro;
  List<UnitDraft> units;
}

// ====================================================================== base

abstract class _Repo {
  _Repo(this.db, this.s);
  final AppDb db;
  final UserSession s;

  Map<String, Object?> _row(Map<String, Object?> data, {bool append = false}) {
    final now = nowIso();
    return {
      'id': newId(),
      'business_id': s.businessId,
      'created_at': now,
      if (!append) 'updated_at': now,
      ...data,
    };
  }

  void audit(String action, String entity, String? entityId, [Map<String, Object?>? details]) {
    db.upsert(
      kAuditLogs,
      _row({
        'user_id': s.userId,
        'action': action,
        'entity': entity,
        'entity_id': entityId,
        'details': details == null ? null : jsonEncode(details),
      }, append: true),
      dirty: true,
    );
  }

  void _movement(String productId, String kind, int qtyMicro, double? unitCost, {String? refId, String? note}) {
    db.upsert(
      kStockMovements,
      _row({
        'product_id': productId,
        'kind': kind,
        'qty_micro': qtyMicro,
        'unit_cost': unitCost,
        'ref_id': refId,
        'note': note,
        'created_by': s.userId,
      }, append: true),
      dirty: true,
    );
  }
}

// ====================================================================== catalog / stock

class CatalogRepo extends _Repo {
  CatalogRepo(super.db, super.s);

  List<Product> products({String query = ''}) {
    final q = query.trim();
    final rows = db.select('''
      SELECT p.*, COALESCE((SELECT SUM(m.qty_micro) FROM stock_movements m WHERE m.product_id = p.id), 0) AS stock_micro
      FROM products p
      WHERE p.deleted_at IS NULL AND p.is_active = 1
        AND (? = '' OR p.name LIKE ? OR p.barcode = ? OR p.category LIKE ?)
      ORDER BY p.name COLLATE NOCASE
    ''', [q, '%$q%', q, '%$q%']);
    return _hydrate(rows.map((r) => Map<String, Object?>.from(r)).toList());
  }

  Product? byBarcode(String code) {
    final rows = db.select('''
      SELECT p.*, COALESCE((SELECT SUM(m.qty_micro) FROM stock_movements m WHERE m.product_id = p.id), 0) AS stock_micro
      FROM products p WHERE p.barcode = ? AND p.deleted_at IS NULL AND p.is_active = 1 LIMIT 1
    ''', [code]);
    if (rows.isEmpty) return null;
    return _hydrate([Map<String, Object?>.from(rows.first)]).first;
  }

  List<Product> _hydrate(List> rows) {
    final units = <String, List<ProductUnit>>{};
    for (final u in db.select('SELECT * FROM product_units WHERE deleted_at IS NULL ORDER BY factor_micro')) {
      units.putIfAbsent(u['product_id'] as String, () => []).add(ProductUnit.fromRow(Map<String, Object?>.from(u)));
    }
    return [
      for (final r in rows)
        if (units[r['id']]?.isNotEmpty ?? false)
          Product(
            id: r['id'] as String,
            name: r['name'] as String,
            barcode: r['barcode'] as String?,
            category: r['category'] as String?,
            baseUnit: r['base_unit'] as String,
            costPerBase: (r['cost_per_base'] as num).toDouble(),
            reorderMicro: r['reorder_micro'] as int,
            stockMicro: r['stock_micro'] as int,
            units: units[r['id']]!,
          ),
    ];
  }

  bool barcodeTaken(String code, {String? exceptId}) {
    final r = db.select('SELECT id FROM products WHERE barcode = ? AND deleted_at IS NULL', [code]);
    return r.any((x) => x['id'] != exceptId);
  }

  void saveProduct(ProductDraft d) {
    if (d.units.isEmpty) throw ArgumentError('Add at least one selling unit');
    if (!d.units.any((u) => u.isDefault)) d.units.first.isDefault = true;
    db.tx(() {
      final isNew = d.id == null;
      final id = d.id ?? newId();
      final fields = {
        'name': d.name.trim(),
        'barcode': d.barcode,
        'category': (d.category ?? '').trim().isEmpty ? null : d.category!.trim(),
        'base_unit': d.baseUnit,
        'cost_per_base': d.costPerBase,
        'reorder_micro': d.reorderMicro,
      };
      if (isNew) {
        db.upsert(
          kProducts,
          _row({'id': id, 'deleted_at': null, 'track_stock': 1, 'is_active': 1, ...fields}),
          dirty: true,
        );
      } else {
        db.patch(kProducts, id, fields);
      }

      final existing = db
          .select('SELECT id FROM product_units WHERE product_id = ? AND deleted_at IS NULL', [id])
          .map((r) => r['id'] as String)
          .toSet();
      final keep = <String>{};
      for (final u in d.units) {
        final uid = u.id ?? newId();
        keep.add(uid);
        final uf = {
          'name': u.name.trim(),
          'factor_micro': u.factorMicro,
          'price': u.price,
          'allow_fraction': u.allowFraction ? 1 : 0,
          'is_default': u.isDefault ? 1 : 0,
        };
        if (existing.contains(uid)) {
          db.patch(kProductUnits, uid, uf);
        } else {
          db.upsert(kProductUnits, _row({'id': uid, 'product_id': id, 'deleted_at': null, ...uf}), dirty: true);
        }
      }
      for (final gone in existing.difference(keep)) {
        db.patch(kProductUnits, gone, {'deleted_at': nowIso()});
      }

      if (isNew && d.openingStockMicro > 0) {
        _movement(id, 'purchase', d.openingStockMicro, d.costPerBase, note: 'Opening stock');
      }
      audit(isNew ? 'product.create' : 'product.update', 'product', id, {'name': d.name});
    });
  }

  /// Stock-in. If [totalCostUgx] is given, the product's cost is re-averaged (weighted average).
  void restock(Product p, int addBaseMicro, {int? totalCostUgx, String? note}) {
    if (addBaseMicro <= 0) throw ArgumentError('Quantity must be more than zero');
    db.tx(() {
      double? unitCost;
      if (totalCostUgx != null && totalCostUgx > 0) {
        unitCost = costPerBase(packCostUgx: totalCostUgx, packBaseMicro: addBaseMicro);
        final avg = weightedAvgCost(
          oldStockMicro: p.stockMicro,
          oldCost: p.costPerBase,
          addMicro: addBaseMicro,
          addCost: unitCost,
        );
        db.patch(kProducts, p.id, {'cost_per_base': avg});
      }
      _movement(p.id, 'purchase', addBaseMicro, unitCost ?? p.costPerBase, note: note ?? 'Restock');
      audit('stock.in', 'product', p.id, {'qty_micro': addBaseMicro, 'cost': totalCostUgx});
    });
  }
}

// ====================================================================== sales

class SalesRepo extends _Repo {
  SalesRepo(super.db, super.s);

  List<Customer> customers([String q = '']) => db
      .select(
        "SELECT id, name, phone FROM customers WHERE deleted_at IS NULL AND (name LIKE ? OR phone LIKE ?) ORDER BY name COLLATE NOCASE LIMIT 50",
        ['%$q%', '%$q%'],
      )
      .map((r) => Customer(r['id'] as String, r['name'] as String, r['phone'] as String?))
      .toList();

  Customer addCustomer(String name, String? phone, String? nin) {
    final row = _row({'name': name.trim(), 'phone': phone, 'nin': nin, 'address': null, 'deleted_at': null});
    db.upsert(kCustomers, row, dirty: true);
    return Customer(row['id'] as String, name.trim(), phone);
  }

  /// Everything below happens in ONE local transaction: a sale is either fully recorded
  /// (sale + items + payments + stock deductions + credit ledger + audit) or not at all.
  ({String saleId, String receiptNo}) completeSale({
    required List<CartLine> lines,
    required int discount,
    required List<PaymentInput> payments,
    Customer? customer,
    DateTime? creditDue,
  }) {
    if (!s.can('make_sales')) throw StateError('You do not have permission to make sales.');
    if (lines.isEmpty) throw ArgumentError('The cart is empty');
    final subtotal = lines.fold<int>(0, (a, l) => a + l.total);
    if (discount < 0 || discount > subtotal) throw ArgumentError('Invalid discount');
    final total = subtotal - discount;
    if (total <= 0) throw ArgumentError('Total must be more than zero');
    final paid = payments.fold<int>(0, (a, p) => a + p.amount);
    if (paid != total) throw ArgumentError('Payments (${fmtUgx(paid)}) must equal the total (${fmtUgx(total)})');
    final credit = payments.where((p) => p.method == 'credit').fold<int>(0, (a, p) => a + p.amount);
    if (credit > 0) {
      if (!s.can('approve_credit')) throw StateError('You do not have permission to approve credit.');
      if (customer == null) throw ArgumentError('Choose a customer for credit sales');
    }

    return db.tx(() {
      final saleId = newId();
      final now = DateTime.now();
      final receiptNo =
          '${DateFormat('yyMMdd').format(now)}-${db.deviceCode}-${db.nextSeq('receipt').toString().padLeft(4, '0')}';

      db.upsert(
        kSales,
        _row({
          'id': saleId,
          'receipt_no': receiptNo,
          'cashier_id': s.userId,
          'customer_id': customer?.id,
          'subtotal': subtotal,
          'discount': discount,
          'total': total,
          'total_cost': lines.fold<int>(0, (a, l) => a + l.cost),
          'status': 'completed',
          'void_reason': null,
          'voided_by': null,
          'deleted_at': null,
        }),
        dirty: true,
      );

      for (final l in lines) {
        db.upsert(
          kSaleItems,
          _row({
            'sale_id': saleId,
            'product_id': l.product.id,
            'unit_id': l.unit.id,
            'product_name': l.product.name,
            'unit_name': l.unit.name,
            'qty_micro': l.qtyMicro,
            'base_qty_micro': l.baseMicro,
            'unit_price': l.unit.price,
            'line_total': l.total,
            'line_cost': l.cost,
          }, append: true),
          dirty: true,
        );
        _movement(l.product.id, 'sale', -l.baseMicro, l.product.costPerBase, refId: saleId);
      }

      for (final p in payments.where((p) => p.amount > 0)) {
        db.upsert(
          kSalePayments,
          _row({'sale_id': saleId, 'method': p.method, 'amount': p.amount, 'reference': p.reference}, append: true),
          dirty: true,
        );
      }

      if (credit > 0) {
        db.upsert(
          kCreditEntries,
          _row({
            'customer_id': customer!.id,
            'sale_id': saleId,
            'kind': 'charge',
            'amount': credit,
            'due_date': creditDue == null ? null : DateFormat('yyyy-MM-dd').format(creditDue),
            'note': 'Sale $receiptNo',
            'created_by': s.userId,
          }, append: true),
          dirty: true,
        );
      }

      audit('sale.create', 'sale', saleId, {'receipt': receiptNo, 'total': total});
      return (saleId: saleId, receiptNo: receiptNo);
    });
  }

  // ---- dashboard numbers (all computed locally => work offline)

  Map<String, int> todaySummary() {
    final start = DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day).toUtc().toIso8601String();
    final t = db.select(
      "SELECT COALESCE(SUM(total),0) AS sales, COALESCE(SUM(total_cost),0) AS cost, COUNT(*) AS n FROM sales WHERE status='completed' AND created_at >= ?",
      [start],
    ).first;
    final byMethod = <String, int>{};
    for (final r in db.select('''
      SELECT p.method, COALESCE(SUM(p.amount),0) AS amt FROM sale_payments p
      JOIN sales s ON s.id = p.sale_id WHERE s.status='completed' AND s.created_at >= ? GROUP BY p.method
    ''', [start])) {
      byMethod[r['method'] as String] = r['amt'] as int;
    }
    final owed = db
        .select("SELECT COALESCE(SUM(CASE kind WHEN 'charge' THEN amount ELSE -amount END),0) AS d FROM credit_entries")
        .first['d'] as int;
    final stockValue = db.select('''
      SELECT COALESCE(SUM(MAX(q,0) * p.cost_per_base / 1000000.0),0) AS v
      FROM products p JOIN (SELECT product_id, SUM(qty_micro) q FROM stock_movements GROUP BY product_id) m
      ON m.product_id = p.id WHERE p.deleted_at IS NULL
    ''').first['v'] as num;
    return {
      'sales': t['sales'] as int,
      'cost': t['cost'] as int,
      'count': t['n'] as int,
      'cash': byMethod['cash'] ?? 0,
      'momo': (byMethod['mtn_momo'] ?? 0) + (byMethod['airtel_money'] ?? 0),
      'bank': byMethod['bank_card'] ?? 0,
      'credit_today': byMethod['credit'] ?? 0,
      'owed': owed,
      'stock_value': stockValue.round(),
    };
  }
}
