#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="/tmp/terminals-demo"
HOME_DIR="/tmp/terminals-demo-home"

rm -rf "$DEST" "$HOME_DIR"
mkdir -p "$DEST" "$HOME_DIR/assets"

rsync -a \
  --exclude ".git" \
  --exclude "vendor" \
  --exclude "assets" \
  "$ROOT/" "$DEST/"

chmod +x "$DEST/demo/"*.sh
touch "$HOME_DIR/.bash_history"
mkdir -p "$DEST/assets" "$ROOT/assets"

cd "$DEST"
vhs demo/hero.tape

cp "$DEST/assets/hero.gif" "$ROOT/assets/hero.gif"
ffmpeg -y -i "$ROOT/assets/hero.gif" -vf "select=eq(n\,90)" -vframes 1 "$ROOT/assets/hero.png" 2>/dev/null

echo "Wrote assets/hero.gif and assets/hero.png"