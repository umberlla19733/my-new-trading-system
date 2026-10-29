#!/usr/bin/env bash
# One-time setup for the Persian image generators (tools/make_*_sheet.py).
#
#   bash tools/setup_render_env.sh
#   /home/user/.venv/bin/python tools/make_feature_sheet.py
#
# Why a script: Pillow alone is not enough. Persian needs real text shaping
# (arabic-reshaper + python-bidi) and a Persian font, because AI image models
# garble Farsi. Both renderers fail with a clear message if a piece is missing,
# and the font lookup order is:  ./assets/fonts  ->  ~/.fonts  ->  /tmp copy.
set -euo pipefail

VENV="${VENV:-$HOME/.venv}"
FONT_DIR="$HOME/.fonts"
VAZIR="https://codeload.github.com/rastikerdar/vazirmatn/tar.gz/refs/tags/v33.003"
PY=/usr/bin/env

echo "==> python venv at $VENV"
if [ ! -x "$VENV/bin/python" ]; then
  "$PY" python3 -m venv "$VENV"
fi
"$VENV/bin/python" -m pip install -q --upgrade pip >/dev/null 2>&1 || true
"$VENV/bin/pip" install -q pillow arabic-reshaper python-bidi
"$VENV/bin/python" - <<'PY'
import PIL, arabic_reshaper, bidi            # noqa: F401
print(f"    pillow {PIL.__version__}, reshaper and bidi importable")
PY

echo "==> Vazirmatn TTFs in $FONT_DIR"
mkdir -p "$FONT_DIR"
if ls "$FONT_DIR"/Vazirmatn-*.ttf >/dev/null 2>&1; then
  echo "    already installed ($(ls "$FONT_DIR"/Vazirmatn-*.ttf | wc -l) weights)"
else
  tmp="$(mktemp -d)"
  # retry, and check the payload: a silent partial download used to leave the
  # font dir empty and the renderers then complained about missing weights
  for try in 1 2 3; do
    if curl -fsSL --retry 2 --max-time 300 -o "$tmp/vaz.tgz" "$VAZIR" &&
       [ "$(wc -c < "$tmp/vaz.tgz")" -gt 1000000 ] && tar xzf "$tmp/vaz.tgz" -C "$tmp"; then
      break
    fi
    echo "    download attempt $try failed, retrying in 3 s"
    sleep 3
  done
  src="$(find "$tmp" -type d -name ttf -path '*fonts*' | head -1)"
  if [ -z "$src" ]; then
    echo "    ERROR: Vazirmatn archive not usable - re-run this script (no network?)"
    rm -rf "$tmp"; exit 1
  fi
  for w in Regular Medium SemiBold Bold ExtraBold; do
    cp "$src/Vazirmatn-$w.ttf" "$FONT_DIR/" 2>/dev/null || echo "    missing weight: $w"
  done
  rm -rf "$tmp"
  got="$(ls "$FONT_DIR"/Vazirmatn-*.ttf 2>/dev/null | wc -l)"
  [ "$got" -ge 5 ] || { echo "    ERROR: only $got weights installed in $FONT_DIR"; exit 1; }
  echo "    installed: $(ls "$FONT_DIR"/Vazirmatn-*.ttf | xargs -n1 basename | tr '\n' ' ')"
fi

echo
echo "render with:"
echo "  $VENV/bin/python tools/make_feature_sheet.py --out docs/GoldBasketGuard-features-fa.png"
echo "  $VENV/bin/python tools/make_flow_sheet.py    --out docs/GoldBasketGuard-flow-fa.png"
