"""Raw-XML border verifier: does Excel get a styled <c> for EVERY grid cell?

openpyxl fabricates merged-cell borders from the anchor, so it cannot be
trusted here. This reads sheetN.xml + styles.xml directly.
"""
import re
import sys
import zipfile
import xml.etree.ElementTree as ET

NS = {'m': 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'}


def col_idx(letters):
    n = 0
    for ch in letters:
        n = n * 26 + ord(ch) - 64
    return n


def split(ref):
    m = re.match(r'([A-Z]+)(\d+)$', ref)
    return col_idx(m.group(1)), int(m.group(2))


def load(path):
    z = zipfile.ZipFile(path)
    st = ET.fromstring(z.read('xl/styles.xml'))
    borders = []
    for b in st.findall('.//m:borders/m:border', NS):
        sides = {}
        for side in ('left', 'right', 'top', 'bottom'):
            el = b.find('m:' + side, NS)
            sides[side] = bool(el is not None and el.attrib.get('style'))
        borders.append(sides)
    xfs = [borders[int(xf.attrib.get('borderId', 0))]
           for xf in st.findall('.//m:cellXfs/m:xf', NS)]
    sheets = {}
    for name, part in (('BOQ', 'sheet1'), ('POW', 'sheet2')):
        root = ET.fromstring(z.read(f'xl/worksheets/{part}.xml'))
        cells = {}
        for c in root.findall('.//m:c', NS):
            cells[split(c.attrib['r'])] = xfs[int(c.attrib.get('s', 0))]
        merges = [mc.attrib['ref'] for mc in root.findall('.//m:mergeCell', NS)]
        sheets[name] = (cells, merges)
    return sheets


def check(name, cells, merges, rows, lastcol):
    fails = []
    # 1. every merged range with a bordered anchor: all cells exist + edges
    for ref in merges:
        a, b = ref.split(':')
        c1, r1 = split(a)
        c2, r2 = split(b)
        if not any(r1 >= lo and r2 <= hi for lo, hi in rows):
            continue
        for r in range(r1, r2 + 1):
            for c in range(c1, c2 + 1):
                s = cells.get((c, r))
                if s is None:
                    fails.append(f'{name} merge {ref}: cell ({c},{r}) has NO <c>')
                    continue
                need = {'left': c == c1, 'right': c == c2,
                        'top': r == r1, 'bottom': r == r2}
                for side, req in need.items():
                    if req and not s[side]:
                        fails.append(f'{name} merge {ref}: ({c},{r}) lacks {side}')
    # 2. every table/info row: all columns exist, outer edges drawn
    covered = {}
    for ref in merges:
        a, b = ref.split(':')
        c1, r1 = split(a)
        c2, r2 = split(b)
        for r in range(r1, r2 + 1):
            for c in range(c1, c2 + 1):
                covered[(c, r)] = (c1, r1, c2, r2)
    for lo, hi in rows:
        for r in range(lo, hi + 1):
            for c in range(1, lastcol + 1):
                s = cells.get((c, r))
                if s is None:
                    fails.append(f'{name} r{r} col{c}: missing cell')
                    continue
                m = covered.get((c, r))
                top = m[1] if m else r
                bot = m[3] if m else r
                if r == top and not s['top']:
                    fails.append(f'{name} r{r} col{c}: no top border')
                if r == bot and not s['bottom']:
                    fails.append(f'{name} r{r} col{c}: no bottom border')
                left = m[0] if m else c
                right = m[2] if m else c
                if c == left and not s['left']:
                    fails.append(f'{name} r{r} col{c}: no left border')
                if c == right and not s['right']:
                    fails.append(f'{name} r{r} col{c}: no right border')
    return fails


def last_summary_row(cells, lastcol):
    rows = sorted({r for (_, r) in cells})
    return rows


if __name__ == '__main__':
    path = sys.argv[1]
    sheets = load(path)
    boq_cells, boq_merges = sheets['BOQ']
    pow_cells, pow_merges = sheets['POW']

    # locate the layout from the xml itself (works for any letterhead length):
    #  - the info block = the run of single-row label merges A{r}:C{r} (BOQ)
    #    or A{r}:B{r} (POW)
    #  - the table header = the row where column A merges down two rows
    def info_block(merges, label_col):
        rows = sorted({split(a)[1] for a, b in
                       (m.split(':') for m in merges)
                       if a[0] == 'A' and b[0] == label_col
                       and split(a)[1] == split(b)[1]})
        # keep the first run of 5 consecutive rows
        for i, r in enumerate(rows):
            if r - rows[0] == i:
                last = r
            else:
                break
        return (rows[0], last) if rows else None

    def header_row(merges):
        for m in merges:
            a, b = m.split(':')
            if a[0] == 'A' and b[0] == 'A' and split(b)[1] == split(a)[1] + 1:
                return split(a)[1]
        return None

    def extent(cells, first):
        r = first
        while (1, r) in cells and cells[(1, r)]['left']:
            r += 1
        return r - 1

    boq_info, pow_info = info_block(boq_merges, 'C'), info_block(pow_merges, 'B')
    boq_hdr, pow_hdr = header_row(boq_merges), header_row(pow_merges)
    if not all([boq_info, pow_info, boq_hdr, pow_hdr]):
        print('FAIL: could not locate info block / table header')
        sys.exit(2)
    boq_last = extent(boq_cells, boq_hdr)
    pow_last = extent(pow_cells, pow_hdr)
    print('BOQ table rows %d..%d, info rows %d..%d'
          % (boq_hdr, boq_last, *boq_info))
    print('POW table rows %d..%d, info rows %d..%d'
          % (pow_hdr, pow_last, *pow_info))
    if boq_last < boq_hdr + 5 or pow_last < pow_hdr + 5:
        print('FAIL: table extent looks wrong (vacuous check) ->',
              boq_last, pow_last)
        sys.exit(2)
    fails = check('BOQ', boq_cells, boq_merges,
                  [boq_info, (boq_hdr, boq_last)], 9)
    fails += check('POW', pow_cells, pow_merges,
                   [pow_info, (pow_hdr, pow_last)], 8)
    if fails:
        print('FAIL: %d problems' % len(fails))
        for f in fails[:40]:
            print('  ', f)
        sys.exit(1)
    print('PASS: every grid cell exists in the XML with its edge borders')
