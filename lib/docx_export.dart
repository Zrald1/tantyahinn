import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:intl/intl.dart';

import 'docx_estimate.dart';
import 'models.dart';
import 'state.dart';

/// Builds the "EXTENSION OF CONTRACT DURATION" letter as a real .docx —
/// editable in Word, matching the division's format: office letterhead,
/// the stamped creation date, a justified body, and the
/// Validated/Recommending/Approved signature block.
class DocxExport {
  static final _dateFmt = DateFormat('MMMM d, yyyy');
  static final _moneyFmt = NumberFormat('#,##0.00');

  static String _esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');

  static String _p(
    String text, {
    bool bold = false,
    String align = 'left',
    int size = 22, // half-points: 22 = 11pt
    int firstLine = 0,
    int spaceAfter = 160,
  }) {
    return '<w:p><w:pPr>'
        '<w:spacing w:after="$spaceAfter"/>'
        '${firstLine > 0 ? '<w:ind w:firstLine="$firstLine"/>' : ''}'
        '<w:jc w:val="$align"/></w:pPr>'
        '<w:r><w:rPr>${bold ? '<w:b/>' : ''}<w:sz w:val="$size"/></w:rPr>'
        '<w:t xml:space="preserve">${_esc(text)}</w:t></w:r></w:p>';
  }

  static String _cell(List<String> paras) =>
      '<w:tc><w:tcPr><w:tcW w:w="5000" w:type="dxa"/></w:tcPr>'
      '${paras.join()}</w:tc>';

  static List<int> build(ContractExtension x) {
    final p = est.project;
    final body = StringBuffer()
      ..write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
      ..write(
        '<w:document '
        'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
        '<w:body>',
      );

    // Letterhead — same lines the sheets print, bold on the office
    // line. The private template writes neither it nor its rule.
    for (var i = 0; i < p.effLetterhead.length; i++) {
      body.write(
        _p(
          p.effLetterhead[i],
          align: 'center',
          bold: i == p.letterheadBold,
          size: i == p.letterheadBold ? 24 : 21,
          spaceAfter: 20,
        ),
      );
    }
    if (p.effLetterhead.isNotEmpty) {
      // Rule under the letterhead.
      body.write(
        '<w:p><w:pPr><w:pBdr>'
        '<w:bottom w:val="single" w:sz="18" w:space="1" w:color="1E4976"/>'
        '</w:pBdr><w:spacing w:after="360"/></w:pPr></w:p>',
      );
    }

    // The stamped date — "the date the extension was created".
    body.write(
      _p(_dateFmt.format(x.createdAt), align: 'right', spaceAfter: 240),
    );
    body.write(
      _p(
        'EXTENSION OF CONTRACT DURATION',
        align: 'center',
        bold: true,
        size: 26,
        spaceAfter: 320,
      ),
    );

    final amount = x.contractAmount > 0 ? x.contractAmount : est.grandTotal;
    body
      ..write(
        _p(
          'This is in response to your letter requesting an extension of '
          'the contract duration for the project of ${x.projectRef} '
          'involving ${x.contractor}, with a total contract amount of '
          '\u20B1${_moneyFmt.format(amount)}, due to delays caused by '
          '${x.reason}.',
          align: 'both',
          firstLine: 720,
        ),
      )
      ..write(
        _p(
          'After evaluation and verification of the circumstances stated, '
          'we hereby approve your request for a ${x.days}-days extension. '
          'This extension is granted solely on the basis of '
          '${x.reasonBasis}, which are considered valid and justifiable '
          'grounds under the contract provisions.',
          align: 'both',
          firstLine: 720,
        ),
      )
      ..write(
        _p(
          'Please be reminded that this extension does not entail any '
          'additional cost to the project and that all works must be '
          'completed within the revised completion period. Kindly ensure '
          'that the remaining activities are undertaken promptly and in '
          'accordance with the approved plans, specifications, and safety '
          'standards.',
          align: 'both',
          firstLine: 720,
        ),
      )
      ..write(
        _p(
          'We look forward to the timely completion of the project within '
          'the adjusted schedule.',
          align: 'both',
          firstLine: 720,
        ),
      )
      ..write(_p('Thank you.', firstLine: 720, spaceAfter: 480));

    // Signature table: Validated | Recommending, then Approved alone.
    String name(String s) => _p(s, bold: true, size: 22, spaceAfter: 0);
    String pos(String s) => _p(s, size: 20, spaceAfter: 0);
    String label(String s) => _p(s, size: 22, spaceAfter: 560);
    body.write(
      '<w:tbl><w:tblPr>'
      '<w:tblW w:w="0" w:type="auto"/>'
      '<w:tblBorders>'
      '<w:top w:val="none"/><w:left w:val="none"/>'
      '<w:bottom w:val="none"/><w:right w:val="none"/>'
      '<w:insideH w:val="none"/><w:insideV w:val="none"/>'
      '</w:tblBorders></w:tblPr>'
      '<w:tr>'
      '${_cell([label('Validated by:'), name(x.validatedBy), pos(x.validatedPos)])}'
      '${_cell([label('Recommending Approval:'), name(x.recommendBy), pos(x.recommendPos)])}'
      '</w:tr>'
      '<w:tr>'
      '${_cell([label('Approved:'), name(x.approvedBy), pos(x.approvedPos)])}'
      '${_cell([_p('', spaceAfter: 0)])}'
      '</w:tr>'
      '</w:tbl>',
    );

    body.write(
      '<w:sectPr>'
      '<w:pgSz w:w="12240" w:h="15840"/>'
      '<w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/>'
      '</w:sectPr></w:body></w:document>',
    );

    final a = Archive();
    void add(String name, String content) {
      final b = utf8.encode(content);
      a.addFile(ArchiveFile(name, b.length, b));
    }

    add(
      '[Content_Types].xml',
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
          '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
          '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
          '<Default Extension="xml" ContentType="application/xml"/>'
          '<Override PartName="/word/document.xml" '
          'ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
          '</Types>',
    );
    add(
      '_rels/.rels',
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
          '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
          '<Relationship Id="rId1" '
          'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" '
          'Target="word/document.xml"/></Relationships>',
    );
    add('word/document.xml', body.toString());
    return ZipEncoder().encode(a)!;
  }

  /// Full estimate (BOQ, POW, PERT-CPM, network, S-CURVE) — see
  /// docx_estimate.dart.
  static Future<List<int>> buildEstimate() => DocxEstimate.build();
}
