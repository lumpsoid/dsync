"""The split circle: two D-shaped halves of one disc, a gap between them."""

from pathlib import Path

from gen import INK, PAPER, SKY, TEAL, plate, svg

OUT = Path(__file__).parent / "g"
C = 256
R = 150  # disc radius
GAP = 30
SHIFT = 26  # vertical offset of each half: "almost in sync"
DEEP = "#0F766E"

GRAD = (
    '<linearGradient id="g" x1="0" y1="0" x2="1" y2="1">'
    '<stop offset="0" stop-color="#14B8A6"/><stop offset="1" stop-color="#0E7490"/>'
    "</linearGradient>"
)


def half(side, color, dy=0, r=R, gap=GAP):
    """Half-disc; side -1 is the left one. Its flat edge faces the gap."""
    x = C + side * gap / 2
    top, bot = C - r + dy, C + r + dy
    sweep = 1 if side > 0 else 0
    return f'<path d="M{x},{top} A{r},{r} 0 0,{sweep} {x},{bot} Z" fill="{color}"/>'


def g1_offset_two_tone():
    return svg(plate(INK) + half(-1, TEAL, -SHIFT) + half(1, SKY, SHIFT))


def g2_offset_mono():
    return svg(plate("url(#g)") + half(-1, "white", -SHIFT) + half(1, "white", SHIFT), GRAD)


def g3_split_ring():
    # Two C-shaped arcs facing each other: the disc as a ring.
    r, w, x0, x1 = 118, 64, C - GAP / 2, C + GAP / 2
    def arc(x, sweep, dy, color):
        return (
            f'<path d="M{x},{C - r + dy} A{r},{r} 0 0,{sweep} {x},{C + r + dy}" fill="none" '
            f'stroke="{color}" stroke-width="{w}"/>'
        )
    return svg(plate(INK, "circle") + arc(x0, 0, -SHIFT, TEAL) + arc(x1, 1, SHIFT, SKY))


def g4_diagonal():
    # The cut runs on the diagonal; the halves slide along it.
    body = half(-1, DEEP, -SHIFT) + half(1, TEAL, SHIFT)
    return svg(plate(PAPER) + f'<g transform="rotate(45 {C} {C})">{body}</g>')


def g5_s_cut():
    # The cut is an S-curve, the two halves hook into each other.
    h = R / 2
    right = (
        f"M{C},{C - R} A{h},{h} 0 0,1 {C},{C} A{h},{h} 0 0,0 {C},{C + R} "
        f"L{C},512 L512,512 L512,0 L{C},0 Z"
    )
    s = f"M{C},{C - R - 20} L{C},{C - R} A{h},{h} 0 0,1 {C},{C} A{h},{h} 0 0,0 {C},{C + R} L{C},{C + R + 20}"
    clip = f'<clipPath id="right"><path d="{right}"/></clipPath>'
    body = (
        f'<circle cx="{C}" cy="{C}" r="{R}" fill="{TEAL}"/>'
        f'<circle cx="{C}" cy="{C}" r="{R}" fill="{SKY}" clip-path="url(#right)"/>'
        f'<path d="{s}" fill="none" stroke="{INK}" stroke-width="{GAP}"/>'
    )
    return svg(plate(INK) + body, clip)


def g6_packet():
    # Halves held apart, one packet crossing the gap.
    gap = 64
    return svg(
        plate(PAPER)
        + half(-1, DEEP, gap=gap)
        + half(1, DEEP, gap=gap)
        + f'<circle cx="{C}" cy="{C}" r="18" fill="{TEAL}"/>'
    )


VARIANTS = {
    "g1-offset-two-tone": g1_offset_two_tone,
    "g2-offset-mono": g2_offset_mono,
    "g3-split-ring": g3_split_ring,
    "g4-diagonal": g4_diagonal,
    "g5-s-cut": g5_s_cut,
    "g6-packet": g6_packet,
}

if __name__ == "__main__":
    OUT.mkdir(exist_ok=True)
    for name, fn in VARIANTS.items():
        (OUT / f"{name}.svg").write_text(fn())
