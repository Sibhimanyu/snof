#!/usr/bin/env bash
# Copy the live dashboard source into the harness and splice in the Firebase
# mock, so the preview always tracks the code actually under review.
set -euo pipefail
PV="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$PV/../public"

cp "$SRC/styles.css" "$SRC/app.js" "$PV/"
rm -rf "$PV/art" && cp -R "$SRC/art" "$PV/art"
python3 - "$SRC/index.html" "$PV/index.html" "$PV/stub.html" <<'EOF'
import re, sys
src = open(sys.argv[1]).read()
stub = open(sys.argv[3]).read().strip()
# Drop the Hosting-injected Firebase SDK; the stub stands in for all of it.
s = re.sub(r'<script src="/__/firebase/[^"]+"></script>\n', '', src)
s = s.replace('<script src="/app.js"></script>', stub + '\n<script src="app.js"></script>')
s = s.replace('href="/styles.css"', 'href="styles.css"')
open(sys.argv[2], 'w').write(s)
EOF
echo "synced -> $PV"
