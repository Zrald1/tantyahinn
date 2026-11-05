import 'cpm.dart';
import 'models.dart';

/// Construction-logic schedule generator (Philippine convention).
///
/// Each BOQ section becomes ONE activity named after the section —
/// only the works the user actually listed, nothing invented.
/// Predecessors come from a construction phase graph (mobilization →
/// clearing → earthworks → form/rebar → pouring → CHB → rough-ins ∥
/// roof → plaster → ceiling ∥ tiling ∥ doors/windows → painting) so
/// sections whose trades can proceed concurrently land on parallel
/// lanes (e.g. CEILING ∥ MASONRY, ELECTRICAL ∥ PLUMBING), while a
/// single-section project shows just that one activity. Phase keys
/// absent from the BOQ resolve to the nearest earlier present phase,
/// and the result is transitively reduced.
///
/// Duration derivation: each trade has a small min-days floor and the
/// contract days (CD − unworkable) are distributed over the activities
/// in proportion to their cost effort, scaled until the critical path
/// equals the target — the
/// planning model behind the NIA/DPWH rule that contract duration
/// comes out of the PERT/CPM network. Days here are working days; the
/// unworkable-days allowance is added on top when the stated CD is
/// written (est.applyCpmDuration).

/// One stage inside a trade template. [key] is the phase key, [share]
/// the portion of section cost this stage covers, [preds] phase keys
/// Bump when the trade templates / phase graph change shape so stored
/// projects re-sync onto the new topology instead of keeping a stale
/// network (the BOQ signature alone can't see template changes).
const kScheduleVersion = 4;

/// A trade template: [key] is the phase-graph slot the section
/// occupies (used for row ordering), [match] the section-title
/// keywords, [preds] the phase keys the work waits on by construction
/// convention. One activity per section — only what the user's BOQ
/// actually contains, never invented stages.
class _Trade {
  final String key;
  final List<String> match;
  final List<String> preds;
  final int minDays;
  const _Trade(this.key, this.match, this.preds, this.minDays);
}

class _Spec {
  final String id, key, name;
  final String? sectionId;
  final double costShare, weight;
  final int minDays;
  final List<String> predKeys;
  const _Spec({
    required this.id,
    required this.key,
    required this.name,
    this.sectionId,
    this.costShare = 1,
    required this.weight,
    required this.minDays,
    required this.predKeys,
  });
}

/// Phase graph: key → default predecessors used when the key has no
/// activity of its own (resolution falls back through the graph).
/// Ranks below are also this graph's topological order.
const _graph = <String, List<String>>{
  'mobl': [],
  'site': ['mobl'],
  'earth': ['site'],
  'srebar': ['mobl'],
  'form': ['mobl'],
  'cprep': ['mobl'],
  'pour': ['cprep', 'srebar', 'form', 'earth'],
  'ssteel': ['pour'],
  'chb': ['pour'],
  'elec': ['chb'],
  'plumb': ['chb'],
  'mech': ['chb'],
  'carp': ['chb'],
  'roof1': ['pour'],
  'roof2': ['roof1'],
  'plaster': ['chb'],
  'dw': ['plaster'],
  'ceil1': ['roof2'],
  'ceil2': ['ceil1', 'plaster'],
  'tile': ['plaster'],
  'paint1': ['plaster'],
  'paint2': ['paint1', 'ceil2', 'tile', 'dw'],
  'misc': ['pour'],
  'cleanup': [],
};

const _rank = <String, double>{
  'mobl': 0,
  'site': 1,
  'earth': 2,
  'srebar': 3,
  'form': 4,
  'cprep': 5,
  'pour': 6,
  'ssteel': 7,
  'chb': 8,
  'elec': 9,
  'plumb': 10,
  'mech': 11,
  'carp': 12,
  'roof1': 13,
  'roof2': 14,
  'plaster': 15,
  'dw': 16,
  'ceil1': 17,
  'tile': 18,
  'ceil2': 19,
  'paint1': 20,
  'paint2': 21,
  'misc': 50,
  'cleanup': 99,
};

/// Trade templates in match order — 'roof' before 'steel' so a
/// "STEEL TRUSS & ROOF FRAMING" section lands on roof framing.
/// Each section becomes ONE activity; [preds] are phase keys resolved
/// against the emitted sections (absent phases fall back to the
/// nearest earlier present phase), so sections that can genuinely
/// proceed concurrently land on parallel lanes.
const _trades = <_Trade>[
  _Trade(
    'mobl',
    [
      'GENERAL REQUIREMENT',
      'MOBILIZATION',
      'TEMPORARY FACILIT',
      'BILLBOARD',
      'SAFETY AND HEALTH',
      'OCCUPATIONAL SAFETY',
    ],
    [],
    3,
  ),
  _Trade(
    'site',
    [
      'SITE WORK',
      'SITE CLEAR',
      'SITE DEVELOP',
      'SITE PREPAR',
      'CLEARING',
      'DEMOLITION',
    ],
    ['mobl'],
    2,
  ),
  _Trade(
    'earth',
    [
      'EARTHWORK',
      'EXCAVATION',
      'BACKFILL',
      'FILLING',
      'GRADING',
      'DRAINAGE',
      'EMBANKMENT',
    ],
    ['site'],
    3,
  ),
  _Trade(
    'form',
    ['FORMWORK', 'FORM WORK', 'SCAFFOLD', 'FALSEWORK'],
    ['mobl'],
    2,
  ),
  _Trade('roof1', ['ROOF'], ['pour'], 4),
  _Trade(
    'srebar',
    [
      'STEEL WORK',
      'STEELWORK',
      'STRUCTURAL STEEL',
      'REINFORCING',
      'REINFORCEMENT',
      'REBAR',
      'TRUSS',
      'METAL WORK',
    ],
    ['mobl'],
    2,
  ),
  _Trade(
    'pour',
    [
      'CONCRET',
      'FOOTING',
      'COLUMN',
      'BEAM',
      'SLAB',
      'STAIR',
      'PAVEMENT',
      'CURB',
    ],
    ['earth', 'srebar', 'form'],
    7,
  ),
  _Trade(
    'chb',
    ['MASONRY', 'CHB', 'BLOCK WORK', 'BRICK', 'HOLLOW BLOCK'],
    ['pour'],
    5,
  ),
  _Trade('plaster', ['PLASTER', 'STUCCO'], ['chb'], 3),
  _Trade('elec', ['ELECTRIC', 'WIRING', 'LIGHTING', 'POWER'], ['chb'], 3),
  _Trade(
    'plumb',
    ['PLUMB', 'SANITAR', 'WATER SUPPLY', 'SEWER', 'SEPTIC', 'WATER WORK'],
    ['chb'],
    3,
  ),
  _Trade(
    'mech',
    [
      'MECHANICAL',
      'AIRCON',
      'AIR-CON',
      'HVAC',
      'VENTILAT',
      'FIRE PROTECT',
      'SPRINKLER',
      'ELEVATOR',
      'PUMP',
    ],
    ['chb'],
    3,
  ),
  // Interior ceilings hang off the roof overhead; without a roof
  // section this resolves away and the lane runs parallel to walls.
  _Trade('ceil1', ['CEILING'], ['roof2'], 3),
  _Trade(
    'tile',
    ['TILE', 'TILING', 'FLOOR', 'PAVING', 'VINYL'],
    ['plaster'],
    3,
  ),
  _Trade(
    'paint2',
    ['PAINT', 'VARNISH', 'EPOXY'],
    ['plaster', 'ceil2', 'tile', 'dw'],
    4,
  ),
  _Trade(
    'carp',
    ['CARPENTR', 'JOINERY', 'WOOD WORK', 'WOODWORK', 'LUMBER'],
    ['chb'],
    3,
  ),
  _Trade(
    'dw',
    ['DOOR', 'WINDOW', 'GLASS', 'JALOUSIE', 'ALUMINUM', 'HARDWARE'],
    ['plaster'],
    2,
  ),
];

const _misc = _Trade('misc', [], ['pour'], 3);

/// Generate the auto activity list from the BOQ sections.
/// [costOf] returns a section's live subtotal; [targetDays] is the
/// working-days target (contract duration minus unworkable days).
List<CpmActivity> generateSchedule(
  List<BoqSection> sections,
  double Function(BoqSection) costOf, {
  required double targetDays,
}) {
  _Trade classify(BoqSection s) {
    final t = s.title.toUpperCase();
    for (final tr in _trades) {
      if (tr.match.any(t.contains)) return tr;
    }
    return _misc;
  }

  // --- emit one activity per BOQ section ----------------------------------
  final keyToIds = <String, List<String>>{};
  final specs = <_Spec>[];
  void emit(_Spec sp) {
    specs.add(sp);
    keyToIds.putIfAbsent(sp.key, () => []).add(sp.id);
  }

  for (final s in sections) {
    final tr = classify(s);
    emit(
      _Spec(
        id: 'auto:${s.id}',
        key: tr.key,
        name: s.title,
        sectionId: s.id,
        costShare: 1,
        weight: costOf(s),
        minDays: tr.minDays,
        predKeys: tr.preds,
      ),
    );
  }

  // --- resolve phase keys to emitted ids --------------------------------
  Set<String> resolveKey(String key, Set<String> seen) {
    if (!seen.add(key)) return {};
    final ids = keyToIds[key];
    if (ids != null) return ids.toSet();
    final out = <String>{};
    for (final p in _graph[key] ?? const <String>[]) {
      out.addAll(resolveKey(p, seen));
    }
    return out;
  }

  final rawPreds = <String, Set<String>>{};
  for (final sp in specs) {
    final out = <String>{};
    for (final pk in sp.predKeys) {
      if (pk.startsWith('prev:')) {
        out.add(pk.substring(5));
      } else {
        out.addAll(resolveKey(pk, {}));
      }
    }
    out.remove(sp.id);
    rawPreds[sp.id] = out;
  }

  // Transitive reduction: drop pred q when another pred already
  // reaches it — keeps the diagram readable.
  bool reaches(String from, String to) {
    final seen = <String>{};
    final stack = [from];
    while (stack.isNotEmpty) {
      final cur = stack.removeLast();
      if (cur == to) return true;
      if (!seen.add(cur)) continue;
      stack.addAll(rawPreds[cur] ?? const <String>{});
    }
    return false;
  }

  for (final sp in specs) {
    final ps = rawPreds[sp.id]!;
    for (final q in List.of(ps)) {
      if (ps.any((r) => r != q && reaches(r, q))) ps.remove(q);
    }
  }

  // --- order rows: phase rank, then BOQ order ----------------------------
  final secOrder = {
    for (var i = 0; i < sections.length; i++) sections[i].id: i,
  };
  specs.sort((a, b) {
    final ra = _rank[a.key] ?? 50, rb = _rank[b.key] ?? 50;
    if (ra != rb) return ra.compareTo(rb);
    return (secOrder[a.sectionId] ?? 999) - (secOrder[b.sectionId] ?? 999);
  });

  final acts = [
    for (final sp in specs)
      CpmActivity(
        id: sp.id,
        name: sp.name,
        days: sp.minDays.toDouble(),
        auto: true,
        sectionId: sp.sectionId,
        costShare: sp.costShare,
        cost: sp.weight,
        predIds: specs
            .where((o) => rawPreds[sp.id]!.contains(o.id))
            .map((o) => o.id)
            .toList(),
      ),
  ];
  // Provisional letter preds (state re-letters after merging).
  for (var i = 0; i < acts.length; i++) {
    final index = {for (var j = 0; j < acts.length; j++) acts[j].id: j};
    acts[i].preds = acts[i].predIds
        .map((id) => index.containsKey(id) ? cpmLetter(index[id]!) : '')
        .where((s) => s.isNotEmpty)
        .join(',');
  }

  // --- fit durations to the target --------------------------------------
  final t = targetDays < 1 ? 1.0 : targetDays;
  final minOf = {
    for (var i = 0; i < acts.length; i++) acts[i].id: specs[i].minDays,
  };
  final free = acts.toList();
  // Effort-normalized durations: k is in days, so an activity takes its
  // cost share of k. lo=0 always satisfies CP<=t (min-days floor); the
  // warmup grows hi until CP>=t brackets the answer.
  final totalW = free.fold<double>(0, (s, a) => s + a.cost);
  double daysFor(CpmActivity a, double k) {
    if (totalW <= 0) return minOf[a.id]!.toDouble();
    return (a.cost / totalW * k).roundToDouble().clamp(
      minOf[a.id]!.toDouble(),
      t,
    );
  }

  double cpAt(double k) {
    for (final a in free) {
      a.days = daysFor(a, k);
    }
    return cpDuration(acts);
  }

  var lo = 0.0, hi = t;
  while (cpAt(hi) < t && hi < 36500) {
    hi *= 2;
    if (hi > 36500) hi = 36500;
  }
  for (var it = 0; it < 60; it++) {
    final mid = (lo + hi) / 2;
    if (cpAt(mid) <= t) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  for (final a in free) {
    a.days = daysFor(a, lo);
  }
  // Reconcile rounding: nudge critical activities ±1 day onto t,
  // spread round-robin so the adjustment isn't dumped on one row.
  for (var it = 0, turn = 0; it < 400; it++) {
    final d = cpDuration(acts);
    if (d == t || d < 0) break;
    final res = computeCpm(acts);
    if (res.error != null) break;
    final critFree = res.nodes
        .where((n) => n.critical && free.contains(n.a))
        .map((n) => n.a)
        .toList();
    if (critFree.isEmpty) break;
    if (d < t) {
      critFree.sort((a, b) => b.cost.compareTo(a.cost));
      critFree[turn++ % critFree.length].days += 1;
    } else {
      critFree.sort((a, b) => a.days.compareTo(b.days));
      final shrinkable = critFree.where((a) => a.days > minOf[a.id]!).toList();
      if (shrinkable.isEmpty) break;
      shrinkable[turn++ % shrinkable.length].days -= 1;
    }
  }
  return acts;
}

/// Longest-path duration on the [CpmActivity.predIds] graph
/// (Kahn + forward pass). Returns -1 on a dependency cycle.
double cpDuration(List<CpmActivity> acts) {
  final idx = {for (var i = 0; i < acts.length; i++) acts[i].id: i};
  final indeg = List<int>.filled(acts.length, 0);
  final succ = <int, List<int>>{};
  for (var i = 0; i < acts.length; i++) {
    for (final p in acts[i].predIds) {
      final j = idx[p];
      if (j != null && j != i) {
        indeg[i]++;
        succ.putIfAbsent(j, () => []).add(i);
      }
    }
  }
  final ef = List<double>.filled(acts.length, 0);
  final q = [
    for (var i = 0; i < acts.length; i++)
      if (indeg[i] == 0) i,
  ];
  var done = 0;
  var best = 0.0;
  while (q.isNotEmpty) {
    final i = q.removeAt(0);
    done++;
    var es = 0.0;
    for (final p in acts[i].predIds) {
      final j = idx[p];
      if (j != null && ef[j] > es) es = ef[j];
    }
    ef[i] = es + acts[i].days;
    if (ef[i] > best) best = ef[i];
    for (final j in succ[i] ?? const <int>[]) {
      if (--indeg[j] == 0) q.add(j);
    }
  }
  return done < acts.length ? -1 : best;
}
