"""b and d side by side, not touching; a data-transfer symbol sits between the stems above the bowls."""

import math
from pathlib import Path

from gen import INK, SKY, TEAL, svg

OUT = Path(__file__).parent / "f"
R = 62  # bowl radius
W = 42  # letter stroke width
GAP = 20  # clear space between the two bowls
TOP, CY = 132, 340
BASE = CY + R
BCX = 256 - (R + W / 2 + GAP / 2)
DCX = 512 - BCX
BX, DX = BCX - R, DCX + R
SW = 24  # symbol stroke width
MID_Y = (TOP + CY - R - W / 2) / 2  # vertical centre of the free space above the bowls
WHITE = "#FFFFFF"


def path(d, color, w=W, extra=""):
    return (
        f'<path d="{d}" fill="none" stroke="{color}" stroke-width="{w}" '
        f'stroke-linecap="round" stroke-linejoin="round" {extra}/>'
    )


def ring(cx):
    return f"M{cx - R},{CY} a{R},{R} 0 1,0 {2 * R},0 a{R},{R} 0 1,0 {-2 * R},0"


def letters():
    return (
        path(f"M{BX},{TOP} L{BX},{BASE}", TEAL)
        + path(ring(BCX), TEAL)
        + path(f"M{DX},{TOP} L{DX},{BASE}", SKY)
        + path(ring(DCX), SKY)
    )


def chevron(x, y, deg, size=26):
    """Arrowhead strokes with the tip at (x, y), pointing along `deg`."""
    pts = []
    for side in (-1, 1):
        a = math.radians(deg + 180 + side * 42)
        pts.append((x + size * math.cos(a), y + size * math.sin(a)))
    (x0, y0), (x1, y1) = pts
    return f"M{x0:.1f},{y0:.1f} L{x},{y} L{x1:.1f},{y1:.1f}"


def icon(symbol, defs=""):
    plate = f'<circle cx="256" cy="256" r="240" fill="{INK}"/>'
    return svg(plate + letters() + symbol, defs)


def f1_arrows():
    # ⇄: one lane each way.
    x0, x1 = BX + 60, DX - 60
    top, bot = MID_Y - 24, MID_Y + 24
    return icon(
        path(f"M{x0},{top} L{x1},{top}", TEAL, SW)
        + path(chevron(x1, top, 0), TEAL, SW)
        + path(f"M{x1},{bot} L{x0},{bot}", SKY, SW)
        + path(chevron(x0, bot, 180), SKY, SW)
    )


def f2_arch():
    # A bridge from one letter to the other, arrowheads at both ends.
    x0, x1, y = BX + 62, DX - 62, MID_Y + 36
    r = (x1 - x0) / 2 / math.sin(math.radians(60))
    return icon(
        path(f"M{x0},{y} A{r:.1f},{r:.1f} 0 0,1 {x1},{y}", WHITE, SW)
        + path(chevron(x0, y, 120), WHITE, SW)
        + path(chevron(x1, y, 60), WHITE, SW)
    )


def f3_packets():
    # Packets in flight, shading from b's colour into d's.
    xs = [BX + 70 + i * (DX - BX - 140) / 3 for i in range(4)]
    cols = [TEAL, "#30CDD6", "#34C6E8", SKY]
    return icon("".join(
        f'<circle cx="{x:.1f}" cy="{MID_Y}" r="{15 + 3 * i}" fill="{c}"/>'
        for i, (x, c) in enumerate(zip(xs, cols))
    ))


def f4_sync_loop():
    # The classic two-arrow sync circle.
    r, cx, cy = 50, 256, MID_Y
    def arc(a0, a1):
        x0, y0 = cx + r * math.cos(math.radians(a0)), cy + r * math.sin(math.radians(a0))
        x1, y1 = cx + r * math.cos(math.radians(a1)), cy + r * math.sin(math.radians(a1))
        return f"M{x0:.1f},{y0:.1f} A{r},{r} 0 0,1 {x1:.1f},{y1:.1f}"

    def tip(a):
        return cx + r * math.cos(math.radians(a)), cy + r * math.sin(math.radians(a))

    (tx0, ty0), (tx1, ty1) = tip(160), tip(340)
    return icon(
        path(arc(200, 340), TEAL, SW) + path(chevron(round(tx1, 1), round(ty1, 1), 70, 22), TEAL, SW)
        + path(arc(20, 160), SKY, SW) + path(chevron(round(tx0, 1), round(ty0, 1), 250, 22), SKY, SW)
    )


def f5_up_down():
    # Upload and download side by side.
    h = 52
    xu, xd = 256 - 34, 256 + 34
    return icon(
        path(f"M{xu},{MID_Y + h} L{xu},{MID_Y - h}", TEAL, SW)
        + path(chevron(xu, MID_Y - h, 270), TEAL, SW)
        + path(f"M{xd},{MID_Y - h} L{xd},{MID_Y + h}", SKY, SW)
        + path(chevron(xd, MID_Y + h, 90), SKY, SW)
    )


def f6_signal():
    # Signal arcs from each stem towards the other, like two radios talking.
    def waves(x, facing, color):
        out = ""
        for i, r in enumerate((34, 70)):
            a0, a1 = (-40, 40) if facing > 0 else (140, 220)
            p0 = (x + r * math.cos(math.radians(a0)), MID_Y + r * math.sin(math.radians(a0)))
            p1 = (x + r * math.cos(math.radians(a1)), MID_Y + r * math.sin(math.radians(a1)))
            out += path(f"M{p0[0]:.1f},{p0[1]:.1f} A{r},{r} 0 0,1 {p1[0]:.1f},{p1[1]:.1f}", color, SW - 4)
        return out

    return icon(waves(BX + 18, 1, TEAL) + waves(DX - 18, -1, SKY))


VARIANTS = {
    "f1-arrows": f1_arrows,
    "f2-arch": f2_arch,
    "f3-packets": f3_packets,
    "f4-sync-loop": f4_sync_loop,
    "f5-up-down": f5_up_down,
    "f6-signal": f6_signal,
}

if __name__ == "__main__":
    OUT.mkdir(exist_ok=True)
    for name, fn in VARIANTS.items():
        (OUT / f"{name}.svg").write_text(fn())
