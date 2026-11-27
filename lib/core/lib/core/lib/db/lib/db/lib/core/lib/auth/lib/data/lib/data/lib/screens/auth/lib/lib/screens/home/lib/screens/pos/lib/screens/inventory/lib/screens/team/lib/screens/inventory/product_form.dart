import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../auth/auth_service.dart';
import '../../core/units.dart';
import '../../core/util.dart';
import '../../data/repos.dart';
import '../barcode/label_pdf.dart';
import '../barcode/scanner_page.dart';

class _U {
  _U({
    this.id,
    String name = '',
    String size = '1',
    String price = '',
    this.fraction = false,
    this.isDefault = false,
  })  : name = TextEditingController(text: name),
        size = TextEditingController(text: size),
        price = TextEditingController(text: price);
  String? id;
  final TextEditingController name, size, price;
  bool fraction;
  bool isDefault;

  void dispose() {
    name.dispose();
    size.dispose();
    price.dispose();
  }
}

class ProductFormPage extends StatefulWidget {
  const ProductFormPage({super.key, this.existing});
  final Product? existing;
  @override
  State<ProductFormPage> createState() => _ProductFormPageState();
}

class _ProductFormPageState extends State<ProductFormPage> {
  final _name = TextEditingController();
  final _category = TextEditingController();
  final _barcode = TextEditingController();
  final _buyQty = TextEditingController();
  final _buyCost = TextEditingController();
  final _costPerBase = TextEditingController();
  final _reorder = TextEditingController();
  late Measure _measure;
  late UnitPreset _buyUnit;
  final List<_U> _units = [];
  String? _error;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final p = widget.existing;
    if (p == null) {
      _measure = kMeasures.first;
      _barcode.text = generateInternalCode();
      _resetUnits();
    } else {
      _measure = measureForBase(p.baseUnit);
      _name.text = p.name;
      _category.text = p.category ?? '';
      _barcode.text = p.barcode ?? generateInternalCode();
      _costPerBase.text = p.costPerBase.toString();
      _reorder.text = p.reorderMicro == 0 ? '' : formatMicro(p.reorderMicro);
      for (final u in p.units) {
        _units.add(
          _U(
            id: u.id,
            name: u.name,
            size: formatMicro(u.factorMicro).replaceAll(',', ''),
            price: '${u.price}',
            fraction: u.allowFraction,
            isDefault: u.isDefault,
          ),
        );
      }
    }
    _buyUnit = _measure.presets.last;
  }

  @override
  void dispose() {
    _name.dispose();
    _category.dispose();
    _barcode.dispose();
    _buyQty.dispose();
    _buyCost.dispose();
    _costPerBase.dispose();
    _reorder.dispose();
    for (final u in _units) {
      u.dispose();
    }
    super.dispose();
  }

  void _resetUnits() {
    for (final u in _units) {
      u.dispose();
    }
    _units
      ..clear()
      ..add(
        _U(
          name: _measure.presets.first.name,
          size: '${_measure.presets.first.sizeInBase}',
          fraction: _measure.id != 'count',
          isDefault: true,
        ),
      )
      ..add(
        _U(
          name: _measure.presets.last.name,
          size: '${_measure.presets.last.sizeInBase}',
          fraction: _measure.id != 'count',
        ),
      );
  }

  Future<void> _save() async {
    final auth = context.read<AuthService>();
    final repo = auth.catalog!;
    try {
      if (_name.text.trim().isEmpty) throw 'Enter the product name';
      final code = _barcode.text.trim();
      if (code.isEmpty) throw 'A code is required';
      if (repo.barcodeTaken(code, exceptId: widget.existing?.id)) {
        throw 'That code is already used by another product';
      }

      final units = <UnitDraft>[];
      for (final u in _units) {
        final size = parseMicro(u.size.text);
        final price = int.tryParse(u.price.text.replaceAll(',', ''));
        if (u.name.text.trim().isEmpty || size == null || size <= 0 || price == null) {
          throw 'Every selling unit needs a name, a size and a price';
        }
        units.add(
          UnitDraft(
            id: u.id,
            name: u.name.text,
            factorMicro: size,
            price: price,
            allowFraction: u.fraction,
            isDefault: u.isDefault,
          ),
        );
      }
      if (units.isEmpty) throw 'Add at least one selling unit';

      double cost;
      var opening = 0;
      if (_isEdit) {
        cost = double.tryParse(_costPerBase.text) ?? 0;
      } else {
        final q = parseMicro(_buyQty.text);
        final total = int.tryParse(_buyCost.text.replaceAll(',', ''));
        if (q != null && q > 0) {
          opening = q * _buyUnit.sizeInBase; // micro of base unit
          cost = total == null ? 0 : costPerBase(packCostUgx: total, packBaseMicro: opening);
        } else {
          cost = 0;
        }
      }

      repo.saveProduct(
        ProductDraft(
          id: widget.existing?.id,
          name: _name.text,
          category: _category.text,
          baseUnit: _measure.baseUnit,
          barcode: code,
          costPerBase: cost,
          reorderMicro: parseMicro(_reorder.text) ?? 0,
          openingStockMicro: opening,
          units: units,
        ),
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final base = _measure.baseUnit;
    final bizName = context.read<AuthService>().session!.businessName;
    final buyQ = parseMicro(_buyQty.text);
    final buyTotal = int.tryParse(_buyCost.text.replaceAll(',', ''));
    final preview = (!_isEdit && buyQ != null && buyQ > 0 && buyTotal != null)
        ? 'Works out to ${fmtUgx(costPerBase(packCostUgx: buyTotal, packBaseMicro: buyQ * _buyUnit.sizeInBase).round())} per $base'
        : null;

    return Scaffold(
      appBar: AppBar(title: Text(_isEdit ? 'Edit product' : 'New product')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _name,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Product name *'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _category,
            decoration: const InputDecoration(labelText: 'Category (optional)'),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _barcode,
                  decoration: const InputDecoration(labelText: 'Barcode / internal code'),
                ),
              ),
              IconButton(
                tooltip: 'New code',
                icon: const Icon(Icons.autorenew),
                onPressed: () => setState(() => _barcode.text = generateInternalCode()),
              ),
              IconButton(
                tooltip: 'Scan existing barcode',
                icon: const Icon(Icons.qr_code_scanner),
                onPressed: () async {
                  final code = await Navigator.push<String>(
                    context,
                    MaterialPageRoute(builder: (_) => const ScannerPage(title: 'Scan barcode', continuous: false)),
                  );
                  if (code != null) setState(() => _barcode.text = code);
                },
              ),
            ],
          ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(Icons.label_outline),
              label: const Text('Preview sticker'),
              onPressed: () {
                final u = _units.isEmpty ? null : _units.firstWhere((x) => x.isDefault, orElse: () => _units.first);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => LabelsPage(
                      businessName: bizName,
                      items: [
                        LabelItem(
                          name: _name.text.isEmpty ? 'Product' : _name.text,
                          priceText: u == null ? '' : '${fmtUgx(int.tryParse(u.price.text) ?? 0)} / ${u.name.text}',
                          code: _barcode.text,
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          const Divider(),
          Text('How is it measured?', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: [
              for (final m in kMeasures)
                ButtonSegment(value: m.id, label: Text('${m.label} (${m.baseUnit})')),
            ],
            selected: {_measure.id},
            onSelectionChanged: _isEdit
                ? null
                : (s) => setState(() {
                      _measure = measureById(s.first);
                      _buyUnit = _measure.presets.last;
                      _resetUnits();
                    }),
          ),
          const SizedBox(height: 4),
          Text(
            'Stock is tracked in $base - the smallest unit - so selling 10 g of a 50 kg sack is exact.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          if (_isEdit)
            TextField(
              controller: _costPerBase,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(labelText: 'Cost price per $base (UGX)'),
            )
          else ...[
            Text(
              'Bulk purchase (optional - sets cost price and opening stock)',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _buyQty,
                    onChanged: (_) => setState(() {}),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: 'Quantity bought'),
                  ),
                ),
                const SizedBox(width: 8),
                DropdownButton<UnitPreset>(
                  value: _buyUnit,
                  items: [for (final u in _measure.presets) DropdownMenuItem(value: u, child: Text(u.name))],
                  onChanged: (u) => setState(() => _buyUnit = u!),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _buyCost,
              onChanged: (_) => setState(() {}),
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: 'Total cost paid (UGX)', helperText: preview),
            ),
          ],
          const SizedBox(height: 12),
          TextField(
            controller: _reorder,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(labelText: 'Low-stock alert at ($base)'),
          ),
          const Divider(height: 32),
          Text('Selling units & prices', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            '"Size" = how many $base are in ONE of that unit. Example: kg = 1000 $base; a "10 g" pack = 10 $base.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          for (final u in _units) _unitCard(u, base),
          Wrap(
            spacing: 8,
            children: [
              for (final p in _measure.presets)
                ActionChip(
                  label: Text('+ ${p.name}'),
                  onPressed: () => setState(
                    () => _units.add(
                      _U(
                        name: p.name,
                        size: '${p.sizeInBase}',
                        fraction: _measure.id != 'count' && p.sizeInBase >= 1000,
                      ),
                    ),
                  ),
                ),
              ActionChip(
                label: const Text('+ custom'),
                onPressed: () => setState(() => _units.add(_U())),
              ),
            ],
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
          const SizedBox(height: 20),
          FilledButton.icon(onPressed: _save, icon: const Icon(Icons.check), label: const Text('Save product')),
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  Widget _unitCard(_U u, String base) {
    final selectedDefault = _units.firstWhere((x) => x.isDefault, orElse: () => _units.first);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: u.name,
                    decoration: const InputDecoration(labelText: 'Unit name', isDense: true),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: u.size,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(labelText: 'Size ($base)', isDense: true),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: _units.length > 1
                      ? () => setState(() {
                            final wasDefault = u.isDefault;
                            u.dispose();
                            _units.remove(u);
                            if (wasDefault && _units.isNotEmpty) {
                              _units.first.isDefault = true;
                            }
                          })
                      : null,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: u.price,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Price (UGX)', isDense: true),
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  children: [
                    const Text('Fractions', style: TextStyle(fontSize: 11)),
                    Switch(value: u.fraction, onChanged: (v) => setState(() => u.fraction = v)),
                  ],
                ),
                Column(
                  children: [
                    const Text('Default', style: TextStyle(fontSize: 11)),
                    RadioGroup<String>(
                      groupValue: selectedDefault.name + (_units.indexOf(selectedDefault)).toString(),
                      onChanged: (_) => setState(() {
                        for (final x in _units) {
                          x.isDefault = identical(x, u);
                        }
                      }),
                      child: Radio<String>(
                        value: u.name + (_units.indexOf(u)).toString(),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
