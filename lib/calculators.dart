import 'dart:math';

import 'models.dart';
import 'price_db.dart';
import 'state.dart';

/// One computed material line before it becomes a BoqLine.
class ComputedLine {
  final String description;
  final double qty;
  final String unit;
  final String? priceKey;
  final double? priceOverride;

  const ComputedLine(
    this.description,
    this.qty,
    this.unit, [
    this.priceKey,
    this.priceOverride,
  ]);

  BoqLine toBoqLine([List<MaterialPrice>? db]) {
    final m = priceKey != null
        ? EstimateState.findIn(db ?? est.priceDb, priceKey!)
        : null;
    final mat = priceOverride ?? m?.price ?? 0.0;
    return BoqLine(
      description: m?.name ?? description,
      qty: qty,
      unit: m?.unit ?? unit,
      materialCost: mat,
      laborCost: mat * est.laborRate,
      priceKey: priceOverride == null ? m?.name : null,
      priceOverridden: priceOverride != null,
    );
  }
}

class CalcResult {
  final String sectionTitle;
  final List<ComputedLine> lines;
  final List<String> notes;
  const CalcResult(this.sectionTitle, this.lines, [this.notes = const []]);
}

double _ceil(double v) => v.ceilToDouble();

// ---------------------------------------------------------------------------
// CONCRETING — port of CONCRETE sheet
// ---------------------------------------------------------------------------

const kConcreteClasses = <String, List<double>>{
  'CLASS AA (1:1.5:3)': [1, 1.5, 3],
  'CLASS A (1:2:4)': [1, 2, 4],
  'CLASS B (1:2.5:5)': [1, 2.5, 5],
  'CLASS C (1:3:6)': [1, 3, 6],
};

CalcResult calcConcrete({
  required double volume,
  required String concreteClass,
  String gravel = '3/4',
}) {
  final r = kConcreteClasses[concreteClass]!;
  final sum = r[0] + r[1] + r[2];
  const dry = 1.7; // dry volume factor (sheet C17)

  final cementPer = _ceil(r[0] * dry * 1440 / sum / 40); // bags / m3
  final sandPer = _roundUp1(r[1] * dry / sum); // m3 / m3
  var aggRatio = r[2] * dry / sum;
  final aggPer = min(aggRatio > 0.5 ? _ceil(aggRatio) : aggRatio, 1.0);

  final cementBags = _ceil(cementPer * volume);
  final sandM3 = _ceil(volume * sandPer + 0.1);
  final aggM3 = volume * aggPer;

  final gravelKey = gravel == '1' ? 'GRAVEL 1"' : 'GRAVEL 3/4"';
  return CalcResult(
    'CONCRETING WORKS',
    [
      ComputedLine('CEMENT 40kg', cementBags, 'bags', 'CEMENT 40kg'),
      ComputedLine('SAND', sandM3, 'cu.m', 'SAND'),
      ComputedLine('GRAVEL $gravel"', _round2(aggM3), 'cu.m', gravelKey),
    ],
    [
      'Per cu.m ($concreteClass): $cementPer bags cement, '
          '${sandPer.toStringAsFixed(1)} cu.m sand, ${aggPer.toStringAsFixed(2)} cu.m gravel',
    ],
  );
}

double _roundUp1(double v) => (v * 10).ceil() / 10;
double _round2(double v) => (v * 100).roundToDouble() / 100;

// ---------------------------------------------------------------------------
// MASONRY — port of MASONRY sheet
// ---------------------------------------------------------------------------

const kMortarClasses = <String, String>{
  'CLASS A (1:2)': 'A',
  'CLASS B (1:3)': 'B',
  'CLASS C (1:4)': 'C',
  'CLASS D (1:5)': 'D',
};

/// cement factor per class (plaster & block-laying), 40kg / 50kg bags
const _plasterFactor40 = {'A': 18.0, 'B': 12.0, 'C': 9.0, 'D': 7.5};
const _plasterFactor50 = {'A': 14.5, 'B': 9.5, 'C': 7.0, 'D': 6.0};

CalcResult calcMasonry({
  required double wallArea,
  double apertureArea = 0,
  double allowance = 0.10,
  String chb = 'CHB 4"',
  String mortarClass = 'CLASS A (1:2)',
  String cementBag = '40kg',
  double plasterMm = 19,
  bool includeRebar = true,
}) {
  final net = max(wallArea - apertureArea, 0.0);
  final f = cementBag == '50kg'
      ? _plasterFactor50[kMortarClasses[mortarClass]!]!
      : _plasterFactor40[kMortarClasses[mortarClass]!]!;

  final chbPcs = _ceil(12.5 * net * (1 + allowance));
  final cement =
      net * 2 * plasterMm * f / 1000 + // rough plastering
      net * 2 * 0.0625 + // fine plastering
      chbPcs * 0.006 * 12 + // mortar fill
      chbPcs * f * 0.0008; // block laying mortar
  final sand =
      net * plasterMm * 2 * 1.33 / 1000 + // rough plaster sand
      chbPcs * 0.006 + // mortar fill sand
      chbPcs * f * 0.0005; // block laying sand

  final lines = <ComputedLine>[
    ComputedLine('Concrete Hollow Blocks $chb', chbPcs, 'pcs', chb),
    ComputedLine('CEMENT $cementBag', _ceil(cement), 'bags', 'CEMENT 40kg'),
    ComputedLine('SAND', _ceil(sand), 'cu.m', 'SAND'),
  ];

  final notes = <String>['Net wall area: ${net.toStringAsFixed(2)} sq.m'];
  if (includeRebar) {
    final barPcs = _ceil(net * 5.5 / 6); // 12mm x 6m bars
    final barKg = 12 * 12 * barPcs / 162;
    final tieKg = 1.8 * net / 53;
    lines.add(
      ComputedLine('Steel bar 12mm', _round2(barKg), 'kg', 'Steel bar 12mm'),
    );
    lines.add(
      ComputedLine(
        'Tie Wire #16 25kg/roll',
        _round2(tieKg),
        'roll',
        'Tie Wire #16 25kg/roll',
      ),
    );
    notes.add('$barPcs pcs of 12mm x 6m bars');
  }
  notes.add('Water: ~${_ceil(_ceil(cement) * 6)} gal');

  return CalcResult('MASONRY WORKS', lines, notes);
}

// ---------------------------------------------------------------------------
// TILING — port of TILES sheet
// ---------------------------------------------------------------------------

const kTileSizes = <String, double>{
  '0.30 x 0.30': 0.30,
  '0.40 x 0.40': 0.40,
  '0.50 x 0.50': 0.50,
  '0.60 x 0.60': 0.60,
};

CalcResult calcTiles({
  required double area,
  required String tileSize,
  bool isWall = false,
  double wastePct = 5,
  bool dryPack = false,
  double dryPackMm = 50,
}) {
  final t = kTileSizes[tileSize]!;
  final tiles = _ceil(area * (1 + wastePct / 100) / (t * t));
  final adhesive = _ceil(area / (isWall ? 3 : 5));
  final grout = _ceil(area / 4);

  final prefix = isWall ? 'WALL TILES' : 'FLOOR TILES';
  final lines = <ComputedLine>[
    ComputedLine('$prefix $tileSize', tiles, 'pcs', 'FLOOR TILES $tileSize'),
    ComputedLine('TILE ADHESIVE 25KG', adhesive, 'bags', 'TILE ADHESIVE 25KG'),
    ComputedLine('TILE GROUT 2kg', grout, 'bags', 'TILE GROUT 2kg'),
  ];
  final notes = <String>[];
  if (dryPack) {
    final cement = _ceil(9.82 * area * dryPackMm / 1000);
    final sand = _ceil(area * dryPackMm * 0.834 / 1000);
    lines.add(ComputedLine('CEMENT 40kg', cement, 'bags', 'CEMENT 40kg'));
    lines.add(ComputedLine('SAND', sand, 'cu.m', 'SAND'));
    notes.add('Dry pack / mud pack ${dryPackMm.toStringAsFixed(0)}mm (1:3)');
  }
  return CalcResult('TILING WORKS', lines, notes);
}

// ---------------------------------------------------------------------------
// PAINTING — port of PAINTING sheet (coefficients in liters per sq.m)
// ---------------------------------------------------------------------------

class PaintSystem {
  final String label;
  final Map<String, double> coats; // material -> L/m2
  const PaintSystem(this.label, this.coats);
}

const kPaintSystems = <PaintSystem>[
  PaintSystem('Concrete - Exterior - Plain - New', {
    'Wall Concrete Putty': 0.4,
    'Primer Flatwall Enamel': 0.16,
    'Topcoat Flat Latex': 0.27,
    'Paint Thinner': 0.2,
  }),
  PaintSystem('Concrete - Exterior - Plain - Repaint', {
    'Wall Concrete Putty': 0.16,
    'Topcoat Flat Latex': 0.27,
    'Paint Thinner': 0.02,
  }),
  PaintSystem('Concrete - Exterior - Textured - New', {
    'Primer Flatwall Enamel': 0.16,
    'Wall Concrete Putty': 0.16,
    'Textured / Acrytex paint': 0.8,
    'Topcoat Flat Latex': 0.53,
    'Paint Thinner': 0.3,
  }),
  PaintSystem('Concrete - Interior - Plain - New', {
    'Wall Concrete Putty': 0.4,
    'Primer Flatwall Enamel': 0.16,
    'Topcoat Flat Latex': 0.27,
    'Paint Thinner': 0.2,
  }),
  PaintSystem('Concrete - Interior - Textured - New', {
    'Primer Flatwall Enamel': 0.16,
    'Wall Concrete Putty': 0.4,
    'Textured / Acrytex paint': 0.8,
    'Topcoat Flat Latex': 0.53,
    'Paint Thinner': 0.3,
  }),
  PaintSystem('Wood - Plain - New', {
    'Primer Flatwall Enamel': 0.16,
    'Plasolux Glazing Putty': 0.4,
    'Topcoat Quick Drying Enamel': 0.27,
    'Paint Thinner': 0.2,
  }),
  PaintSystem('Wood - Plain - Repaint', {
    'Plasolux Glazing Putty': 0.16,
    'Topcoat Quick Drying Enamel': 0.27,
    'Paint Thinner': 0.09,
  }),
];

CalcResult calcPainting({required double area, required int systemIndex}) {
  final sys = kPaintSystems[systemIndex];
  final lines = sys.coats.entries
      .map((e) => ComputedLine(e.key, _ceil(area * e.value), 'liters', e.key))
      .toList();
  return CalcResult('PAINTING WORKS', lines, [sys.label]);
}

// ---------------------------------------------------------------------------
// CARPENTRY — port of CARPENTRY sheet
// ---------------------------------------------------------------------------

CalcResult calcCarpentry({
  required double length,
  required double width,
  required String system, // 'ceiling' | 'plywood partition' | 'metal stud'
}) {
  final area = length * width;
  final perim3 = _ceil(length / 3 + width / 3); // wall angles / cornice

  final List<ComputedLine> lines;
  final notes = <String>['Area: ${area.toStringAsFixed(2)} sq.m'];

  switch (system) {
    case 'plywood partition':
      lines = [
        ComputedLine(
          'Marine Plywood 4ft x 8ft 3/4"',
          _ceil(area / 2.88 * 1.1),
          'pcs',
          'Marine Plywood 4ft x 8ft 3/4',
        ),
        ComputedLine('2x2 lumber 8ft', _ceil(area * 1.6), 'pcs'),
        ComputedLine('CWN Assorted', _ceil(area * 36), 'kg', 'CWN Assorted'),
        ComputedLine('Concrete Nails', _ceil(area * 12), 'kg'),
      ];
      break;
    case 'metal stud':
      lines = [
        ComputedLine(
          'Fiber Cement Board 4ft x 8ft 4.5mm',
          _ceil(area / 2.88 * 1.1),
          'pcs',
          'Fiber Cement Board 4ft x 8ft 4.5mm',
        ),
        ComputedLine(
          'Fiber Cement Board Screw 1 1/2',
          _ceil(area * 36),
          'box',
          'Fiber Cement Board Screw 1 1/2',
        ),
        ComputedLine(
          'Stainless  Flathead Metal Screw',
          _ceil(area * 20),
          'pcs',
          'Stainless  Flathead Metal Screw',
        ),
        ComputedLine(
          'METAL STUD 32mm x 76mm, 0.8mm thickness',
          _ceil(area * 1.3),
          'pcs',
          'METAL STUD\t32mm x 76mm',
        ),
      ];
      break;
    default: // ceiling - metal furring
      final fcb = _ceil(area / 2.88);
      lines = [
        ComputedLine(
          'Fiber Cement Board 4ft x 8ft 4.5mm',
          fcb,
          'pcs',
          'Fiber Cement Board 4ft x 8ft 4.5mm',
        ),
        ComputedLine(
          'Metal furring 0.6mm thickness 5m',
          fcb * 2,
          'pcs',
          'Metal furring 0.6mm thickness 5m',
        ),
        ComputedLine(
          'C - Channel 1mm thickness 5m',
          fcb,
          'pcs',
          'C - Channel 1mm thickness 5m',
        ),
        ComputedLine(
          'Wall angle 0.5mm thickness 3m',
          perim3,
          'pcs',
          'Wall angle 0.5mm thickness 3m',
        ),
        ComputedLine(
          'Blind Revit  3/16x3/4',
          _ceil(area * 20 / 500),
          'box',
          'Blind Revit',
        ),
        ComputedLine('Wood Cornice 1 x 3 x 10', perim3, 'pcs', 'Wood Cornice'),
        ComputedLine(
          'Fiber Cement Board Screw 1 1/2',
          _ceil(area * 36),
          'box',
          'Fiber Cement Board Screw 1 1/2',
        ),
        ComputedLine('Concrete Nail', 1, 'kg'),
        ComputedLine('Wall Clip', fcb * 12, 'pcs', 'Wall Clip'),
        ComputedLine('Expansion bolt 2" 1/2', 1, 'box', 'Expansion bolt'),
      ];
  }
  return CalcResult(
    system == 'ceiling' ? 'CEILING WORKS' : 'CARPENTRY WORKS',
    lines,
    notes,
  );
}

// ---------------------------------------------------------------------------
// STEEL / REBAR — port of STEEL sheet (member volumes + rebar weight)
// ---------------------------------------------------------------------------

CalcResult calcSteel({
  required double length,
  required double width,
  required double height,
  int members = 1,
  double barDiaMm = 12,
  double barsPerMember = 4,
  double barLengthM = 6,
  String concreteClass = 'CLASS A (1:2:4)',
  bool includeConcrete = true,
  String memberName = 'COLUMN',
}) {
  final volume = length * width * height * members;
  final barKg =
      barDiaMm * barDiaMm * barLengthM * barsPerMember * members / 162;
  final tieKg = barKg * 0.02;

  final lines = <ComputedLine>[
    ComputedLine(
      'Steel bar ${barDiaMm.toStringAsFixed(0)}mm',
      _round2(barKg),
      'kg',
      'Steel bar ${barDiaMm.toStringAsFixed(0)}mm',
    ),
    ComputedLine(
      'Tie Wire #16 25kg/roll',
      _round2(tieKg),
      'roll',
      'Tie Wire #16 25kg/roll',
    ),
  ];

  final notes = <String>[
    '$members x $memberName ${length}x$width x ${height}m = '
        '${volume.toStringAsFixed(2)} cu.m concrete',
  ];

  if (includeConcrete && volume > 0) {
    final c = calcConcrete(volume: volume, concreteClass: concreteClass);
    lines.addAll(c.lines);
  }
  return CalcResult('STEEL WORKS', lines, notes);
}

// ---------------------------------------------------------------------------
// STAIRS — port of STAIRS sheet
// ---------------------------------------------------------------------------

CalcResult calcStairs({
  required double totalRise,
  required double riser,
  required double tread,
  required double stairWidth,
  double waistMm = 100,
  String concreteClass = 'CLASS A (1:2:4)',
  bool tileTreads = false,
  String tileSize = '0.60 x 0.60',
}) {
  final steps = (totalRise / riser).floorToDouble();
  final run = steps * tread;
  // waist slab + triangular steps volume
  final volume =
      stairWidth * (run * waistMm / 1000 + 0.5 * run * riser * steps / 2);

  final c = calcConcrete(volume: volume, concreteClass: concreteClass);
  final lines = <ComputedLine>[...c.lines];
  final notes = <String>[
    '$steps steps, run ${run.toStringAsFixed(2)} m, '
        'concrete ~${volume.toStringAsFixed(2)} cu.m',
  ];

  if (tileTreads) {
    final t = kTileSizes[tileSize]!;
    final treadArea = steps * tread * stairWidth * 1.1;
    lines.add(
      ComputedLine(
        'FLOOR TILES $tileSize',
        _ceil(treadArea / (t * t)),
        'pcs',
        'FLOOR TILES $tileSize',
      ),
    );
    lines.add(
      ComputedLine(
        'TILE ADHESIVE 25KG',
        _ceil(treadArea / 5),
        'bags',
        'TILE ADHESIVE 25KG',
      ),
    );
  }
  return CalcResult('CONCRETING WORKS', lines, notes);
}
