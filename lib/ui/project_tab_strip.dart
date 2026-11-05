// Browser-style project tab strip - part of ../main.dart
// (keeps main.dart under the ~1000-line cap).
part of '../main.dart';

/// Browser-style project tab strip: one chip per open project, the
/// active one raised, a close × per tab and a trailing + for a new
/// tab. Only the ACTIVE session's state is bound to the UI — this
/// strip is the whole cost of having many projects open.
class _ProjectTabs extends StatelessWidget {
  const _ProjectTabs();

  Future<void> _closeTab(BuildContext context, ProjectSession s) async {
    // only a tab with real content earns a confirm — closing drops
    // its rolling autosave along with the tab
    if (projectTabs.tabs.length > 1 && s.hasContent && context.mounted) {
      final name = s.state.project.title.isEmpty
          ? 'Untitled project'
          : s.state.project.title;
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Close project tab'),
          content: Text(
            'Close "$name"? Unsaved work in this tab is discarded.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Close tab'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    projectTabs.close(s);
  }

  Widget _chip(BuildContext context, ProjectSession s) {
    final sel = identical(s, projectTabs.active);
    final t = s.state.project.title;
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 5),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () => projectTabs.activate(s),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          constraints: const BoxConstraints(maxWidth: 220),
          padding: const EdgeInsets.only(left: 10, right: 3),
          decoration: BoxDecoration(
            color: sel ? Colors.white : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: sel
                  ? cs.primary.withValues(alpha: .45)
                  : Colors.transparent,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  t.isEmpty ? 'Untitled project' : t,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
                    color: sel
                        ? const Color(0xFF0F172A)
                        : const Color(0xFF64748B),
                  ),
                ),
              ),
              Tooltip(
                message: 'Close tab',
                excludeFromSemantics: true,
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => _closeTab(context, s),
                  child: Padding(
                    padding: const EdgeInsets.all(3),
                    child: Icon(
                      Icons.close,
                      semanticLabel: 'Close tab',
                      size: 12,
                      color: sel
                          ? const Color(0xFF64748B)
                          : const Color(0xFF94A3B8),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // one project open = zero chrome — the strip appears the moment a
    // second tab exists and disappears when back to one, like editors
    // that auto-hide their tab bar
    if (projectTabs.tabs.length <= 1) return const SizedBox.shrink();
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: const BoxDecoration(
        color: Color(0xFFF1F5F9),
        border: Border(bottom: BorderSide(color: Color(0xFFE2E8F0))),
      ),
      child: Row(
        children: [
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [for (final s in projectTabs.tabs) _chip(context, s)],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.add, size: 16),
            tooltip: 'New project tab',
            visualDensity: VisualDensity.compact,
            onPressed: () => projectTabs.newTab(),
          ),
        ],
      ),
    );
  }
}
