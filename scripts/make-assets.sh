#!/bin/bash
# 앱 아이콘(Resources/AppIcon.icns)과 README 이미지(docs/images)를 다시 만든다.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

swiftc -O -swift-version 5 -target arm64-apple-macos26.0 scripts/render-assets.swift -o "$WORK/render"
"$WORK/render" "$WORK"

mkdir -p docs/images
cp "$WORK/hero.png" docs/images/hero.png
sips -z 256 256 "$WORK/icon-1024.png" --out docs/images/icon.png >/dev/null

ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size "$WORK/icon-1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) "$WORK/icon-1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns

echo "완료: Resources/AppIcon.icns, docs/images/hero.png, docs/images/icon.png"
