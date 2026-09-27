"""Generates the d/b mirror icon drafts as SVGs on a 512 canvas."""

import math
from pathlib import Path

OUT = Path(__file__).parent
W = 56  # glyph stroke width
R = 80  # bowl radius (stroke centre line)
TOP, BASE = 112, 400  # stem top, baseline (stroke centre)
BOWL_Y = BASE - R

TEAL, SKY, INK, PAPER = "#2DD4BF", "#38BDF8", "#0B1F24", "#F4F7F6"


def svg(body, defs=""):
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">'
        f"<defs>{defs}</defs>{body}</svg>"
    )


def plate(fill, shape="squircle"):
    if shape == "circle":
        return f'<circle cx="256" cy="256" r="240" fill="{fill}"/>'
    return f'<rect x="16" y="16" width="480" height="480" rx="112" fill="{fill}"/>'


def stroke(d, color, w=W, cap="round", extra=""):
    return (
        f'<path d="{d}" fill="none" stroke="{color}" stroke-width="{w}" '
        f'stroke-linecap="{cap}" stroke-linejoin="round" {extra}/>'
    )


def ring(cx, cy=BOWL_Y, r=R):
    return f"M{cx - r},{cy} a{r},{r} 0 1,0 {2 * r},0 a{r},{r} 0 1,0 {-2 * r},0"


def stem(x, top=TOP, base=BASE):
    return f"M{x},{top} L{x},{base}"


def pt(cx, cy, r, deg):
    a = math.radians(deg)
    return cx + r * math.cos(a), cy + r * math.sin(a)


def arc(cx, cy, r, a0, a1):
    """Arc from angle a0 to a1 (degrees, screen coords, clockwise positive)."""
    x0, y0 = pt(cx, cy, r, a0)
    x1, y1 = pt(cx, cy, r, a1)
    large = 1 if abs(a1 - a0) > 180 else 0
    sweep = 1 if a1 > a0 else 0
    return f"M{x0:.1f},{y0:.1f} A{r},{r} 0 {large},{sweep} {x1:.1f},{y1:.1f}"


def arrowhead(cx, cy, r, deg, clockwise, color, size=64):
    """Filled triangle at angle `deg`, pointing along the direction of travel."""
    x, y = pt(cx, cy, r, deg)
    a = math.radians(deg)
    tx, ty = (-math.sin(a), math.cos(a)) if clockwise else (math.sin(a), -math.cos(a))
    nx, ny = math.cos(a), math.sin(a)
    tip = (x + tx * size * 0.75, y + ty * size * 0.75)
    l = (x + nx * size * 0.7, y + ny * size * 0.7)
    rr = (x - nx * size * 0.7, y - ny * size * 0.7)
    pts = " ".join(f"{px:.1f},{py:.1f}" for px, py in (tip, l, rr))
    return f'<polygon points="{pts}" fill="{color}" stroke="{color}" stroke-width="10" stroke-linejoin="round"/>'


# b stem left, d stem right, bowls overlap in the middle ("bd").
BX, DX = 104, 408
BCX, DCX = BX + R, DX - R  # 184, 328


def a_overlap_two_tone():
    b = stroke(stem(BX), TEAL) + stroke(ring(BCX), TEAL)
    d = stroke(stem(DX), SKY) + stroke(ring(DCX), SKY)
    mask = (
        '<mask id="bmask"><rect width="512" height="512" fill="black"/>'
        + stroke(ring(BCX), "white")
        + "</mask>"
    )
    lens = stroke(ring(DCX), "#FFFFFF", extra='mask="url(#bmask)"')
    return svg(plate(INK) + b + d + lens, mask)


def b_overlap_mono():
    grad = (
        '<linearGradient id="g" x1="0" y1="0" x2="1" y2="1">'
        '<stop offset="0" stop-color="#14B8A6"/><stop offset="1" stop-color="#0E7490"/>'
        "</linearGradient>"
    )
    glyph = "".join(
        stroke(p, "white") for p in (stem(BX), ring(BCX), stem(DX), ring(DCX))
    )
    return svg(plate("url(#g)") + glyph, grad)


def c_shared_spine():
    # "db": stems merge into one shared spine, bowls outward.
    sx = 256
    left, right = sx - R, sx + R
    body = (
        stroke(ring(left), TEAL)
        + stroke(ring(right), SKY)
        + stroke(stem(sx), INK)
    )
    return svg(plate(PAPER) + body)


def d_counter_rotating():
    # Smaller, separate bowls, each an open arc with an arrow: two wheels turning opposite ways.
    r = 60
    by = BASE - r
    bcx, dcx = BX + r, DX - r
    b_arc = arc(bcx, by, r, 180, 420)  # from the stem, over the top, round to the bottom
    d_arc = arc(dcx, by, r, 0, -240)  # mirrored
    body = (
        stroke(stem(BX), TEAL)
        + stroke(b_arc, TEAL, cap="butt")
        + arrowhead(bcx, by, r, 420, True, TEAL, size=54)
        + stroke(stem(DX), SKY)
        + stroke(d_arc, SKY, cap="butt")
        + arrowhead(dcx, by, r, -240, False, SKY, size=54)
    )
    return svg(plate(INK) + body)


def e_interlocked():
    # Bowls woven like chain links: d over b at the top crossing, b over d at the bottom.
    bg, w, h = INK, 46, 44
    bcx, dcx = 256 - h, 256 + h
    bx, dx = bcx - R, dcx + R
    body = (
        stroke(stem(bx), TEAL, w=w)
        + stroke(ring(bcx), TEAL, w=w)
        + stroke(stem(dx), SKY, w=w)
        + stroke(ring(dcx), SKY, w=w)
    )
    cross = math.degrees(math.atan2(math.sqrt(R**2 - h**2), h))

    def over(cx, a, color):
        seg = arc(cx, BOWL_Y, R, a - 20, a + 20)
        return stroke(seg, bg, w=w + 20, cap="butt") + stroke(seg, color, w=w, cap="butt")

    # top crossing: d passes over (angle measured on d's circle); bottom: b over.
    return svg(
        plate(bg, "circle") + body
        + over(dcx, 180 + cross, SKY)
        + over(bcx, cross, TEAL)
    )


def f_stem_arrows():
    # Ascenders carry arrows: b's points up (send), d's has a down chevron cut in (receive).
    ink = "#0F766E"
    rings = stroke(ring(BCX), ink) + stroke(ring(DCX), ink)
    up = stroke(stem(BX), ink) + stroke(
        f"M{BX - 36},{TOP + 36} L{BX},{TOP} L{BX + 36},{TOP + 36}", ink, w=W - 12
    )
    down = stroke(stem(DX), ink) + stroke(
        f"M{DX - 36},{TOP + 60} L{DX},{TOP + 96} L{DX + 36},{TOP + 60}", PAPER, w=W - 36
    )
    return svg(plate(PAPER) + rings + up + down)


VARIANTS = {
    "a-overlap-two-tone": a_overlap_two_tone,
    "b-overlap-mono": b_overlap_mono,
    "c-shared-spine": c_shared_spine,
    "d-counter-rotating": d_counter_rotating,
    "e-interlocked": e_interlocked,
    "f-stem-arrows": f_stem_arrows,
}

if __name__ == "__main__":
    for name, fn in VARIANTS.items():
        (OUT / f"{name}.svg").write_text(fn())
