"""Plate colour candidates for the two-tone g1 glyph, each shown on light and dark wallpaper."""

from pathlib import Path

from gen import INK, PAPER, SKY, TEAL
from gen_ctx import glyph, place, text, dummy

OUT = Path(__file__).parent / "plates"
C = 256

# name: (plate fill, extra plate markup, left half, right half, defs)
CANDIDATES = {
    "a  ink (current)": (INK, "", TEAL, SKY, ""),
    "b  slate teal #134E5E": ("#134E5E", "", TEAL, SKY, ""),
    "c  teal gradient": ("url(#pc)", "", TEAL, SKY,
        '<linearGradient id="pc" x1="0" y1="0" x2="0.6" y2="1"><stop offset="0" stop-color="#1F5F6E"/><stop offset="1" stop-color="#0B2A33"/></linearGradient>'),
    "d  navy gradient": ("url(#pd)", "", TEAL, SKY,
        '<linearGradient id="pd" x1="0" y1="0" x2="0.6" y2="1"><stop offset="0" stop-color="#23407A"/><stop offset="1" stop-color="#0F1B3D"/></linearGradient>'),
    "e  ink + rim + sheen": ("url(#pe)", "rim", TEAL, SKY,
        '<linearGradient id="pe" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#1A3A42"/><stop offset="1" stop-color="#0B1F24"/></linearGradient>'),
    "f  graphite #2B3440": ("#2B3440", "", TEAL, SKY, ""),
    "g  deep teal to blue": ("url(#pg)", "", TEAL, SKY,
        '<linearGradient id="pg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#0F4A52"/><stop offset="1" stop-color="#153A6B"/></linearGradient>'),
    "h  light (reference)": (PAPER, "", "#0D9488", "#0284C7", ""),
}


def icon(name, shape):
    fill, extra, l, r, _ = CANDIDATES[name]
    if shape == "circle":
        plate = f'<circle cx="{C}" cy="{C}" r="{C}" fill="{fill}"/>'
        rim = f'<circle cx="{C}" cy="{C}" r="{C - 5}" fill="none" stroke="white" stroke-opacity="0.22" stroke-width="10"/>'
        scale = 0.85
    else:
        plate = f'<rect x="16" y="16" width="480" height="480" rx="112" fill="{fill}"/>'
        rim = '<rect x="21" y="21" width="470" height="470" rx="107" fill="none" stroke="white" stroke-opacity="0.22" stroke-width="10"/>'
        scale = 1.0
    return plate + (rim if extra == "rim" else "") + glyph(l, r, scale)


TW, TH = 680, 170  # tile
W = 2 * TW + 60
rows = (len(CANDIDATES) + 1) // 2
H = rows * (TH + 20) + 20
out = []
for i, name in enumerate(CANDIDATES):
    tx = 20 + (i % 2) * (TW + 20)
    ty = 20 + (i // 2) * (TH + 20)
    out.append(text(tx, ty + 18, name, 15, "#111", "start", "bold"))
    for k, (wall, dock) in enumerate((("url(#wl)", "rgba(255,255,255,0.55)"), ("url(#wd)", "rgba(40,40,40,0.6)"))):
        px = tx + k * (TW / 2 + 5)
        pw = TW / 2 - 5
        out.append(f'<rect x="{px}" y="{ty + 28}" width="{pw}" height="{TH - 28}" rx="12" fill="{wall}"/>')
        # Android pair with a neighbour, then a dock pair with a neighbour.
        out.append(dummy("circle", "#EA4335", px + 14, ty + 54, 64))
        out.append(place(icon(name, "circle"), px + 88, ty + 46, 80))
        out.append(f'<rect x="{px + 180}" y="{ty + 46}" width="146" height="96" rx="20" fill="{dock}"/>')
        out.append(place(icon(name, "squircle"), px + 188, ty + 54, 80))
        out.append(dummy("sq", "#5E5CE6", px + 272, ty + 70, 48))

defs = "".join(c[4] for c in CANDIDATES.values()) + (
    '<linearGradient id="wl" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#EAF0F7"/><stop offset="1" stop-color="#C4D3E4"/></linearGradient>'
    '<linearGradient id="wd" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#1D2433"/><stop offset="1" stop-color="#07090D"/></linearGradient>'
)
svg = (
    f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">'
    f'<defs>{defs}</defs><rect width="{W}" height="{H}" fill="white"/>{"".join(out)}</svg>'
)

if __name__ == "__main__":
    OUT.mkdir(exist_ok=True)
    (OUT / "plates.svg").write_text(svg)
