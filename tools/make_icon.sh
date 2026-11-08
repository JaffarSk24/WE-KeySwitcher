#!/bin/zsh
# Renders Resources/icon/AppIcon.svg into Resources/AppIcon.icns and a 1024 px PNG.
# Needs an SVG renderer: vectorcraft-cli if installed, otherwise rsvg-convert.
set -euo pipefail
cd "$(dirname "$0")/.."
SVG=Resources/icon/AppIcon.svg
SET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$SET"
render() { # size out
  if command -v vectorcraft-cli >/dev/null; then
    vectorcraft-cli convert "$SVG" "$2" --ppi $(( 72.0 * $1 / 1024 )) >/dev/null
  else
    rsvg-convert -w "$1" -h "$1" "$SVG" -o "$2"
  fi
}
for s in 16 32 128 256 512; do
  render $s "$SET/icon_${s}x${s}.png"
  render $(( s * 2 )) "$SET/icon_${s}x${s}@2x.png"
done
render 1024 Resources/icon/AppIcon-1024.png
iconutil -c icns "$SET" -o Resources/AppIcon.icns
rm -rf "$(dirname "$SET")"
echo "Resources/AppIcon.icns"
