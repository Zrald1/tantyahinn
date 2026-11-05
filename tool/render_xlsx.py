"""Render every sheet (except DATA) of an xlsx through a PRIVATE hidden
Excel instance -> PNGs.

Safety: uses DispatchEx (new process), aborts if the instance PID is one that
already existed, never saves, and only ever kills its own PID.
"""
import os
import shutil
import subprocess
import sys
import tempfile

import fitz
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


src, outdir = sys.argv[1], sys.argv[2]
os.makedirs(outdir, exist_ok=True)
tmp = os.path.join(tempfile.gettempdir(), 'render_copy.xlsx')
shutil.copyfile(src, tmp)

before = excel_pids()
xl = win32com.client.DispatchEx('Excel.Application')
_, mypid = win32process.GetWindowThreadProcessId(xl.Hwnd)
print('pre-existing excel pids:', sorted(before), '| private instance pid:', mypid)
if mypid in before:
    print('ABORT: attached to a pre-existing Excel instance; not touching it')
    sys.exit(3)

try:
    xl.Visible = False
    xl.DisplayAlerts = False
    wb = xl.Workbooks.Open(tmp, ReadOnly=True)
    for name in [ws.Name for ws in wb.Worksheets
                 if ws.Name != 'DATA']:
        ws = wb.Worksheets(name)
        try:
            ps = ws.PageSetup
            ps.Zoom = False
            ps.FitToPagesWide = 1
            ps.FitToPagesTall = False
            # keep the workbook's own orientation (BOQ/POW portrait,
            # PERT-CPM/PERT-NETWORK/S-CURVE landscape via injected
            # <pageSetup orientation>) so the render proves what the
            # user will actually print
            ps.LeftMargin = ps.RightMargin = 20
            ps.TopMargin = ps.BottomMargin = 20
        except Exception as e:  # no printer driver etc.
            print('pagesetup skipped:', e)
        pdf = os.path.join(outdir, name + '.pdf')
        ws.ExportAsFixedFormat(0, pdf)
        doc = fitz.open(pdf)
        for i, page in enumerate(doc):
            png = os.path.join(outdir, f'{name}_p{i + 1}.png')
            page.get_pixmap(dpi=120).save(png)
            print('wrote', png)
        doc.close()
    wb.Close(False)
finally:
    try:
        xl.Quit()
    except Exception:
        pass
    del xl
    if mypid in excel_pids() and mypid not in before:
        subprocess.run(['taskkill', '/F', '/PID', str(mypid)],
                       capture_output=True)
print('done; remaining excel pids:', sorted(excel_pids()))
