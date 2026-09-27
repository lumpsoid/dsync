#!/usr/bin/env bash
# Renders every draft at 256/48/24/16 px and tiles them into sheet.png.
# `sheet.sh` renders the first round; `sheet.sh e` renders gen_e.py into e/.
set -euo pipefail
cd "$(dirname "$0")"
if [ -n "${1:-}" ]; then python3 "gen_$1.py"; cd "$1"; else python3 gen.py; fi
rm -rf png && mkdir png
tiles=()
for f in *.svg; do
  n=${f%.svg}
  for s in 256 48 24 16; do rsvg-convert -w $s -h $s "$f" -o "png/$n-$s.png"; done
  magick -background white \
    "png/$n-256.png" \
    \( "png/$n-48.png" "png/$n-24.png" "png/$n-16.png" -background white -gravity center -splice 12x0 +append -extent 256x60 \) \
    -gravity center -append \
    -gravity south -splice 0x28 -font DejaVu-Sans -pointsize 18 -annotate +0+4 "$n" \
    "png/$n-tile.png"
  tiles+=("png/$n-tile.png")
done
magick montage "${tiles[@]}" -tile 3x -geometry +16+16 -background white sheet.png
