import 'package:tantyahin/models.dart';
import 'package:tantyahin/state.dart';
import 'package:flutter_test/flutter_test.dart';

/// Multi-project tabs: `est` resolves to the ACTIVE session's state
/// so switching is instant and only one project renders; each tab
/// keeps its own data, view tab and office assets.
void main() {
  tearDown(projectTabs.reset);

  test('newTab activates a fresh session; switching restores est', () {
    final first = est;
    first.project.title = 'FIRST';
    first.project.themeColor = 0xFF123456;
    first.sections.add(BoqSection(title: 'A'));

    final s = projectTabs.newTab();
    expect(projectTabs.tabs.length, 2);
    expect(identical(est, first), isFalse, reason: 'active switched');
    expect(est.sections, isEmpty, reason: 'new tab starts blank');
    // office carry-over: the custom theme follows into the new tab
    expect(est.project.themeColor, 0xFF123456);

    est.project.title = 'SECOND';
    s.viewTab = 3; // left on 3D MODEL
    projectTabs.activateIndex(0);
    expect(est.project.title, 'FIRST');
    expect(est.sections.length, 1);
    expect(projectTabs.active.viewTab, 0);

    projectTabs.activate(s);
    expect(est.project.title, 'SECOND');
    expect(projectTabs.active.viewTab, 3);
  });

  test('close removes a tab and drops its autosave; last tab resets', () {
    final s = projectTabs.newTab();
    projectTabs.activateIndex(0); // go back to tab 0
    projectTabs.close(s);
    expect(projectTabs.tabs.length, 1);

    // the last tab never disappears — it resets in place instead
    est.project.title = 'WORK';
    est.sections.add(BoqSection(title: 'A'));
    projectTabs.close(projectTabs.tabs.single);
    expect(projectTabs.tabs.length, 1);
    expect(est.sections, isEmpty);
  });

  test('per-session autosave keys never collide', () {
    final s = projectTabs.newTab();
    expect(
      projectTabs.tabs.first.state.autosaveFile.path,
      isNot(s.state.autosaveFile.path),
    );
    expect(
      projectTabs.tabs.first.state.autosaveFile.path.endsWith(
        'autosave.boqproj',
      ),
      isTrue,
      reason: 'tab 0 keeps the legacy rolling file',
    );
    expect(s.state.autosaveFile.path.contains('autosave-${s.id}'), isTrue);
  });
}
