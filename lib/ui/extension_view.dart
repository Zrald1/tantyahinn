import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../docx_export.dart';
import '../models.dart';
import '../open_file.dart';
import '../state.dart';
import 'sheet_view.dart';

/// EXTENSION tab: creates "EXTENSION OF CONTRACT DURATION" letters.
/// Each record is stamped with the date it was created (auto-recorded,
/// shown in the list and printed on the letter) and prefilled from the
/// current project — title, contract amount, and the signatories.
class ExtensionView extends StatefulWidget {
  const ExtensionView({super.key});

  @override
  State<ExtensionView> createState() => _ExtensionViewState();
}

class _ExtensionViewState extends State<ExtensionView> {
  ContractExtension? _sel;

  static const _reasons = [
    'adverse weather conditions',
    'suspension of work (work suspension order)',
    'variation order / additional works',
    'delayed release of funds',
    'unforeseen site conditions',
    'calamity / force majeure',
  ];
  static const _bases = {
    'adverse weather conditions': 'weather-related interruptions',
    'suspension of work (work suspension order)':
        'the duly issued work suspension order',
    'variation order / additional works':
        'the approved variation order and the additional works it requires',
    'delayed release of funds': 'the delayed release of project funds',
    'unforeseen site conditions': 'unforeseen site conditions',
    'calamity / force majeure': 'the calamity, a force majeure event',
  };

  ContractExtension? get _x =>
      _sel ?? (est.extensions.isEmpty ? null : est.extensions.last);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 8, 16),
      child: Card(
        child: ListenableBuilder(
          listenable: est,
          builder: (context, _) {
            final x = _x;
            return Column(
              children: [
                _toolbar(x),
                const Divider(height: 1),
                Expanded(
                  child: x == null
                      ? _empty()
                      : Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(flex: 7, child: _preview(x)),
                            SizedBox(width: 360, child: _form(x)),
                          ],
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _empty() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.description_outlined,
            size: 56,
            color: Color(0xFFCBD5E1),
          ),
          const SizedBox(height: 14),
          const Text(
            'No extension recorded yet',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 16,
              color: Color(0xFF475569),
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Create one — today\'s date is recorded automatically and '
            'the letter prefills from your project.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12.5, color: Color(0xFF94A3B8)),
          ),
          const SizedBox(height: 12),
          FilledButton.tonal(
            onPressed: () => setState(() => _sel = est.addExtension()),
            child: const Text('New extension'),
          ),
        ],
      ),
    );
  }

  Widget _toolbar(ContractExtension? x) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(
        children: [
          const Icon(
            Icons.description_outlined,
            size: 18,
            color: Color(0xFF64748B),
          ),
          const SizedBox(width: 8),
          const Text(
            'CONTRACT EXTENSION',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 12,
              letterSpacing: 1,
              color: Color(0xFF475569),
            ),
          ),
          const SizedBox(width: 10),
          const Flexible(
            child: Text(
              'creation date is auto-recorded; fields prefill from the project',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
            ),
          ),
          // Record picker — shows the stamped creation date of each.
          if (x != null)
            DropdownButton<ContractExtension>(
              value: x,
              underline: const SizedBox(),
              items: [
                for (final e in est.extensions)
                  DropdownMenuItem(
                    value: e,
                    child: Text(
                      '${DateFormat('MMM d, yyyy').format(e.createdAt)}'
                      ' — ${e.days} days',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
              ],
              onChanged: (e) => setState(() => _sel = e),
            ),
          TextButton.icon(
            onPressed: () => setState(() => _sel = est.addExtension()),
            icon: const Icon(Icons.add, size: 16),
            label: const Text('New extension', style: TextStyle(fontSize: 12)),
          ),
          if (x != null) ...[
            TextButton.icon(
              onPressed: () => _exportDocx(x),
              icon: const Icon(Icons.download_outlined, size: 16),
              label: const Text('Save .docx', style: TextStyle(fontSize: 12)),
            ),
            IconButton(
              tooltip: 'Delete this extension',
              onPressed: () {
                est.removeExtension(x);
                setState(() => _sel = null);
              },
              icon: const Icon(
                Icons.delete_outline,
                size: 17,
                color: Colors.redAccent,
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ------------------------- letter preview -------------------------

  Widget _preview(ContractExtension x) {
    final p = est.project;
    final amount = x.contractAmount > 0 ? x.contractAmount : est.grandTotal;
    final body = const TextStyle(
      fontSize: 12,
      height: 1.55,
      color: Color(0xFF1E293B),
    );
    final money = NumberFormat('#,##0.00').format(amount);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Container(
          width: 780,
          padding: const EdgeInsets.fromLTRB(48, 24, 48, 40),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: const Color(0xFFE2E8F0)),
            borderRadius: BorderRadius.circular(6),
            boxShadow: const [
              BoxShadow(color: Color(0x11000000), blurRadius: 12),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              OfficeHeader(),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerRight,
                child: Text(
                  DateFormat('MMMM d, yyyy').format(x.createdAt),
                  style: body,
                ),
              ),
              const SizedBox(height: 22),
              const Text(
                'EXTENSION OF CONTRACT DURATION',
                textAlign: TextAlign.center,
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
              ),
              const SizedBox(height: 22),
              _par(
                body,
                'This is in response to your letter requesting an '
                'extension of the contract duration for the project of '
                '${x.projectRef} involving ${x.contractor}, with a '
                'total contract amount of \u20B1$money, due to delays '
                'caused by ${x.reason}.',
              ),
              _par(
                body,
                'After evaluation and verification of the '
                'circumstances stated, we hereby approve your request '
                'for a ${x.days}-days extension. This extension is '
                'granted solely on the basis of ${x.reasonBasis}, '
                'which are considered valid and justifiable grounds '
                'under the contract provisions.',
              ),
              _par(
                body,
                'Please be reminded that this extension does not '
                'entail any additional cost to the project and that '
                'all works must be completed within the revised '
                'completion period. Kindly ensure that the remaining '
                'activities are undertaken promptly and in accordance '
                'with the approved plans, specifications, and safety '
                'standards.',
              ),
              _par(
                body,
                'We look forward to the timely completion of the '
                'project within the adjusted schedule.',
              ),
              _par(body, 'Thank you.'),
              const SizedBox(height: 20),
              _sigRow(
                'Validated by:',
                x.validatedBy,
                x.validatedPos,
                'Recommending Approval:',
                x.recommendBy,
                x.recommendPos,
              ),
              const SizedBox(height: 26),
              _sigRow('Approved:', x.approvedBy, x.approvedPos, '', '', ''),
              const SizedBox(height: 10),
              Text(
                'project: ${p.title} • ${p.location}',
                style: const TextStyle(fontSize: 10, color: Color(0xFF94A3B8)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _par(TextStyle s, String t) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Text(t, textAlign: TextAlign.justify, style: s),
  );

  Widget _sigRow(
    String l1,
    String n1,
    String p1,
    String l2,
    String n2,
    String p2,
  ) {
    Widget col(String l, String n, String p) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l,
            style: const TextStyle(fontSize: 12, color: Color(0xFF1E293B)),
          ),
          const SizedBox(height: 34),
          Text(
            n,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 12,
              decoration: TextDecoration.underline,
            ),
          ),
          Text(
            p,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 11),
          ),
        ],
      ),
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [col(l1, n1, p1), col(l2, n2, p2)],
    );
  }

  // ------------------------- editor form ----------------------------

  Widget _form(ContractExtension x) {
    Widget field(
      String label,
      String value,
      void Function(String) set, {
      String? hint,
    }) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label.toUpperCase(),
              style: const TextStyle(
                fontSize: 9.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
                color: Color(0xFF64748B),
              ),
            ),
            InlineEdit(value: value, hint: hint ?? label, onCommit: set),
          ],
        ),
      );
    }

    return Container(
      decoration: const BoxDecoration(
        border: Border(left: BorderSide(color: Color(0xFFE2E8F0))),
        color: Color(0xFFFAFBFD),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              margin: const EdgeInsets.only(bottom: 14),
              decoration: BoxDecoration(
                color: Color(est.project.sectionColor),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.event_available,
                    size: 16,
                    color: Color(0xFF475569),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Recorded ${DateFormat('MMMM d, yyyy h:mm a').format(x.createdAt)}',
                      style: const TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            field('Project (as written on the letter)', x.projectRef, (s) {
              x.projectRef = s;
              est.update();
            }),
            field(
              'Contractor',
              x.contractor,
              (s) {
                x.contractor = s;
                est.update();
              },
              hint: 'e.g. 2 Brothers Construction Enterprises',
            ),
            field('Extension days', '${x.days}', (s) {
              final v = int.tryParse(s);
              if (v != null && v > 0) {
                x.days = v;
                est.update();
              }
            }),
            const Text(
              'REASON FOR DELAY',
              style: TextStyle(
                fontSize: 9.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
                color: Color(0xFF64748B),
              ),
            ),
            const SizedBox(height: 4),
            DropdownButtonFormField<String>(
              initialValue: _reasons.contains(x.reason) ? x.reason : null,
              isExpanded: true,
              decoration: const InputDecoration(isDense: true),
              items: [
                for (final r in _reasons)
                  DropdownMenuItem(
                    value: r,
                    child: Text(r, style: const TextStyle(fontSize: 12)),
                  ),
              ],
              onChanged: (r) {
                if (r == null) return;
                x.reason = r;
                x.reasonBasis = _bases[r] ?? r;
                est.update();
              },
            ),
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 10),
              child: InlineEdit(
                value: x.reason,
                hint: 'or type a custom reason',
                onCommit: (s) {
                  x.reason = s;
                  if (_bases[x.reason] == null) x.reasonBasis = s;
                  est.update();
                },
              ),
            ),
            field('Legal basis phrase', x.reasonBasis, (s) {
              x.reasonBasis = s;
              est.update();
            }),
            field(
              'Contract amount (₱)',
              NumberFormat('#,##0.00').format(x.contractAmount),
              (s) {
                final v = double.tryParse(s.replaceAll(',', ''));
                if (v != null) {
                  x.contractAmount = v;
                  est.update();
                }
              },
            ),
            const Divider(height: 24),
            field('Validated by — name', x.validatedBy, (s) {
              x.validatedBy = s;
              est.update();
            }),
            field('Validated by — position', x.validatedPos, (s) {
              x.validatedPos = s;
              est.update();
            }),
            field('Recommending approval — name', x.recommendBy, (s) {
              x.recommendBy = s;
              est.update();
            }),
            field('Recommending approval — position', x.recommendPos, (s) {
              x.recommendPos = s;
              est.update();
            }),
            field('Approved — name', x.approvedBy, (s) {
              x.approvedBy = s;
              est.update();
            }),
            field('Approved — position', x.approvedPos, (s) {
              x.approvedPos = s;
              est.update();
            }),
          ],
        ),
      ),
    );
  }

  Future<void> _exportDocx(ContractExtension x) async {
    final loc = await getSaveLocation(
      suggestedName:
          'Extension of Contract Duration - ${x.projectRef.isEmpty ? est.project.title : x.projectRef}.docx',
      acceptedTypeGroups: [
        const XTypeGroup(label: 'Word document', extensions: ['docx']),
      ],
    );
    if (loc == null) return;
    await File(loc.path).writeAsBytes(DocxExport.build(x));
    unawaited(openExportedFile(loc.path));
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Saved ${loc.path}')));
    }
  }
}
