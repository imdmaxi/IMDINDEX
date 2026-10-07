"""Draws the site icons from the logo mark (filled square, ring, faded square, filled square on a dark tile).

No dependencies: writes PNG and ICO with zlib/struct, antialiased by 4x4 supersampling.
Run from the repository root:  python3 tools/make-icons.py  (writes into web/)
"""

import struct
import zlib

TILE = (25, 25, 24)  # --ink
MARK = (255, 255, 255)
FADED = 0.45  # opacity of the bottom-left square, as in the CSS logo
SS = 4  # supersampling per axis


def coverage(size):
    """Per-pixel (r, g, b, a) floats for the icon at `size` pixels."""
    px = []
    n = size * SS
    s = n / 64.0  # design grid is 64 units
    tile_r = 14 * s
    # mark geometry on the 64-unit grid: 2x2 cells of 16 units, gap 4, centred
    cells = [(14, 14), (34, 14), (14, 34), (34, 34)]
    cell = 16
    for y in range(size):
        row = []
        for x in range(size):
            acc = [0.0, 0.0, 0.0, 0.0]
            for sy in range(SS):
                for sx in range(SS):
                    X = (x * SS + sx + 0.5) / s
                    Y = (y * SS + sy + 0.5) / s
                    # rounded tile
                    inside_tile = _rounded(X, Y, 0, 0, 64, 64, tile_r / s)
                    if not inside_tile:
                        continue
                    color, alpha = TILE, 1.0
                    for i, (cx, cy) in enumerate(cells):
                        if i == 1:  # ring
                            mx, my, r = cx + cell / 2, cy + cell / 2, cell / 2
                            d = ((X - mx) ** 2 + (Y - my) ** 2) ** 0.5
                            if r - 2.6 <= d <= r:
                                color = MARK
                        elif cx <= X < cx + cell and cy <= Y < cy + cell and _rounded(X, Y, cx, cy, cell, cell, 1.5):
                            if i == 2:
                                color = tuple(TILE[k] + (MARK[k] - TILE[k]) * FADED for k in range(3))
                            else:
                                color = MARK
                    for k in range(3):
                        acc[k] += color[k] * alpha
                    acc[3] += alpha
            n_samples = SS * SS
            a = acc[3] / n_samples
            if acc[3] > 0:
                rgb = [acc[k] / acc[3] for k in range(3)]
            else:
                rgb = [0, 0, 0]
            row.append((rgb[0], rgb[1], rgb[2], a))
        px.append(row)
    return px


def _rounded(X, Y, x0, y0, w, h, r):
    if not (x0 <= X < x0 + w and y0 <= Y < y0 + h):
        return False
    cx = min(max(X, x0 + r), x0 + w - r)
    cy = min(max(Y, y0 + r), y0 + h - r)
    return (X - cx) ** 2 + (Y - cy) ** 2 <= r * r


def png_bytes(size):
    px = coverage(size)
    raw = b"".join(
        b"\x00" + b"".join(bytes([round(r), round(g), round(b), round(a * 255)]) for r, g, b, a in row) for row in px
    )

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )


def ico_bytes(sizes):
    images = [png_bytes(s) for s in sizes]
    header = struct.pack("<HHH", 0, 1, len(images))
    offset = 6 + 16 * len(images)
    entries = b""
    for s, img in zip(sizes, images):
        entries += struct.pack("<BBBBHHII", s % 256, s % 256, 0, 0, 1, 32, len(img), offset)
        offset += len(img)
    return header + entries + b"".join(images)


SVG = """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
  <rect width="64" height="64" rx="14" fill="#191918"/>
  <rect x="14" y="14" width="16" height="16" rx="1.5" fill="#fff"/>
  <circle cx="42" cy="22" r="6.7" fill="none" stroke="#fff" stroke-width="2.6"/>
  <rect x="14" y="34" width="16" height="16" rx="1.5" fill="#fff" fill-opacity="0.45"/>
  <rect x="34" y="34" width="16" height="16" rx="1.5" fill="#fff"/>
</svg>
"""

MANIFEST = """{
  "name": "The Zero Person Billion Dollar Company",
  "short_name": "$COMPANY",
  "icons": [
    { "src": "/icon-192.png", "sizes": "192x192", "type": "image/png" },
    { "src": "/icon-512.png", "sizes": "512x512", "type": "image/png" }
  ],
  "theme_color": "#191918",
  "background_color": "#edece8",
  "display": "standalone"
}
"""

if __name__ == "__main__":
    import os

    os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "web"))
    open("favicon.svg", "w").write(SVG)
    open("favicon.ico", "wb").write(ico_bytes([16, 32, 48]))
    for name, size in [("favicon-32.png", 32), ("apple-touch-icon.png", 180), ("icon-192.png", 192), ("icon-512.png", 512)]:
        open(name, "wb").write(png_bytes(size))
    open("site.webmanifest", "w").write(MANIFEST)
    print("icons written")
