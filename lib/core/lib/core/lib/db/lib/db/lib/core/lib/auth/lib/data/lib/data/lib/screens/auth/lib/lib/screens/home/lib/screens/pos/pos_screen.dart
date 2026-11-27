import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';

import '../../auth/auth_service.dart';
import '../../core/units.dart';
import '../../core/util.dart';
import '../../data/repos.dart';

class PosScreen extends StatefulWidget {
  const PosScreen({super.key});
  @override
  State<PosScreen> createState() => _PosScreenState();
}

class _PosScreenState extends State<PosScreen> {
  final _search = TextEditingController();
  final _discount = TextEditingController(text: '0');
  final List<CartLine> _cart = [];
  Customer? _customer;
  DateTime? _creditDue;

  @override
  void dispose() {
    _search.dispose();
    _discount.dispose();
    super.dispose();
  }

  int get _subtotal => _cart.fold<int>(0, (sum, line) => sum + line.total);

  int get _discountValue {
    final parsed = int.tryParse(_discount.text.trim()) ?? 0;
    if (parsed < 0) return 0;
    return parsed > _subtotal ? _subtotal : parsed;
  }

  int get _total => _subtotal - _discountValue;

  void _addOrMergeLine(Product product, ProductUnit unit, int qtyMicro) {
    if (qtyMicro <= 0) return;
    setState(() {
      final idx = _cart.indexWhere((l) => l.product.id == product.id && l.unit.id == unit.id);
      if (idx >= 0) {
        _cart[idx] = CartLine(product, unit, _cart[idx].qtyMicro + qtyMicro);
      } else {
        _cart.add(CartLine(product, unit, qtyMicro));
      }
    });
  }

  Future<void> _openUnitPicker(Product product) async {
    var selectedUnit = product.defaultUnit;
    final qtyCtrl = TextEditingController(text: selectedUnit.allowFraction ? '1' : '1');
    String? err;

    final added = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, MediaQuery.of(ctx).viewInsets.bottom + 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(product.name, style: Theme.of(ctx).textTheme.titleMedium),
              Text('Available: ${product.stockText}', style: Theme.of(ctx).textTheme.bodySmall),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final u in product.units)
                    ChoiceChip(
                      label: Text('${u.name} (${fmtUgx(u.price)})'),
                      selected: selectedUnit.id == u.id,
                      onSelected: (_) {
                        setModalState(() {
                          selectedUnit = u;
                          if (!u.allowFraction) {
                            final currentMicro = parseQtyMicro(qtyCtrl.text, allowFraction: true) ?? kMicro;
                            final whole = (currentMicro / kMicro).round().clamp(1, 999999);
                            qtyCtrl.text = '$whole';
                          }
                        });
                      },
                    ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: qtyCtrl,
                keyboardType: TextInputType.numberWithOptions(decimal: selectedUnit.allowFraction),
                decoration: InputDecoration(
                  labelText: 'Quantity (${selectedUnit.name})',
                  helperText: selectedUnit.allowFraction ? 'Decimals allowed' : 'Whole units only',
                  errorText: err,
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () {
                  final micro = parseQtyMicro(qtyCtrl.text, allowFraction: selectedUnit.allowFraction);
                  if (micro == null || micro <= 0) {
                    setModalState(() => err = 'Enter a valid quantity greater than zero.');
                    return;
                  }
                  Navigator.pop(ctx, true);
                },
                child: const Text('Add to cart'),
              ),
            ],
          ),
        ),
      ),
    );

    if (added == true) {
      final micro = parseQtyMicro(qtyCtrl.text, allowFraction: selectedUnit.allowFraction) ?? 0;
      _addOrMergeLine(product, selectedUnit, micro);
    }
    qtyCtrl.dispose();
  }

  Future<void> _scanBarcode(CatalogRepo catalog) async {
    final code = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const _BarcodeScannerPage()),
    );
    if (!mounted || code == null || code.trim().isEmpty) return;
    final found = catalog.byBarcode(code.trim());
    if (found == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No product found for barcode: ${code.trim()}')),
      );
      return;
    }
    await _openUnitPicker(found);
  }

  Future<void> _pickCustomer(SalesRepo sales) async {
    final searchCtrl = TextEditingController();
    final nameCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    final ninCtrl = TextEditingController();
    var query = '';

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) {
          final list = sales.customers(query);
          return Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, MediaQuery.of(ctx).viewInsets.bottom + 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(child: Text('Select customer', style: Theme.of(ctx).textTheme.titleMedium)),
                    if (_customer != null)
                      TextButton(
                        onPressed: () {
                          setState(() {
                            _customer = null;
                            _creditDue = null;
                          });
                          Navigator.pop(ctx);
                        },
                        child: const Text('Clear'),
                      ),
                  ],
                ),
                TextField(
                  controller: searchCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Search name or phone',
                    prefixIcon: Icon(Icons.search),
                  ),
                  onChanged: (v) => setModalState(() => query = v.trim()),
                ),
                const SizedBox(height: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 200),
                  child: list.isEmpty
                      ? const Center(child: Padding(padding: EdgeInsets.all(16), child: Text('No matching customers')))
                      : ListView.builder(
                          shrinkWrap: true,
                          itemCount: list.length,
                          itemBuilder: (_, i) {
                            final c = list[i];
                            return ListTile(
                              title: Text(c.name),
                              subtitle: c.phone == null ? null : Text(c.phone!),
                              onTap: () {
                                setState(() => _customer = c);
                                Navigator.pop(ctx);
                              },
                            );
                          },
                        ),
                ),
                const Divider(),
                Text('New customer', style: Theme.of(ctx).textTheme.titleSmall),
                const SizedBox(height: 8),
                TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Full name *')),
                const SizedBox(height: 8),
                TextField(
                  controller: phoneCtrl,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(labelText: 'Phone number'),
                ),
                const SizedBox(height: 8),
                TextField(controller: ninCtrl, decoration: const InputDecoration(labelText: 'NIN (optional)')),
                const SizedBox(height: 12),
                FilledButton.tonal(
                  onPressed: () {
                    if (nameCtrl.text.trim().isEmpty) return;
                    final created = sales.addCustomer(
                      nameCtrl.text,
                      phoneCtrl.text.trim().isEmpty ? null : phoneCtrl.text.trim(),
                      ninCtrl.text.trim().isEmpty ? null : ninCtrl.text.trim(),
                    );
                    setState(() => _customer = created);
                    Navigator.pop(ctx);
                  },
                  child: const Text('Save & select customer'),
                ),
              ],
            ),
          );
        },
      ),
    );
    searchCtrl.dispose();
    nameCtrl.dispose();
    phoneCtrl.dispose();
    ninCtrl.dispose();
  }

  Future<void> _openCheckout(SalesRepo sales) async {
    if (_cart.isEmpty || _total <= 0) return;
    var method = 'cash';
    final amountCtrl = TextEditingController(text: '$_total');
    final refCtrl = TextEditingController();
    var dueDate = _creditDue ?? DateTime.now().add(const Duration(days: 14));
    String? err;

    final done = await showModalBottomSheet<({String saleId, String receiptNo})>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, MediaQuery.of(ctx).viewInsets.bottom + 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Checkout · ${fmtUgx(_total)}', style: Theme.of(ctx).textTheme.titleLarge),
              const SizedBox(height: 8),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.person_outline),
                title: Text(_customer?.name ?? 'Walk-in customer'),
                subtitle: _customer?.phone == null ? null : Text(_customer!.phone!),
                trailing: TextButton(
                  onPressed: () async {
                    Navigator.pop(ctx);
                    await _pickCustomer(sales);
                  },
                  child: const Text('Change'),
                ),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                initialValue: method,
                decoration: const InputDecoration(labelText: 'Payment method'),
                items: [
                  for (final entry in kPaymentLabels.entries)
                    DropdownMenuItem(value: entry.key, child: Text(entry.value)),
                ],
                onChanged: (v) {
                  if (v == null) return;
                  setModalState(() => method = v);
                },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: amountCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Amount (UGX)'),
              ),
              if (method != 'cash' && method != 'credit') ...[
                const SizedBox(height: 12),
                TextField(
                  controller: refCtrl,
                  decoration: const InputDecoration(labelText: 'Transaction / reference ID'),
                ),
              ],
              if (method == 'credit') ...[
                const SizedBox(height: 12),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Due date'),
                  subtitle: Text('${dueDate.year}-${dueDate.month.toString().padLeft(2, '0')}-${dueDate.day.toString().padLeft(2, '0')}'),
                  trailing: TextButton(
                    onPressed: () async {
                      final picked = await showDatePicker(
                        context: ctx,
                        initialDate: dueDate,
                        firstDate: DateTime.now(),
                        lastDate: DateTime.now().add(const Duration(days: 365)),
                      );
                      if (picked != null) setModalState(() => dueDate = picked);
                    },
                    child: const Text('Pick date'),
                  ),
                ),
              ],
              if (err != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(err!, style: const TextStyle(color: Colors.red)),
                ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () {
                  final amt = int.tryParse(amountCtrl.text.trim()) ?? 0;
                  if (amt != _total) {
                    setModalState(() => err = 'Enter exact total (${fmtUgx(_total)}) to complete sale.');
                    return;
                  }
                  if (method == 'credit' && _customer == null) {
                    setModalState(() => err = 'Select a customer before recording a credit sale.');
                    return;
                  }
                  try {
                    final result = sales.completeSale(
                      lines: List<CartLine>.from(_cart),
                      discount: _discountValue,
                      payments: [
                        PaymentInput(method, amt, refCtrl.text.trim().isEmpty ? null : refCtrl.text.trim()),
                      ],
                      customer: _customer,
                      creditDue: method == 'credit' ? dueDate : null,
                    );
                    Navigator.pop(ctx, result);
                  } catch (e) {
                    setModalState(() => err = '$e');
                  }
                },
                child: const Text('Complete sale'),
              ),
            ],
          ),
        ),
      ),
    );

    amountCtrl.dispose();
    refCtrl.dispose();

    if (done != null && mounted) {
      setState(() {
        _cart.clear();
        _discount.text = '0';
        _customer = null;
        _creditDue = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Sale complete · Receipt ${done.receiptNo}')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();
    final catalog = auth.catalog!;
    final sales = auth.sales!;

    return ListenableBuilder(
      listenable: auth.db!,
      builder: (context, _) {
        final items = catalog.products(query: _search.text);
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _search,
                      decoration: InputDecoration(
                        labelText: 'Search products or barcode',
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: _search.text.isEmpty
                            ? null
                            : IconButton(
                                icon: const Icon(Icons.clear),
                                onPressed: () {
                                  _search.clear();
                                  setState(() {});
                                },
                              ),
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    tooltip: 'Scan barcode',
                    onPressed: () => _scanBarcode(catalog),
                    icon: const Icon(Icons.qr_code_scanner),
                  ),
                ],
              ),
            ),
            Expanded(
              child: items.isEmpty
                  ? const Center(child: Text('No products found'))
                  : ListView.builder(
                      itemCount: items.length,
                      itemBuilder: (_, i) {
                        final p = items[i];
                        final u = p.defaultUnit;
                        return Card(
                          child: ListTile(
                            title: Text(p.name),
                            subtitle: Text('${u.name} · ${fmtUgx(u.price)} · Stock: ${p.stockText}'),
                            trailing: IconButton(
                              icon: const Icon(Icons.add_shopping_cart),
                              onPressed: () => _openUnitPicker(p),
                            ),
                            onTap: () => _addOrMergeLine(p, u, kMicro),
                          ),
                        );
                      },
                    ),
            ),
            if (_cart.isNotEmpty)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Text('Cart (${_cart.length})', style: Theme.of(context).textTheme.titleMedium),
                          const Spacer(),
                          TextButton.icon(
                            onPressed: () => _pickCustomer(sales),
                            icon: const Icon(Icons.person_add_alt_1, size: 18),
                            label: Text(_customer?.name ?? 'Customer'),
                          ),
                        ],
                      ),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 140),
                        child: ListView.builder(
                          shrinkWrap: true,
                          itemCount: _cart.length,
                          itemBuilder: (_, i) {
                            final line = _cart[i];
                            return ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              title: Text('${line.product.name} (${line.qtyText})'),
                              subtitle: Text(fmtUgx(line.total)),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.remove_circle_outline),
                                    onPressed: () {
                                      setState(() {
                                        final next = line.qtyMicro - kMicro;
                                        if (next <= 0) {
                                          _cart.removeAt(i);
                                        } else {
                                          _cart[i] = CartLine(line.product, line.unit, next);
                                        }
                                      });
                                    },
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.add_circle_outline),
                                    onPressed: () => _addOrMergeLine(line.product, line.unit, kMicro),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.delete_outline),
                                    onPressed: () => setState(() => _cart.removeAt(i)),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _discount,
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(labelText: 'Discount (UGX)', isDense: true),
                              onChanged: (_) => setState(() {}),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text('Subtotal: ${fmtUgx(_subtotal)}', style: Theme.of(context).textTheme.bodySmall),
                              Text('Total: ${fmtUgx(_total)}', style: Theme.of(context).textTheme.titleMedium),
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: _total > 0 ? () => _openCheckout(sales) : null,
                        child: Text('Charge ${fmtUgx(_total)}'),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _BarcodeScannerPage extends StatelessWidget {
  const _BarcodeScannerPage();

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Scan barcode')),
        body: MobileScanner(
          onDetect: (capture) {
            final raw = capture.barcodes.firstOrNull?.rawValue;
            if (raw != null && raw.isNotEmpty) {
              Navigator.pop(context, raw);
            }
          },
        ),
      );
}
