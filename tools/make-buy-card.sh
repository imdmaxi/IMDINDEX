#!/usr/bin/env bash
# Renders tools/buy-card.html to web/buy/card.png (1200x1200), the preview of the X player card.
# Needs Google Chrome. Run from the repository root:  ./tools/make-buy-card.sh
set -euo pipefail

CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
PROFILE="$(mktemp -d)"
"$CHROME" --headless=new --disable-gpu --no-first-run --user-data-dir="$PROFILE" --hide-scrollbars \
  --window-size=1200,1200 --virtual-time-budget=5000 --timeout=10000 --screenshot="$PWD/web/buy/card.png" \
  "file://$PWD/tools/buy-card.html" >/dev/null 2>&1
rm -rf "$PROFILE"
echo "web/buy/card.png written"
