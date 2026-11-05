import 'models.dart';

/// Activity letter by position, matching ITEM NO. on the sheets
/// (A..Z, then A1, A2…).
String cpmLetter(int i) => i < 26 ? String.fromCharCode(65 + i) : 'A${i - 25}';

/// A scheduled activity: the input [a] plus its computed times and its
/// placement in the network diagram ([level] = longest-chain depth,
/// [lane] = vertical slot inside the level).
class CpmNode {
  final CpmActivity a;
  final String letter;
  double es = 0, ef = 0, ls = 0, lf = 0;
  int level = 0, lane = 0;
  final List<int> predIdx = [];
  final List<int> succIdx = [];

  CpmNode(this.a, this.letter);

  double get slack => ls - es;
  bool get critical => slack.abs() < 0.001;
}

class CpmResult {
  final List<CpmNode> nodes; // input order
  final double duration;
  final List<CpmNode> critical; // one zero-slack path, start→finish
  final String? error;

  CpmResult(this.nodes, this.duration, this.critical, this.error);

  int get maxLevel => nodes.isEmpty
      ? 0
      : nodes.map((n) => n.level).reduce((a, b) => a > b ? a : b);
  int get laneCount => nodes.isEmpty
      ? 0
      : nodes.map((n) => n.lane).reduce((a, b) => a > b ? a : b) + 1;

  String get criticalPath => critical.map((n) => n.letter).join('-');
}

/// Forward/backward pass over [acts]. Predecessor letters that don't
/// resolve are ignored; a dependency cycle reports an error instead of
/// hanging (the UI shows it, export skips the diagram).
CpmResult computeCpm(List<CpmActivity> acts) {
  if (acts.isEmpty) return CpmResult(const [], 0, const [], null);
  final nodes = [
    for (var i = 0; i < acts.length; i++) CpmNode(acts[i], cpmLetter(i)),
  ];
  final idxOf = {for (var i = 0; i < nodes.length; i++) nodes[i].letter: i};

  // Parse predecessor letters ("A,C" / "B, D") into edges.
  for (var i = 0; i < acts.length; i++) {
    for (final p in acts[i].preds.split(RegExp(r'[,;\s]+'))) {
      if (p.isEmpty) continue;
      final j = idxOf[p.trim().toUpperCase()];
      if (j != null && j != i) {
        nodes[i].predIdx.add(j);
        nodes[j].succIdx.add(i);
      }
    }
  }

  // Kahn topological order.
  final indeg = [for (final n in nodes) n.predIdx.length];
  final queue = [
    for (var i = 0; i < nodes.length; i++)
      if (indeg[i] == 0) i,
  ];
  final order = <int>[];
  while (queue.isNotEmpty) {
    final i = queue.removeAt(0);
    order.add(i);
    for (final j in nodes[i].succIdx) {
      if (--indeg[j] == 0) queue.add(j);
    }
  }
  if (order.length < nodes.length) {
    return CpmResult(
      nodes,
      0,
      const [],
      'Dependency cycle detected — check predecessors.',
    );
  }

  // Forward pass: ES = max EF of predecessors; also the layout level.
  for (final i in order) {
    final n = nodes[i];
    n.es = n.predIdx.isEmpty
        ? 0
        : n.predIdx.map((j) => nodes[j].ef).reduce((a, b) => a > b ? a : b);
    n.ef = n.es + n.a.days;
    n.level = n.predIdx.isEmpty
        ? 0
        : n.predIdx.map((j) => nodes[j].level).reduce((a, b) => a > b ? a : b) +
              1;
  }
  final duration = nodes.map((n) => n.ef).reduce((a, b) => a > b ? a : b);

  // Backward pass: LF = min LS of successors (project end when a leaf).
  for (final i in order.reversed) {
    final n = nodes[i];
    n.lf = n.succIdx.isEmpty
        ? duration
        : n.succIdx.map((j) => nodes[j].ls).reduce((a, b) => a < b ? a : b);
    n.ls = n.lf - n.a.days;
  }

  // Lanes: critical-path nodes sit on lane 0 of their level so the
  // main flow reads as one straight spine; parallel branches fill the
  // lanes below, ordered by their predecessors' average lane (the
  // barycenter heuristic — it keeps connector crossings down).
  final takenLanes = <int, Set<int>>{}; // level -> lanes in use
  double bary(CpmNode n) => n.predIdx.isEmpty
      ? 0
      : n.predIdx.map((j) => nodes[j].lane.toDouble()).reduce((x, y) => x + y) /
            n.predIdx.length;
  final sortedOrder = List<int>.of(order)
    ..sort((a, b) {
      final na = nodes[a], nb = nodes[b];
      if (na.level != nb.level) return na.level - nb.level;
      if ((na.a.lane >= 0) != (nb.a.lane >= 0)) {
        return na.a.lane >= 0 ? -1 : 1;
      }
      if (na.critical != nb.critical) return na.critical ? -1 : 1;
      return bary(na).compareTo(bary(nb));
    });
  for (final i in sortedOrder) {
    final n = nodes[i];
    final lvl = n.level;
    final taken = takenLanes.putIfAbsent(lvl, () => {});
    // a lane pinned by dragging the node wins; otherwise critical
    // spine first, then barycenter
    var want = n.a.lane >= 0 ? n.a.lane : (n.critical ? 0 : bary(n).round());
    if (want < 0) want = 0;
    // nearest free slot to `want` (probe down, then up)
    var lane = want;
    if (taken.contains(lane)) {
      for (var d = 1; ; d++) {
        if (want - d >= 0 && !taken.contains(want - d)) {
          lane = want - d;
          break;
        }
        if (!taken.contains(want + d)) {
          lane = want + d;
          break;
        }
      }
    }
    taken.add(lane);
    n.lane = lane;
  }

  // One critical path: a zero-slack start node, then follow any
  // zero-slack successor to the finish.
  CpmNode? cur;
  for (final n in nodes) {
    if (n.critical && n.predIdx.isEmpty) {
      cur = n;
      break;
    }
  }
  cur ??= nodes.where((n) => n.critical && n.es == 0).firstOrNull;
  final path = <CpmNode>[];
  while (cur != null) {
    path.add(cur);
    CpmNode? next;
    for (final j in cur.succIdx) {
      if (nodes[j].critical) {
        next = nodes[j];
        break;
      }
    }
    cur = next;
  }
  return CpmResult(nodes, duration, path, null);
}

/// Time granularity for the S-curve table/chart: per calendar day,
/// per 7-day week or per 30-day month block.
enum CurveBucket {
  day('D', 'DAY', 1),
  week('W', 'WEEK', 7),
  month('M', 'MONTH', 30);

  /// Row tag ('D5', 'W2', 'M1'), column header and days per bucket.
  final String tag;
  final String label;
  final int days;
  const CurveBucket(this.tag, this.label, this.days);
}

/// One bucket (or partial last bucket) of the planned S-curve.
class SCurveRow {
  final int week; // 1-based bucket number (day-, week- or month-#)
  final String tag; // 'D' | 'W' | 'M'
  final int fromDay; // first calendar day covered (1-based, inclusive)
  final int toDay; // last calendar day covered (inclusive)
  final double planned; // amount earned this bucket
  final double cumulative; // running total
  final double pct; // this bucket's share of the contract (0..1)
  final double cumPct; // cumulative share (0..1)

  const SCurveRow(
    this.week,
    this.tag,
    this.fromDay,
    this.toDay,
    this.planned,
    this.cumulative,
    this.pct,
    this.cumPct,
  );
}

/// Cost-weighted planned progress: each activity's cost spread evenly
/// across its available [ES, LF) window, bucketed by [bucket] (day,
/// 7-day week or 30-day month) up to [horizonDays] (the contract
/// duration; defaults to the CPM duration).
/// Critical rows have LF − ES = duration so they spread exactly as an
/// early schedule; float-rich work spreads over the whole window the
/// logic allows instead of dumping its value into a few days.
/// [weights] overrides the per-activity cost (e.g. live BOQ subtotals);
/// activities weighing 0 share a small equal weight so the curve still
/// works before prices are filled in.
///
/// [unworkableDays] spreads the pre-determined unworkable allowance
/// through the calendar: CPM times are working days, so each schedule
/// day is stretched by (CP + unworkable) / CP to land the planned
/// finish at CP + unworkable — the NIA "calendar days inclusive of
/// unworkable days" convention. When the stated CD is longer, the
/// curve simply tops out early.
List<SCurveRow> buildSCurve(
  CpmResult r, {
  double? horizonDays,
  List<double>? weights,
  double unworkableDays = 0,
  CurveBucket bucket = CurveBucket.week,
}) {
  if (r.nodes.isEmpty || r.error != null) return const [];
  final wts =
      weights ?? [for (final n in r.nodes) n.a.cost > 0 ? n.a.cost : 1.0];
  final weights2 = [for (final w in wts) w > 0 ? w : 1.0];
  final totalW = weights2.fold<double>(0, (a, b) => a + b);
  final span = unworkableDays > 0 && r.duration > 0
      ? r.duration + unworkableDays
      : r.duration;
  final factor = r.duration > 0 ? span / r.duration : 1.0;
  final horizon =
      (horizonDays != null && horizonDays > span ? horizonDays : span).clamp(
        7,
        3650,
      );
  final step = bucket.days.toDouble();
  final buckets = (horizon / step).ceil();
  final rows = <SCurveRow>[];
  var cum = 0.0;
  for (var w = 0; w < buckets; w++) {
    final from = w * step;
    final to = (from + step).clamp(0, horizon).toDouble();
    var amt = 0.0;
    for (var i = 0; i < r.nodes.length; i++) {
      final n = r.nodes[i];
      final spanDays = n.lf - n.es;
      if (spanDays <= 0) continue;
      final es = n.es * factor, lf = n.lf * factor;
      final overlap = (to < lf ? to : lf) - (from > es ? from : es);
      if (overlap > 0) {
        amt += weights2[i] / (spanDays * factor) * overlap;
      }
    }
    cum += amt;
    rows.add(
      SCurveRow(
        w + 1,
        bucket.tag,
        from.round() + 1,
        to.round(),
        amt,
        cum,
        totalW > 0 ? amt / totalW : 0,
        totalW > 0 ? cum / totalW : 0,
      ),
    );
  }
  return rows;
}

/// Parses a contract-duration string like "60 days" / "75 CALENDAR DAYS"
/// into a day count; null when nothing parses.
double? parseDays(String s) {
  final m = RegExp(r'(\d+(?:\.\d+)?)').firstMatch(s);
  return m == null ? null : double.tryParse(m.group(1)!);
}
