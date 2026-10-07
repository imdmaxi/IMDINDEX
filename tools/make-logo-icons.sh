#!/usr/bin/env bash
# Builds the website's logo and icons from brand/logo-imd1679.svg (the logo with IMD NFT #1679, whose artwork
# is read on-chain from the identity.md contract 0x0000ec93127baa929e58e97dd0095a2bfb38ec1d).
# macOS only (rasterizes with Quick Look). Run from the repository root:  ./tools/make-logo-icons.sh
set -euo pipefail

SRC=brand/logo-imd1679.svg
TMP="$(mktemp -d)"
cp "$SRC" web/logo.svg
cp "$SRC" web/favicon.svg

for s in 16 32 48 180 192 400 512; do
  qlmanage -t -s "$s" -o "$TMP" "$SRC" >/dev/null 2>&1
  mv "$TMP/$(basename "$SRC").png" "$TMP/$s.png"
done

cp "$TMP/32.png" web/favicon-32.png
cp "$TMP/180.png" web/apple-touch-icon.png
cp "$TMP/192.png" web/icon-192.png
cp "$TMP/512.png" web/icon-512.png
cp "$TMP/400.png" brand/logo-400-imd1679.png

# favicon.ico holding the 16, 32 and 48 px PNGs
python3 - "$TMP" <<'PY'
import struct, sys
tmp = sys.argv[1]
sizes = [16, 32, 48]
imgs = [open(f"{tmp}/{s}.png", "rb").read() for s in sizes]
out = struct.pack("<HHH", 0, 1, len(imgs))
off = 6 + 16 * len(imgs)
for s, img in zip(sizes, imgs):
    out += struct.pack("<BBBBHHII", s, s, 0, 0, 1, 32, len(img), off)
    off += len(img)
open("web/favicon.ico", "wb").write(out + b"".join(imgs))
PY

rm -rf "$TMP"
echo "logo and icons written to web/ and brand/"
