"""Variations on draft e (interlocked): looser link, different line imagery."""

import math
from pathlib import Path

from gen import INK, SKY, TEAL, pt, svg

OUT = Path(__file__).parent / "e"
R = 76  # bowl radius
H = 58  # half the distance between bowl centres: smaller overlap than draft e
W = 40  # stroke width
TOP = 116
CY = 328  # bowl centre line
BCX, DCX = 256 - H, 256 + H
BX, DX = BCX - R, DCX + R
K = math.sqrt(R**2 - H**2)  # crossing points sit at (256, CY ± K)
CROSS = math.degrees(math.atan2(K, H))


def letter(stem_x, cx, clockwise):
    """Stem from the top down to the bowl's middle, then the whole bowl in one path,
    so dash patterns run continuously through the join."""
    sweep = 1 if clockwise else 0
    far = 2 * cx - stem_x
    return (
        f"M{stem_x},{TOP} L{stem_x},{CY} "
        f"A{R},{R} 0 1,{sweep} {far},{CY} A{R},{R} 0 1,{sweep} {stem_x},{CY}"
    )


B = letter(BX, BCX, clockwise=False)  # down the stem, bowl runs under then over
D = letter(DX, DCX, clockwise=True)


def seg(cx, deg, span=24):
    x0, y0 = pt(cx, CY, R, deg - span)
    x1, y1 = pt(cx, CY, R, deg + span)
    return f"M{x0:.1f},{y0:.1f} A{R},{R} 0 0,1 {x1:.1f},{y1:.1f}"


def weave_masks(gap):
    """b dips under d at the top crossing, d dips under b at the bottom one."""
    def mask(mid, cut):
        return (
            f'<mask id="{mid}" maskUnits="userSpaceOnUse">'
            '<rect width="512" height="512" fill="white"/>'
            f'<path d="{cut}" fill="none" stroke="black" stroke-width="{W + gap}"/>'
            "</mask>"
        )

    return mask("under-b", seg(DCX, 180 + CROSS)) + mask("under-d", seg(BCX, CROSS))


def path(d, color, w=W, cap="round", extra=""):
    return (
        f'<path d="{d}" fill="none" stroke="{color}" stroke-width="{w}" '
        f'stroke-linecap="{cap}" stroke-linejoin="round" {extra}/>'
    )


def icon(draw_b, draw_d, defs="", gap=32):
    plate = f'<circle cx="256" cy="256" r="240" fill="{INK}"/>'
    body = (
        f'<g mask="url(#under-b)">{draw_b}</g>'
        f'<g mask="url(#under-d)">{draw_d}</g>'
    )
    return svg(plate + body, weave_masks(gap) + defs)


def e1_link_solid():
    return icon(path(B, TEAL), path(D, SKY))


def e2_beads():
    # A chain of beads: the letters as strings of packets.
    dots = f'stroke-dasharray="0 {W + 24}"'
    return icon(path(B, TEAL, extra=dots), path(D, SKY, extra=dots), gap=40)


def e3_dashes():
    # Pills with gaps: a transfer in progress.
    dash = f'stroke-dasharray="26 {W + 26}"'
    return icon(path(B, TEAL, extra=dash), path(D, SKY, extra=dash))


def e4_tube():
    # Hollow strokes, like two cables.
    def tube(d, color):
        return path(d, color) + path(d, INK, w=W - 20)

    return icon(tube(B, TEAL), tube(D, SKY))


def e5_gradient():
    # Each letter fades into the other's colour: the two replicas exchange content.
    grads = (
        f'<linearGradient id="gb" gradientUnits="userSpaceOnUse" x1="{BX}" y1="0" x2="{DX}" y2="0">'
        f'<stop offset="0.15" stop-color="{TEAL}"/><stop offset="0.85" stop-color="{SKY}"/></linearGradient>'
        f'<linearGradient id="gd" gradientUnits="userSpaceOnUse" x1="{DX}" y1="0" x2="{BX}" y2="0">'
        f'<stop offset="0.15" stop-color="{SKY}"/><stop offset="0.85" stop-color="{TEAL}"/></linearGradient>'
    )
    return icon(path(B, "url(#gb)"), path(D, "url(#gd)"), defs=grads)


def e6_packets():
    # A thin wire with packets riding on it.
    def wire(d, color):
        return path(d, color, w=12) + path(
            d, color, w=W, extra=f'stroke-dasharray="0 {W + 90}" stroke-dashoffset="-40"'
        )

    return icon(wire(B, TEAL), wire(D, SKY), gap=24)


VARIANTS = {
    "e1-link-solid": e1_link_solid,
    "e2-beads": e2_beads,
    "e3-dashes": e3_dashes,
    "e4-tube": e4_tube,
    "e5-gradient": e5_gradient,
    "e6-packets": e6_packets,
}

if __name__ == "__main__":
    OUT.mkdir(exist_ok=True)
    for name, fn in VARIANTS.items():
        (OUT / f"{name}.svg").write_text(fn())
