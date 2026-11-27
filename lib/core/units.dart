// Micro-unit engine for Sseddume Labs.
//
// Quantities are stored as integers scaled by kScale (1,000,000) so that 0.01 kg is
// never 0.010000000000000002. Money is whole UGX. Intermediate products use BigInt,
// so a 50 kg sack sold in 10 g portions cannot overflow or drift.

const int kScale = 1000000;

/// Round-half-up of (a * b / d) without overflow. Sign-symmetric.
int mulDivRound(int a, int b, int d) {
  final n = BigInt.from(a) * BigInt.from(b);
  final den = BigInt.from(d);
  final q = (n.abs() * BigInt.two + den) ~/ (den * BigInt.two);
  return (n.isNegative ? -q : q).toInt();
}

/// "0.25" / "10" / "1,5" -> micro units. Returns null when not a number. Extra decimals are truncated.
int? parseMicro(String input) {
  final s = input.trim().replaceAll(',', '.');
  final m = RegExp(r'^(\d*)(?:\.(\d*))?$').firstMatch(s);
  if (m == null) return null;
  final whole = m.group(1) ?? '';
  final frac = m.group(2) ?? '';
  if (whole.isEmpty && frac.isEmpty) return null;
  final w = whole.isEmpty ? 0 : int.parse(whole);
  final f = int.parse(frac.padRight(6, '0').substring(0, 6));
  return w * kScale + f;
}

String _group(int n) {
  final s = n.toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}

/// Micro units -> "0.01", "50", "1,500", "1.234567"
String formatMicro(int micro) {
  final a = micro.abs();
  final whole = _group(a ~/ kScale);
  final frac = (a % kScale).toString().padLeft(6, '0').replaceFirst(RegExp(r'0+$'), '');
  final s = frac.isEmpty ? whole : '$whole.$frac';
  return micro < 0 ? '-$s' : s;
}

/// Quantity in a selling unit -> quantity in base units.
int toBaseMicro(int qtyMicro, int factorMicro) => mulDivRound(qtyMicro, factorMicro, kScale);

/// Price of `qtyMicro` selling units at `unitPrice` UGX per ONE unit.
int lineTotalUgx(int qtyMicro, int unitPrice) => mulDivRound(qtyMicro, unitPrice, kScale);

/// Exact proportional cost of `baseMicro` base units, rounded to whole UGX.
int lineCostUgx(int baseMicro, double costPerBase) =>
    mulDivRound(baseMicro, (costPerBase * 10000).round(), 10000 * kScale);

/// Cost per base unit from a bulk purchase.
double costPerBase({required int packCostUgx, required int packBaseMicro}) =>
    packCostUgx * kScale / packBaseMicro;

/// Moving-average cost after a restock at a (possibly) different price.
double weightedAvgCost({
  required int oldStockMicro,
  required double oldCost,
  required int addMicro,
  required double addCost,
}) {
  final o = oldStockMicro < 0 ? 0 : oldStockMicro;
  final total = o + addMicro;
  if (total <= 0) return addCost;
  return (o * oldCost + addMicro * addCost) / total;
}

// ---------------------------------------------------------------- presets for the product form

class UnitPreset {
  const UnitPreset(this.name, this.sizeInBase);
  final String name;
  final int sizeInBase;
}

class Measure {
  const Measure(this.id, this.label, this.baseUnit, this.presets);
  final String id;
  final String label;
  final String baseUnit;
  final List<UnitPreset> presets;
}

const List<Measure> kMeasures = [
  Measure('weight', 'Weight', 'g', [
    UnitPreset('g', 1),
    UnitPreset('10 g', 10),
    UnitPreset('100 g', 100),
    UnitPreset('250 g', 250),
    UnitPreset('500 g', 500),
    UnitPreset('kg', 1000),
  ]),
  Measure('volume', 'Volume', 'ml', [
    UnitPreset('ml', 1),
    UnitPreset('100 ml', 100),
    UnitPreset('250 ml', 250),
    UnitPreset('500 ml', 500),
    UnitPreset('litre', 1000),
  ]),
  Measure('count', 'Count', 'pc', [
    UnitPreset('pc', 1),
    UnitPreset('half dozen', 6),
    UnitPreset('dozen', 12),
  ]),
];

Measure measureById(String id) =>
    kMeasures.firstWhere((m) => m.id == id, orElse: () => kMeasures.last);

Measure measureForBase(String base) =>
    kMeasures.firstWhere((m) => m.baseUnit == base, orElse: () => kMeasures.last);
