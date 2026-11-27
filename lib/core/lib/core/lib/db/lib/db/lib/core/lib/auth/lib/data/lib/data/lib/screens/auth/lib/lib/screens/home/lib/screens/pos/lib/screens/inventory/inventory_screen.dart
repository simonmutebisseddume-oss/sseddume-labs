import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../auth/auth_service.dart';
import '../../core/units.dart';
import '../../core/util.dart';
import '../../data/repos.dart';
import '../barcode/label_pdf.dart';
import '../barcode/scanner_page.dart';
import 'product_form.dart';

class InventoryScreen extends StatefulWidget {
  const InventoryScreen({super.key});
  @override
  State<InventoryScreen> createState() => _InventoryScreenState();
}

class _InventoryScreenState extends State<InventoryScreen> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();
    final s = auth.session!;
    final repo = auth.catalog!;
    final canManage = s.can('manage_products');
    final canStock = s.can('edit_stock');

    return Scaffold(
      floatingActionButton: canManage
          ? FloatingActionButton.extended(
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ProductFormPage())),
              icon: const Icon(Icons.add),
              label: const Text('New product'),
            )
          : null,
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    onChanged: (v) => setState(() => _q = v),
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: 'Search name, category or code',
                      isDense: true,
                    ),
                  ),
                ),
                if (canStock)
                  IconButton.filledTonal(
                    tooltip: 'Scan to restock',
                    icon: const Icon(Icons.qr_code_scanner),
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ScannerPage(
                          title: 'Stock-in: scan item',
                          onCode: (code) async {
                            final p = repo.byBarcode(code);
                            if (p == null) return 'Unknown code $code - add it as a new product';
                            await _restockDialog(context, repo, p);
                            return 'Restocked ${p.name}';
                          },
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: ListenableBuilder(
              listenable: auth.db!,
              builder: (context, _) {
                final list = repo.products(query: _q);
                if (list.isEmpty) {
                  return Center(
                    child: Text(
                      _q.isEmpty
                          ? 'No products yet.${canManage ? '\nTap "New product" to add one.' : ''}'
                          : 'No match',
                      textAlign: TextAlign.center,
                    ),
                  );
                }
                return ListView.builder(
                  padding: const EdgeInsets.only(bottom: 90),
                  itemCount: list.length,
                  itemBuilder: (_, i) {
                    final p = list[i];
                    return Card(
                      child: ListTile(
                        title: Text(p.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Text(
                          '${fmtUgx(p.defaultUnit.price)} / ${p.defaultUnit.name}'
                          '${s.can('view_profit') ? '  ·  cost ${p.costPerBase.toStringAsFixed(2)}/${p.baseUnit}' : ''}',
                        ),
                        trailing: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              p.stockText,
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: p.stockMicro <= 0 ? Colors.red : (p.lowStock ? Colors.orange : null),
                              ),
                            ),
                            if (p.lowStock) const Text('LOW', style: TextStyle(fontSize: 10, color: Colors.orange)),
                          ],
                        ),
                        onTap: () => _actions(context, repo, p, canManage, canStock),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  void _actions(BuildContext context, CatalogRepo repo, Product p, bool canManage, bool canStock) {
    final biz = context.read<AuthService>().session!.businessName;
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(p.name, style: Theme.of(context).textTheme.titleMedium),
              subtitle: Text('Code ${p.barcode ?? '-'}'),
            ),
            if (canStock)
              ListTile(
                leading: const Icon(Icons.add_box_outlined),
                title: const Text('Restock'),
                onTap: () {
                  Navigator.pop(sheet);
                  _restockDialog(context, repo, p);
                },
              ),
            if (canManage)
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Edit product & prices'),
                onTap: () {
                  Navigator.pop(sheet);
                  Navigator.push(context, MaterialPageRoute(builder: (_) => ProductFormPage(existing: p)));
                },
              ),
            ListTile(
              leading: const Icon(Icons.label_outline),
              title: const Text('Print labels'),
              onTap: () {
                Navigator.pop(sheet);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => LabelsPage(businessName: biz, items: [LabelItem.fromProduct(p)]),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _restockDialog(BuildContext context, CatalogRepo repo, Product p) async {
    final qty = TextEditingController();
    final cost = TextEditingController();
    var unit = p.units.last; // bulk unit first (kg / dozen)
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: Text('Restock ${p.name}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: qty,
                      autofocus: true,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'Quantity bought'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  DropdownButton<ProductUnit>(
                    initialValue: unit,
                    items: [for (final u in p.units) DropdownMenuItem(value: u, child: Text(u.name))],
                    onChanged: (u) => setS(() => unit = u!),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: cost,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Total cost paid (UGX, optional)',
                  helperText: 'Updates the average cost price',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                final q = parseMicro(qty.text);
                if (q == null || q <= 0) return;
                repo.restock(
                  p,
                  toBaseMicro(q, unit.factorMicro),
                  totalCostUgx: int.tryParse(cost.text.replaceAll(',', '')),
                );
                Navigator.pop(ctx);
              },
              child: const Text('Add stock'),
            ),
          ],
        ),
      ),
    );
    qty.dispose();
    cost.dispose();
  }
}
