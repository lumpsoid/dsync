"""Renders the dsync app icon for every platform from one geometry.

The mark: a disc split into two D-shaped halves (the two replicas), offset
vertically, teal and sky, on a dark teal gradient plate. Exploration that led
here lives in drafts/.

Writes the master SVGs next to this file, then every platform asset into the
Flutter project. Needs rsvg-convert and ImageMagick (magick).

    python3 design/icon/gen_icons.py
"""

import json
import subprocess
import tempfile
from pathlib import Path

HERE = Path(__file__).parent
ROOT = HERE.parent.parent

C = 256  # masters are drawn on a 512 canvas
R = 150  # disc radius
GAP = 30  # cut between the halves
SHIFT = 26  # vertical offset of each half
TEAL, SKY = "#2DD4BF", "#38BDF8"
PLATE = (
    '<linearGradient id="plate" x1="0" y1="0" x2="0.6" y2="1">'
    '<stop offset="0" stop-color="#1F5F6E"/><stop offset="1" stop-color="#0B2A33"/>'
    "</linearGradient>"
)


def svg(body, defs=""):
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">'
        f"<defs>{defs}</defs>{body}</svg>"
    )


def half(side, color, dy):
    x = C + side * GAP / 2
    sweep = 1 if side > 0 else 0
    return f'<path d="M{x},{C - R + dy} A{R},{R} 0 0,{sweep} {x},{C + R + dy} Z" fill="{color}"/>'


def glyph(scale=1.0, left=TEAL, right=SKY):
    body = half(-1, left, -SHIFT) + half(1, right, SHIFT)
    return f'<g transform="translate({C},{C}) scale({scale}) translate({-C},{-C})">{body}</g>'


def rounded(x0, size, radius):
    return f'<rect x="{x0}" y="{x0}" width="{size}" height="{size}" rx="{radius}" fill="url(#plate)"/>'


FULL = '<rect width="512" height="512" fill="url(#plate)"/>'

# Every glyph point stays within 177 units of the centre (the corners of the
# flat edges), which is what the safe-zone scales below are checked against.
MASTERS = {
    # Rounded plate with its own margin: Windows, Linux, web, legacy Android.
    "dsync": svg(rounded(16, 480, 112) + glyph(), PLATE),
    # Full bleed, the OS applies the mask: iOS, web maskable (safe radius 205).
    "dsync-full": svg(FULL + glyph(), PLATE),
    # macOS grid: an 824/1024 body centred, corner radius ~22.4% of the body.
    "dsync-macos": svg(rounded(50, 412, 92) + glyph(0.86), PLATE),
    # Android adaptive layers on a 108dp canvas; safe circle radius is 33dp (156
    # units), the glyph at 0.8 reaches 142.
    "android-foreground": svg(glyph(0.8)),
    "android-background": svg(FULL, PLATE),
    "android-monochrome": svg(glyph(0.8, "white", "white")),
}


def render(master, size, dest, opaque=False):
    dest = Path(dest)
    dest.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["rsvg-convert", "-w", str(size), "-h", str(size), str(HERE / f"{master}.svg"), "-o", str(dest)],
        check=True,
    )
    if opaque:  # App Store rejects icons with an alpha channel
        subprocess.run(["magick", str(dest), "-background", "#0B2A33", "-alpha", "remove", "-alpha", "off", str(dest)], check=True)


def android():
    res = ROOT / "android/app/src/main/res"
    for density, factor in {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}.items():
        d = res / f"mipmap-{density}"
        render("dsync", int(48 * factor), d / "ic_launcher.png")
        for layer in ("foreground", "background", "monochrome"):
            render(f"android-{layer}", int(108 * factor), d / f"ic_launcher_{layer}.png")
    xml = res / "mipmap-anydpi-v26/ic_launcher.xml"
    xml.parent.mkdir(exist_ok=True)
    xml.write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <background android:drawable="@mipmap/ic_launcher_background"/>\n'
        '    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>\n'
        '    <monochrome android:drawable="@mipmap/ic_launcher_monochrome"/>\n'
        "</adaptive-icon>\n"
    )


def from_contents(appiconset, master, opaque):
    """Renders every image an Xcode asset catalog lists, at size x scale."""
    contents = json.loads((appiconset / "Contents.json").read_text())
    for image in contents["images"]:
        points = float(image["size"].split("x")[0])
        scale = int(image["scale"].rstrip("x"))
        render(master, round(points * scale), appiconset / image["filename"], opaque)


def windows():
    with tempfile.TemporaryDirectory() as tmp:
        pngs = []
        for size in (16, 24, 32, 48, 64, 128, 256):
            p = Path(tmp) / f"{size}.png"
            render("dsync", size, p)
            pngs.append(str(p))
        subprocess.run(["magick", *pngs, str(ROOT / "windows/runner/resources/app_icon.ico")], check=True)


def web():
    render("dsync", 32, ROOT / "web/favicon.png")
    for size in (192, 512):
        render("dsync", size, ROOT / f"web/icons/Icon-{size}.png")
        render("dsync-full", size, ROOT / f"web/icons/Icon-maskable-{size}.png")


def linux():
    render("dsync", 256, ROOT / "linux/runner/resources/app_icon.png")


if __name__ == "__main__":
    for name, body in MASTERS.items():
        (HERE / f"{name}.svg").write_text(body)
    android()
    from_contents(ROOT / "ios/Runner/Assets.xcassets/AppIcon.appiconset", "dsync-full", opaque=True)
    from_contents(ROOT / "macos/Runner/Assets.xcassets/AppIcon.appiconset", "dsync-macos", opaque=False)
    windows()
    web()
    linux()
