"""g1 / g2 (and a light variant) mocked up where each platform actually shows the icon."""

from pathlib import Path

from gen import INK, PAPER, SKY, TEAL
from gen_g import GRAD, SHIFT, half

OUT = Path(__file__).parent / "ctx"
FONT = 'font-family="DejaVu Sans, sans-serif"'
C = 256

VARIANTS = {  # name: (plate fill, left half, right half)
    "g1": (INK, TEAL, SKY),
    "g2": ("url(#g)", "white", "white"),
    "light": (PAPER, "#0D9488", "#0284C7"),
}


def glyph(left, right, scale=1.0):
    body = half(-1, left, -SHIFT) + half(1, right, SHIFT)
    return f'<g transform="translate({C},{C}) scale({scale}) translate({-C},{-C})">{body}</g>'


def place(content, x, y, size):
    return f'<g transform="translate({x},{y}) scale({size / 512})">{content}</g>'


def android(v):
    fill, l, r = VARIANTS[v]
    return f'<circle cx="{C}" cy="{C}" r="{C}" fill="{fill}"/>' + glyph(l, r, 0.85)


def squircle(v):
    fill, l, r = VARIANTS[v]
    return f'<rect x="16" y="16" width="480" height="480" rx="112" fill="{fill}"/>' + glyph(l, r)


def bare(l=TEAL, r=SKY):
    """No plate, glyph grown to fill the box: taskbar, tray, favicon."""
    return glyph(l, r, 1.42)


def dummy(shape, color, x, y, size):
    s = size
    plate = (
        f'<circle cx="{x + s / 2}" cy="{y + s / 2}" r="{s / 2}" fill="{color}"/>'
        if shape == "circle"
        else f'<rect x="{x + s * 0.03}" y="{y + s * 0.03}" width="{s * 0.94}" height="{s * 0.94}" rx="{s * 0.22}" fill="{color}"/>'
    )
    return plate + f'<rect x="{x + s * 0.32}" y="{y + s * 0.32}" width="{s * 0.36}" height="{s * 0.36}" rx="{s * 0.08}" fill="white" opacity="0.9"/>'


def text(x, y, s, size=13, color="#222", anchor="middle", weight="normal"):
    return f'<text x="{x}" y="{y}" {FONT} font-size="{size}" fill="{color}" text-anchor="{anchor}" font-weight="{weight}">{s}</text>'


def panel(x, y, w, h, bg):
    return f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="12" fill="{bg}"/>'


W = 1400
LX = 250  # panels start here, the row label sits to the left
PW = 560  # panel width
out, y = [], 20


def row_label(title, sub):
    out.append(text(24, y + 40, title, 17, "#111", "start", "bold"))
    out.append(text(24, y + 62, sub, 12, "#666", "start"))


# Android home screen, light and dark wallpaper.
h = 170
row_label("Android", "home screen, 96 px")
for i, (bg, fg) in enumerate(((("url(#wl)"), "#222"), ("url(#wd)", "#EEE"))):
    px = LX + i * (PW + 30)
    out.append(panel(px, y, PW, h, bg))
    items = [("d", "#EA4335"), ("g1", None), ("g2", None), ("light", None), ("d", "#34A853")]
    for j, (name, col) in enumerate(items):
        ix = px + 24 + j * 106
        if col:
            out.append(dummy("circle", col, ix, y + 26, 90))
            out.append(text(ix + 45, y + 140, "App", 13, fg))
        else:
            out.append(place(android(name), ix, y + 26, 90))
            out.append(text(ix + 45, y + 140, f"dsync ({name})", 12, fg))
y += h + 30

# Android themed + iOS tinted: one mono shape, the OS picks the colours.
h = 150
row_label("Themed / tinted", "Android 13+, iOS 18 tinted")
tints = [("#DCE4F2", "#2C4A6E", "Android light"), ("#2C3A4C", "#C3D5EE", "Android dark"),
         ("#1C1C1E", "#F5B34A", "iOS tinted amber"), ("#1C1C1E", "#8AB4F8", "iOS tinted blue")]
out.append(panel(LX, y, PW * 2 + 30, h, "#F0F1F3"))
for j, (plate, ink, label) in enumerate(tints):
    ix = LX + 40 + j * 290
    shape = (f'<circle cx="{C}" cy="{C}" r="{C}" fill="{plate}"/>' if j < 2
             else f'<rect x="16" y="16" width="480" height="480" rx="112" fill="{plate}"/>')
    out.append(place(shape + glyph(ink, ink, 0.85), ix, y + 22, 90))
    out.append(text(ix + 45, y + 135, label, 12, "#333"))
y += h + 30

# macOS dock.
h = 150
row_label("macOS", "dock, 80 px")
for i, (wall, dock) in enumerate((("url(#wl)", "rgba(255,255,255,0.55)"), ("url(#wd)", "rgba(40,40,40,0.6)"))):
    px = LX + i * (PW + 30)
    out.append(panel(px, y, PW, h, wall))
    out.append(f'<rect x="{px + 30}" y="{y + 30}" width="{PW - 60}" height="100" rx="24" fill="{dock}"/>')
    items = [("d", "#5E5CE6"), ("g1", None), ("g2", None), ("light", None), ("d", "#FBBC04")]
    for j, (name, col) in enumerate(items):
        ix = px + 50 + j * 94
        if col:
            out.append(dummy("sq", col, ix, y + 40, 80))
        else:
            out.append(place(squircle(name), ix, y + 40, 80))
y += h + 30

# Windows taskbar, 24 px, light and dark.
h = 110
row_label("Windows", "taskbar, 24 px")
for i, (bg, fg) in enumerate((("#F3F3F3", "#222"), ("#202020", "#EEE"))):
    px = LX + i * (PW + 30)
    out.append(panel(px, y, PW, h, bg))
    items = [("bare", bare()), ("g1", squircle("g1")), ("g2", squircle("g2")), ("light", squircle("light"))]
    for j, (label, art) in enumerate(items):
        ix = px + 40 + j * 130
        out.append(f'<rect x="{ix - 12}" y="{y + 18}" width="48" height="48" rx="6" fill="{fg}" opacity="0.06"/>')
        out.append(place(art, ix, y + 30, 24))
        out.append(text(ix + 12, y + 92, label, 12, fg))
y += h + 30

# Tray / menu bar, 16 px.
h = 110
row_label("Tray / menu bar", "16 px")
for i, (bg, fg, mono) in enumerate((("#E9E9EB", "#222", "#111"), ("#1E1E1E", "#EEE", "#FFF"))):
    px = LX + i * (PW + 30)
    out.append(panel(px, y, PW, h, bg))
    items = [("mono", bare(mono, mono)), ("two-tone", bare()), ("g1", squircle("g1")), ("g2", squircle("g2"))]
    for j, (label, art) in enumerate(items):
        ix = px + 50 + j * 130
        out.append(place(art, ix, y + 34, 16))
        out.append(text(ix + 8, y + 88, label, 12, fg))
y += h + 30

# Browser tab favicon, 16 px.
h = 110
row_label("Browser tab", "favicon, 16 px")
for i, (bar, tab, fg) in enumerate((("#DEE1E6", "#FFFFFF", "#222"), ("#202124", "#35363A", "#EEE"))):
    px = LX + i * (PW + 30)
    out.append(panel(px, y, PW, h, bar))
    items = [("two-tone", bare()), ("g1", squircle("g1")), ("g2", squircle("g2"))]
    for j, (label, art) in enumerate(items):
        tx = px + 16 + j * 180
        out.append(f'<rect x="{tx}" y="{y + 30}" width="170" height="38" rx="8" fill="{tab}"/>')
        out.append(place(art, tx + 12, y + 41, 16))
        out.append(text(tx + 36, y + 54, "dsync", 13, fg, "start"))
        out.append(text(tx + 85, y + 92, label, 12, fg))
y += h + 20

defs = (
    GRAD
    + '<linearGradient id="wl" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#EAF0F7"/><stop offset="1" stop-color="#C4D3E4"/></linearGradient>'
    + '<linearGradient id="wd" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#1D2433"/><stop offset="1" stop-color="#07090D"/></linearGradient>'
)
svg = (
    f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{y}" viewBox="0 0 {W} {y}">'
    f'<defs>{defs}</defs><rect width="{W}" height="{y}" fill="white"/>{"".join(out)}</svg>'
)

if __name__ == "__main__":
    OUT.mkdir(exist_ok=True)
    (OUT / "context.svg").write_text(svg)
