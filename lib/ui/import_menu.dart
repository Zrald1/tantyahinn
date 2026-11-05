import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../boq_import.dart';
import '../models.dart';
import '../state.dart';

/// "Import" button that sits next to Export in the top bar. Opens the
/// file picker, parses the file into draft sections, then shows a
/// preview dialog where the user confirms Append vs Replace — nothing
/// touches `est.sections` until that confirm.
class ImportButton extends StatelessWidget {
  const ImportButton({super.key});

  Future<void> _import(BuildContext context) async {
    final f = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(
          label: 'BOQ files',
          extensions: ['xlsx', 'csv', 'tsv', 'txt', 'pdf', 'docx'],
        ),
        const XTypeGroup(label: 'Excel workbook', extensions: ['xlsx']),
        const XTypeGroup(label: 'PDF document', extensions: ['pdf']),
        const XTypeGroup(label: 'Word document', extensions: ['docx']),
        const XTypeGroup(
          label: 'CSV / text',
          extensions: ['csv', 'tsv', 'txt'],
        ),
      ],
    );
    if (f == null || !context.mounted) return;

    BoqImportResult result;
    try {
      result = await BoqImport.fromFile(f.path);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Import failed: $e')));
      }
      return;
    }
    if (!context.mounted) return;

    if (result.sections.isEmpty) {
      await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Nothing to import'),
          content: Text(
            'No BOQ rows were found in ${f.name}.\n\n'
            'The importer looks for a table with columns like '
            'Description, Qty, Unit and Unit Cost.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }

    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => _PreviewDialog(result: result, fileName: f.name),
    );
    if (action == null || !context.mounted) return;

    est.importBoq(result.sections, replace: action == 'replace');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Imported ${result.lineCount} item(s) in '
          '${result.sections.length} section(s) '
          '(${action == 'replace' ? 'replaced' : 'appended'}).',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: () => _import(context),
      icon: const Icon(Icons.file_upload_outlined, size: 18),
      label: const Text('Import'),
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 40),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        foregroundColor: const Color(0xFF334155),
        side: const BorderSide(color: Color(0xFFCBD5E1)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
        textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
      ),
    );
  }
}

/// What was parsed — sections, line counts, sample rows, warnings —
/// with Append / Replace / Cancel actions.
class _PreviewDialog extends StatelessWidget {
  final BoqImportResult result;
  final String fileName;
  const _PreviewDialog({required this.result, required this.fileName});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('Import BOQ'),
      contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              fileName,
              style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
            ),
            const SizedBox(height: 4),
            Text(
              '${result.sections.length} section(s) · '
              '${result.lineCount} priced item(s)'
              '${result.source.isEmpty ? '' : ' · ${result.source}'}',
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
            ),
            if (result.warnings.isNotEmpty) ...[
              const SizedBox(height: 10),
              for (final w in result.warnings)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(
                        Icons.warning_amber_rounded,
                        size: 16,
                        color: Color(0xFFD97706),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          w,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFF92400E),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
            const SizedBox(height: 10),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 300),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: result.sections.length,
                itemBuilder: (_, i) {
                  final s = result.sections[i];
                  final items = s.lines
                      .where((l) => l.kind == BoqLineKind.item)
                      .toList();
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 5,
                        ),
                        margin: const EdgeInsets.only(top: 6),
                        decoration: BoxDecoration(
                          color: cs.primary.withValues(alpha: .08),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          s.title,
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 12,
                            color: cs.primary,
                          ),
                        ),
                      ),
                      for (final l in items.take(4))
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          child: Text(
                            '${l.description} — ${l.qty} ${l.unit} '
                            '@ ${l.materialCost + l.laborCost}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 11.5),
                          ),
                        ),
                      if (items.length > 4)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Text(
                            '… ${items.length - 4} more',
                            style: const TextStyle(
                              fontSize: 11,
                              color: Color(0xFF64748B),
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        if (est.sections.isNotEmpty)
          TextButton(
            onPressed: () => Navigator.pop(context, 'replace'),
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFFDC2626),
            ),
            child: const Text('Replace current'),
          ),
        FilledButton(
          onPressed: () => Navigator.pop(context, 'append'),
          child: Text(est.sections.isEmpty ? 'Import' : 'Append'),
        ),
      ],
    );
  }
}
