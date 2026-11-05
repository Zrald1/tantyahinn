"""Ground-truth geometry probe: for every sheet of an xlsx (except DATA) ask
a PRIVATE hidden Excel where the logo picture really sits relative to the
letterhead.

Prints, per sheet: the centre of the first letterhead line's merged range vs
the logo's centre (delta in px, should be ~0), and how far the logo's bottom
edge overlaps row 5 (should be negative = clear of the first text line).

Safety: same pattern as render_xlsx.py - DispatchEx (new process), aborts if
it attached to a pre-existing Excel, never saves, kills only its own PID.
"""
import os
import shutil
import subprocess
import sys
import tempfile

import win32com.client
import win32process


def excel_pids():
    out = subprocess.run(
        ['tasklist', '/FI', 'IMAGENAME eq EXCEL.EXE', '/FO', 'CSV', '/NH'],
        capture_output=True, text=True).stdout
    pids = set()
    for line in out.splitlines():
        parts = [p.strip('"') for p in line.split('","')]
        if len(parts) > 1 and parts[0].upper().startswith('EXCEL'):
            pids.add(int(parts[1]))
    return pids


src = sys.argv[1]
tmp = os.path.join(tempfile.gettempdir(), 'probe_copy.xlsx')
shutil.copyfile(src, tmp)
before = excel_pids()
xl = win32com.client.DispatchEx('Excel.Application')
_, mypid = win32process.GetWindowThreadProcessId(xl.Hwnd)
if mypid in before:
    print('ABORT: attached to a pre-existing Excel instance; not touching it')
    sys.exit(3)
try:
    xl.Visible = False
    xl.DisplayAlerts = False
    wb = xl.Workbooks.Open(tmp, ReadOnly=True)
    for ws in wb.Worksheets:
        if ws.Name == 'DATA':
            continue
        logos = [s for s in ws.Shapes if s.Name.startswith('logo')]
        first = ws.Range('A5')
        for cc in range(1, 30):
            if ws.Cells(5, cc).Value not in (None, ''):
                first = ws.Cells(5, cc)
                break
        ma = first.MergeArea
        text_c = ma.Left + ma.Width / 2
        if not logos:
            print(f'{ws.Name:13s} no logo')
            continue
        lg = logos[0]
        logo_c = lg.Left + lg.Width / 2
        row5 = ws.Range('A5').Top
        print(f'{ws.Name:13s} header-center={text_c * 96 / 72:7.1f}px '
              f'logo-center={logo_c * 96 / 72:7.1f}px '
              f'delta={(logo_c - text_c) * 96 / 72:+6.1f}px '
              f'logo-vs-row5={lg.Top + lg.Height - row5:+5.1f}pt '
              f'BR={lg.BottomRightCell.Address} (merge {ma.Address})')
    wb.Close(False)
finally:
    try:
        xl.Quit()
    except Exception:
        pass
    subprocess.run(['taskkill', '/F', '/PID', str(mypid)],
                   capture_output=True)
print('remaining excel pids:', sorted(excel_pids()))
