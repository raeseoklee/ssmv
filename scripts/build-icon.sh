#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
iconset="$PWD/Resources/AppIcon.iconset"
mkdir -p "$iconset"
# Keep the original artwork and alpha. Normalize its oversized transparent canvas
# before creating Dock renditions. The measured solid artwork is 975 × 965px.
# Target equal-axis 68px Dock artwork at the reference scale.
# A 1170 × 1158px crop maps both axes to approximately 853 / 1024px.
icon_work_dir="$(mktemp -d -t ssmv-icon)"
normalized_icon="$icon_work_dir/normalized.png"
trap 'rm -rf "$icon_work_dir"' EXIT
sips -c 1158 1170 Resources/AppIcon-source.png --out "$normalized_icon" >/dev/null
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$normalized_icon" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  retina_size=$((size * 2))
  sips -z "$retina_size" "$retina_size" "$normalized_icon" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o Resources/AppIcon.icns
