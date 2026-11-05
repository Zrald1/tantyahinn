import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tantyahin/state.dart';

void main() {
  test('real legacy .boqproj (Downloads/estimate.boqproj) opens', () {
    final f = File(r'C:\Users\Zrald\Downloads\estimate.boqproj');
    if (!f.existsSync()) return; // file is user data — skip if absent
    final j = jsonDecode(f.readAsStringSync());
    final e = EstimateState();
    e.loadJson(Map<String, dynamic>.from(j as Map));

    // sections + project info survived
    expect(e.sections.length, 4);
    expect(e.project.title, isNotEmpty);

    // schedule re-syncs onto the one-activity-per-section model
    e.syncSchedule();
    final names = e.activities.map((a) => a.name).toList();
    for (final s in e.sections) {
      expect(names, contains(s.title));
    }

    // management board seeds from the loaded sections
    e.syncTrackItems();
    expect(e.trackItems.length, e.sections.length);
    expect(e.overallProgress, 0);
  });
}
