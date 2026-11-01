#!/bin/bash
# Le tavole del README (docs/images), dai sorgenti di questa cartella: Chrome senza finestra a 2×.
# La tavola dei casi del MIXER (pixels-*.png) usa le catture in catture/, ritagliate il 28/10 dalla tavola del 25/10.
# Uso: docs/images/source/make.sh [cartella di lavoro]   Parla riga per riga.
set -euo pipefail
S="$(cd "$(dirname "$0")" && pwd)"; I="$(dirname "$S")"
W="${1:-$(mktemp -d /tmp/port-readme.XXXXXX)}"; mkdir -p "$W"
CH="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
foto() { "$CH" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=2 --window-size="$1" \
           --user-data-dir="$W/chrome" --screenshot="$2" "$3" >/dev/null 2>&1; echo "  $(basename "$2")"; }
foto 1280,400 "$I/banner.png" "file://$S/banner.html"
foto 1280,560 "$I/how-it-works.png" "file://$S/architettura.html"
foto 1280,560 "$I/how-it-works-it.png" "file://$S/architettura-it.html"
for t in lavoro:the-work pixel:pixels pila:stack prove:verified; do
  for l in en it; do foto 1280,1000 "$W/grezza-${t%%:*}-$l.png" "file://$S/tavole.html?t=${t%%:*}&l=$l"; done
done
python3 - "$W" "$I" <<'PY'
import sys
from PIL import Image
W, I = sys.argv[1], sys.argv[2]
for t, d in [("lavoro", "the-work"), ("pixel", "pixels"), ("pila", "stack"), ("prove", "verified")]:
    for l in ["en", "it"]:
        im = Image.open(f"{W}/grezza-{t}-{l}.png").convert("RGB"); w, h = im.size; fondo = im.getpixel((5, h - 5)); px = im.load(); y = h - 1
        while y > 0 and all(px[x, y] == fondo for x in range(0, w, 7)): y -= 1
        im.crop((0, 0, w, min(h, y + 60))).save(f"{I}/{d}-{l}.png", optimize=True)
        print(f"  {d}-{l}.png")
PY
