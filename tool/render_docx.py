"""Render a docx through a PRIVATE hidden Word instance -> one PNG per page
(<out>_p1.png, ...).
Safety: DispatchEx gives a new process; PID is found by diffing the
WINWORD process list before/after dispatch; never saves; kills only
the PID it created.
"""
import os
import shutil
import subprocess
import sys
import tempfile
import time

import fitz
import win32com.client


def word_pids():
    out = subprocess.run(
        ['tasklist', '/FI', 'IMAGENAME eq WINWORD.EXE', '/FO', 'CSV', '/NH'],
        capture_output=True, text=True).stdout
    pids = set()
    for line in out.splitlines():
        parts = [p.strip('"') for p in line.split('","')]
        if len(parts) > 1 and parts[0].upper().startswith('WINWORD'):
            pids.add(int(parts[1]))
    return pids


src, outpng = sys.argv[1], sys.argv[2]
tmp = os.path.join(tempfile.gettempdir(), 'render_copy.docx')
shutil.copyfile(src, tmp)

before = word_pids()
wd = win32com.client.DispatchEx('Word.Application')
time.sleep(1.5)
mypids = word_pids() - before
mypid = mypids.pop() if mypids else None
print('pre-existing word pids:', sorted(before), '| private pid:', mypid)

try:
    wd.Visible = False
    wd.DisplayAlerts = 0
    doc = wd.Documents.Open(tmp, ReadOnly=True)
    pdf = os.path.join(tempfile.gettempdir(), 'render_docx.pdf')
    doc.ExportAsFixedFormat(pdf, 17)  # wdExportFormatPDF
    doc.Close(False)
    d = fitz.open(pdf)
    base = outpng[:-4] if outpng.lower().endswith('.png') else outpng
    for i, page in enumerate(d):
        out = f'{base}_p{i + 1}.png'
        page.get_pixmap(dpi=110).save(out)
        print('wrote', out, page.rect.width, page.rect.height)
finally:
    try:
        wd.Quit()
    except Exception:
        pass
    del wd
    time.sleep(0.5)
    if mypid and mypid in word_pids():
        subprocess.run(['taskkill', '/F', '/PID', str(mypid)],
                       capture_output=True)
print('done; remaining word pids:', sorted(word_pids()))
