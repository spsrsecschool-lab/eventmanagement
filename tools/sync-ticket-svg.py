#!/usr/bin/env python3
"""Copies shared/ticket-svg.js into public/index.html and admin/index.html between the
// <ticket-svg> and // </ticket-svg> markers. Run after editing the shared file."""
import re, pathlib
root = pathlib.Path(__file__).resolve().parent.parent
src = (root / 'shared' / 'ticket-svg.js').read_text()
for f in ['public/index.html', 'admin/index.html']:
    p = root / f
    if not p.exists(): continue
    t = p.read_text()
    new = re.sub(r'(// <ticket-svg>\n).*?(// </ticket-svg>)', lambda m: m.group(1) + src + m.group(2), t, flags=re.S)
    if new != t: p.write_text(new); print('updated', f)
    else: print('unchanged', f)
