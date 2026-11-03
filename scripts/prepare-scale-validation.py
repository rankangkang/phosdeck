#!/usr/bin/env python3
"""One-shot scale regression using two exact roots already authorized in the app.
Usage: prepare-scale-validation.py LIBRARY_COPIES_ROOT IMPORTED_BATCH_ROOT --app-support APP_SUPPORT
The test writes JPEGs only under a new hidden directory in IMPORTED_BATCH_ROOT.
APP_SUPPORT is the XCTest host application's OhMyLRC Application Support directory.
"""
import argparse, base64, json, sqlite3
from pathlib import Path
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('library', type=Path)
p.add_argument('imported', type=Path)
p.add_argument('--app-support', type=Path, required=True,
               help='explicitly authorized App Application Support directory')
a = p.parse_args()
support = a.app_support.resolve()
with sqlite3.connect((support / 'DefaultCatalog/Catalog.sqlite').as_uri() + '?mode=ro', uri=True) as db:
    db.row_factory = sqlite3.Row
    request = {}
    for key in ('library', 'imported'):
        row = db.execute('SELECT * FROM storageRoot WHERE path=?', (str(getattr(a, key).resolve()),)).fetchone()
        if row is None:
            p.error('Select both exact directories in the app first; the imported root must come from Copy Import.')
        value = dict(row)
        value['bookmark'] = base64.b64encode(value['bookmark']).decode('ascii')
        request[key] = value
folder = support / 'ScaleValidation'
folder.mkdir(exist_ok=True)
with (folder / 'request.json').open('x') as f:
    json.dump(request, f)
print('Private one-shot scale request prepared.')
