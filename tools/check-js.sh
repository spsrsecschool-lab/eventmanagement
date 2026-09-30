#!/bin/sh
# node --check every inline <script> in the HTML pages and every api/*.js file.
cd "$(dirname "$0")/.." || exit 1
fail=0
for f in public/index.html admin/index.html scanner/index.html; do
  python3 - "$f" <<'PY' || fail=1
import re, sys, subprocess, tempfile, os
t = open(sys.argv[1]).read()
blocks = re.findall(r'<script(?![^>]*\bsrc=)[^>]*>(.*?)</script>', t, flags=re.S)
ok = True
for i, b in enumerate(blocks):
    with tempfile.NamedTemporaryFile('w', suffix='.js', delete=False) as tf: tf.write(b)
    r = subprocess.run(['node', '--check', tf.name], capture_output=True, text=True); os.unlink(tf.name)
    if r.returncode: ok = False; print(sys.argv[1], 'script', i, 'FAILED\n', r.stderr)
print(sys.argv[1], 'OK' if ok else 'FAILED', f'({len(blocks)} scripts)')
sys.exit(0 if ok else 1)
PY
done
for f in admin/api/*.js shared/ticket-svg.js; do node --check "$f" || fail=1; done
[ $fail = 0 ] && echo "all JS OK"; exit $fail
