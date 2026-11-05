import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:tantyahin/design_calc.dart';
import 'package:tantyahin/model3d.dart';
import 'package:tantyahin/state.dart';
import 'package:tantyahin/ui/design_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'accuracy_campaign_test.dart' as acc;

void main() {
  group('NSCP 2015 Ca/Cv tables (Table 208-7 / 208-8 x Na/Nv)', () {
    test('Zone 4 nodes', () {
      expect(seismicCa(4, 'SA', 1.0), .32);
      expect(seismicCa(4, 'SB', 1.0), .40);
      expect(seismicCa(4, 'SC', 1.0), .40);
      expect(seismicCa(4, 'SD', 1.0), .44);
      expect(seismicCa(4, 'SE', 1.0), .44);
      expect(seismicCv(4, 'SA', 1.0), .32);
      expect(seismicCv(4, 'SC', 1.0), .56);
      expect(seismicCv(4, 'SD', 1.0), .64);
      expect(seismicCv(4, 'SE', 1.0), .96);
    });
    test('Zone 2 nodes + near-source scaling', () {
      expect(seismicCa(2, 'SA', 1.0), .16);
      expect(seismicCa(2, 'SD', 1.0), .28);
      expect(seismicCv(2, 'SC', 1.0), .32);
      expect(seismicCv(2, 'SE', 1.0), .64);
      // near-source factors multiply the Z4 coefficients only
      expect(seismicCa(4, 'SD', 1.5), closeTo(.66, 1e-9));
      expect(seismicCa(2, 'SD', 1.5), .28);
    });
  });

  group('NSCP 2015 ELF hand oracle (Eq.208-8..17)', () {
    // Zone 4 SD: Ca=0.44 Cv=0.64; SMRF R=8.5 Ct=0.0731; I=1; hn=12
    final p = DesignParams(zone: 4, soil: 'SD');
    final r = seismicELF(p, [2000, 2000, 2000, 2000], [3, 6, 9, 12]);
    test('Ca, Cv, T, V caps', () {
      expect(r.ca, closeTo(.44, 1e-9));
      expect(r.cv, closeTo(.64, 1e-9));
      expect(r.t, closeTo(.0731 * math.pow(12, .75), 1e-9));
      // Eq.208-9 cap: 2.5 Ca I W / R = 0.1294 W governs (raw 0.1597 W)
      expect(r.vmax, closeTo(2.5 * .44 * 8000 / 8.5, 1e-6));
      expect(r.v, closeTo(r.vmax, 1e-9));
      expect(r.vmin, closeTo(.11 * .44 * 8000, 1e-6)); // Eq.208-10
      // Eq.208-11 Zone-4 floor: 0.8 Z Nv I W / R
      expect(r.vz4, closeTo(.8 * .4 * 8000 / 8.5, 1e-6));
      expect(r.ft, 0.0); // T < 0.7 s -> no Ft (Eq.208-16)
    });
    test('Fx sums to V and increases with height (Eq.208-17)', () {
      expect(r.fx.reduce((a, b) => a + b), closeTo(r.v, 1e-6));
      for (var i = 1; i < 4; i++) {
        expect(r.fx[i], greaterThan(r.fx[i - 1]));
      }
    });
    test('Ft applies for T > 0.7 and is capped at 0.25 V', () {
      // Ct=0.0488 masonry, tall + light -> long period
      final q = DesignParams(zone: 4, soil: 'SD', sys: 2);
      final t = seismicELF(q, [500, 500], [20, 45]);
      expect(t.t, greaterThan(0.7));
      expect(t.ft, closeTo(math.min(.07 * t.t * t.v, .25 * t.v), 1e-9));
      expect(t.fx.reduce((a, b) => a + b), closeTo(t.v, 1e-6));
    });
    test('V floor: vmin governs a tall flexible building', () {
      // Zone 2 SB: Cv=Ca=0.20, R=8.5; hn=60 -> T~1.58s -> raw V < vmin
      final q = DesignParams(zone: 2, soil: 'SB', occ: 0);
      final t = seismicELF(q, [1000, 1000], [30, 60]);
      // raw CvIW/RT = 29.9 kN < vmin 44 kN -> the floor governs
      expect(t.v, closeTo(.11 * .20 * 2000, 1e-6)); // Eq.208-10
      expect(t.v, t.vmin);
    });
  });

  group('project persistence', () {
    test('params round-trip; stale system index clamps', () {
      final p = DesignParams(zone: 2, soil: 'SC', occ: 4, sys: 2, na: 1.4, nv: 1.2, windKph: 150);
      final q = DesignParams.fromJson(jsonDecode(jsonEncode(p.toJson())));
      expect(q.zone, 2);
      expect(q.soil, 'SC');
      expect(q.occ, 4);
      expect(q.sys, 2);
      expect(q.na, 1.4);
      expect(q.windKph, 150);
      expect(DesignParams.fromJson({'sys': 9}).sys, kSystems.length - 1);
    });
    test('no 8th-edition fields exist on DesignParams', () {
      // regression: code/ss/s1/tl were the ASCE-7 path - gone for good
      final j = DesignParams().toJson();
      for (final stale in ['code', 'ss', 's1', 'tl']) {
        expect(j.containsKey(stale), isFalse, reason: stale);
      }
    });
  });

  group('integrated simulation on real project models', () {
    final models = {
      'L-house': acc.lHouse(),
      'two-storey': acc.twoStorey(),
      'commercial': acc.commercial(),
    };
    for (final e in models.entries) {
      test('${e.key}: finite, consistent, NSCP 2015 ELF', () {
        final r = designCalc(e.value, DesignParams(qa: 200));
        acc.expectFinite(r, e.key);
        expect(r.storeyForces.reduce((a, b) => a + b), closeTo(r.v, 1e-6));
        expect(r.v, greaterThan(0));
        expect(r.sections.map((s) => s.title).join('|'),
            contains('EQUIVALENT LATERAL'));
        // NSCP 2015 only: no ASCE/8th-ed wording anywhere
        for (final s in r.sections) {
          expect(s.title, isNot(contains('ASCE')));
          expect(s.title, isNot(contains('8th')));
          for (final x in s.rows) {
            expect(x.label, isNot(contains('ASCE')));
            expect(x.value, isNot(contains('SDS')));
            expect(x.formula ?? '', isNot(contains('8th')));
          }
        }
      });
    }
  });

  group('seismic combos - Ev = 0.5 Ca I D (Eq.208-18)', () {
    test('dead factor grows by 0.5 Ca I; uplift reduces it', () {
      final p = DesignParams(zone: 4, soil: 'SD', occ: 0); // Ca .44, I 1.0
      final r = designCalc(acc.twoStorey(), p);
      final dTot = acc.kn(acc.row(r, 'DEAD', 'TOTAL DEAD LOAD'));
      final l = acc.kn(acc.row(r, 'LIVE', 'TOTAL LIVE LOAD'));
      final ca = seismicCa(4, 'SD', 1.0);
      final ev = 0.5 * ca * 1.0; // 0.22
      final c1 = acc.row(r, 'COMBINATIONS', '(1.2 + 0.5CaI)D');
      final c2 = acc.row(r, 'COMBINATIONS', '(0.9 - 0.5CaI)D');
      expect(c1.value, startsWith(acc.kn(c1).toStringAsFixed(2)));
      expect(acc.kn(c1), closeTo((1.2 + ev) * dTot + 0.5 * l, 0.05));
      expect(acc.kn(c2), closeTo((0.9 - ev) * dTot, 0.05));
      expect(c1.ref, contains('208-18'.replaceAll('-', '.').isEmpty ? '' : 'S208.6.1'));
      expect(acc.row(r, 'SEISMIC', 'Vertical effect Ev').ref, 'S208.6.1 Eq.208-18');
    });
    test('f1 = 1.0 for assembly/storage occupancies, 0.5 otherwise', () {
      final d = acc.twoStorey();
      final res = designCalc(d, DesignParams(occ: 0)); // residential f1=.5
      final ret = designCalc(d, DesignParams(occ: 2)); // retail f1=1.0
      final lRet = acc.kn(acc.row(ret, 'LIVE', 'TOTAL LIVE LOAD'));
      final lRes = acc.kn(acc.row(res, 'LIVE', 'TOTAL LIVE LOAD'));
      final dTot = acc.kn(acc.row(ret, 'DEAD', 'TOTAL DEAD LOAD'));
      final ca = seismicCa(4, 'SD', 1.0);
      expect(acc.kn(acc.row(ret, 'COMBINATIONS', '(1.2 + 0.5CaI)D')),
          closeTo((1.2 + .5 * ca) * dTot + 1.0 * lRet, 0.05));
      expect(acc.kn(acc.row(res, 'COMBINATIONS', '(1.2 + 0.5CaI)D')),
          closeTo((1.2 + .5 * ca) * dTot + 0.5 * lRes, 0.05));
      // and the emitted labels show the factor
      expect(acc.row(ret, 'COMBINATIONS', '(1.2 + 0.5CaI)D').label,
          contains('1.0L'));
      expect(acc.row(res, 'COMBINATIONS', '(1.2 + 0.5CaI)D').label,
          contains('0.5L'));
    });
  });

  group('system restrictions (S208.4.6.3 / Table 208-11)', () {
    test('IMRF rejected in Zone 4, allowed in Zone 2', () {
      final r4 = designCalc(acc.twoStorey(), DesignParams(zone: 4, sys: 1));
      expect(acc.row(r4, 'SEISMIC', 'System check').status, Chk.fail);
      final r2 = designCalc(acc.twoStorey(), DesignParams(zone: 2, sys: 1));
      expect(
          r2.sections
              .firstWhere((s) => s.title.contains('SEISMIC'))
              .rows
              .any((x) => x.label == 'System check'),
          isFalse);
    });
  });

  group('footing embedment - Table 305-1 floor-aware minimum', () {
    test('2-storey model warns below 0.45 m; 3+ floors need 0.60 m', () {
      // twoStorey has default footD=0 -> 0.60 m embedment, so it passes
      final r2 = designCalc(acc.twoStorey(), DesignParams());
      final row2 = acc.row(r2, 'FOOTINGS', 'embedment');
      expect(row2.value, contains('vs min 0.45 m'));
      expect(row2.status, Chk.ok);
      expect(row2.ref, contains('305-1'));
      final r3 = designCalc(acc.commercial(), DesignParams());
      expect(acc.row(r3, 'FOOTINGS', 'embedment').value, contains('vs min 0.60 m'));
    });
    test('1-storey minimum is 0.30 m', () {
      final m = Model3d(name: 'one')
        ..volumes.add(Volume3d(footprint: [0, 0, 6, 0, 6, 4, 0, 4], height: .12))
        ..blocks.add(Block3d(def: 'col-sq', x: 3, y: 2, footing: true));
      final r = designCalc(m, DesignParams());
      expect(acc.row(r, 'FOOTINGS', 'embedment').value, contains('vs min 0.30 m'));
    });
  });

  group('citations - every check row carries an NSCP 2015 ref', () {
    test('all rows in check sections have refs', () {
      final r = designCalc(acc.commercial(), DesignParams());
      for (final s in r.sections) {
        if (s.title.startsWith('SUMMARY')) continue;
        for (final x in s.rows) {
          expect(x.ref, isNotNull,
              reason: '${s.title} / ${x.label} has no citation');
        }
      }
    });
    test('canonical refs appear', () {
      final r = designCalc(acc.commercial(), DesignParams());
      final refs = {for (final s in r.sections) for (final x in s.rows) x.ref ?? ''};
      for (final want in [
        'Table 204-1', 'Table 205-1', 'S208.6.1 Eq.208-18',
        'S305.1 Table 305-1', 'Eq.203-5 + S208.6.1', 'S422.4.2 / S421.2',
      ]) {
        expect(refs, contains(want), reason: want);
      }
    });
    test('S410.6.1 emits when the bar schedule lands outside 1-8%', () {
      // a 0.09m stub column still gets a 4-16mm schedule -> rho ~9.9%
      final m = acc.twoStorey()
        ..blocks.add(Block3d(def: 'col-sq', x: 2, y: 3, sx: 0.3));
      final r = designCalc(m, DesignParams());
      final row = r.sections
          .firstWhere((s) => s.title.contains('COLUMNS'))
          .rows
          .firstWhere((x) => x.ref == 'S410.6.1');
      expect(row.status, Chk.fail);
    });
    test('cited tokens resolve inside the bundled NSCP 2015 text', () {
      final f = File('docs/nscp/NSCP-2015_djvu.txt');
      expect(f.existsSync(), isTrue,
          reason: 'run from the repo root; the djvu text must be committed');
      final src = f.readAsStringSync();
      expect(src, contains('National Structural Code of the Philippines'));
      // every code citation emitted by a real report must exist verbatim
      final r = designCalc(acc.commercial(), DesignParams());
      final cited = <String>{};
      final pat = RegExp(
          r'(20[0-9][AB]?[-.]\d[\d.-]*|[34][0-9]{2}[-.]\d[\d.-]*|7\d\d(?:\.\d+)?)');
      for (final s in r.sections) {
        for (final x in s.rows) {
          for (final mt in pat.allMatches(x.ref ?? '')) {
            cited.add(mt.group(0)!);
          }
        }
      }
      expect(cited.length, greaterThan(15));
      for (final token in cited) {
        expect(src, contains(token),
            reason: 'citation $token missing from source text');
      }
    });
  });

  group('parameter sweep fuzz', () {
    test('300 random param combos hold every invariant', () {
      final rnd = math.Random(2024);
      final models = [acc.twoStorey(), acc.commercial(), acc.lHouse()];
      for (var i = 0; i < 300; i++) {
        final p = DesignParams(
          zone: rnd.nextBool() ? 4 : 2,
          soil: kSoils[rnd.nextInt(5)],
          occ: rnd.nextInt(kOccupancies.length),
          sys: rnd.nextInt(kSystems.length),
          na: 1.0 + rnd.nextDouble() * 0.5,
          nv: 1.0 + rnd.nextDouble() * 0.6,
        );
        final m = models[i % 3];
        final r = designCalc(m, p);
        acc.expectFinite(r, 'combo $i');
        expect(r.storeyForces.reduce((a, b) => a + b), closeTo(r.v, 1e-6),
            reason: 'combo $i');
        // NSCP 208.5.2.1: V >= 0.11 Ca I W always
        final ca = seismicCa(p.zone, p.soil, p.na);
        expect(r.v, greaterThanOrEqualTo(0.11 * ca * kOccupancies[p.occ].$3 * r.w - 1e-6),
            reason: 'combo $i');
      }
    });
  });

  testWidgets('UI: NSCP 2015 only - no edition selector, refs visible', (t) async {
    t.view.physicalSize = const Size(1500, 1100);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    est.newProject();
    est.models
      ..clear()
      ..add(acc.twoStorey());
    await t.pumpWidget(const MaterialApp(home: Scaffold(body: DesignView())));
    await t.pump();
    expect(find.text('DESIGN CALCULATION - NSCP 2015 (7th ed.)'), findsOneWidget);
    expect(find.text('Code edition'), findsNothing);
    expect(find.text('Ss'), findsNothing);
    expect(find.text('Seismic zone'), findsOneWidget);
    // citations render next to their check rows (criteria is on top)
    expect(find.textContaining('NSCP 2015 Table 208-11'), findsWidgets);
    // scroll the report to a deep footing row's citation
    await t.scrollUntilVisible(find.text('F1 embedment depth'), 300,
        scrollable: find.byType(Scrollable).last);
    expect(find.textContaining('S305.1 Table 305-1'), findsWidgets);
    expect(find.textContaining('8th'), findsNothing);
  });

  test('PDF export: 2015-only signature produces a real document', () async {
    final r = designCalc(acc.commercial(), DesignParams());
    final bytes = await designReportPdf(r, 'Sim');
    expect(String.fromCharCodes(bytes.sublist(0, 5)), '%PDF-');
    File('${Directory.systemTemp.path}/design_calc_2015.pdf').writeAsBytesSync(bytes);
  });
}
