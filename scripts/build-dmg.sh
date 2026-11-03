#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Assets/Info.plist)
arch="${ARXIV_LENS_ARCH:-$(uname -m)}"
identity="${SIGN_IDENTITY:--}"
case "$arch" in
    arm64|x86_64) ;;
    *) echo "Unsupported build architecture: $arch" >&2; exit 2 ;;
esac
triple="$arch-apple-macosx13.0"
swift build -c release --triple "$triple"
binary="$(swift build -c release --triple "$triple" --show-bin-path)/ArxivLens"

temp="$(mktemp -d "$PWD/.build/dmg.XXXXXXXX")"
trap 'rm -rf "$temp"' EXIT
app="$temp/staging/Arxiv Lens.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$temp/AppIcon.iconset" dist
install -m 755 "$binary" "$app/Contents/MacOS/ArxivLens"
cp Assets/Info.plist "$app/Contents/Info.plist"
swift scripts/app-icon.swift "$temp/icon.png"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$temp/icon.png" --out "$temp/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    doubled=$((size * 2))
    sips -z "$doubled" "$doubled" "$temp/icon.png" --out "$temp/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil --convert icns --output "$app/Contents/Resources/AppIcon.icns" "$temp/AppIcon.iconset"
if [[ "$identity" == "-" ]]; then
    codesign --force --sign - "$app"
else
    codesign --force --timestamp --options runtime --sign "$identity" "$app"
fi
codesign --verify --strict "$app"
ln -s /Applications "$temp/staging/Applications"

name="Arxiv-Lens-$version-macOS-$arch.dmg"
hdiutil create -ov -volname "Arxiv Lens" -srcfolder "$temp/staging" -format UDZO -imagekey zlib-level=9 "$temp/$name"
hdiutil verify "$temp/$name"
mv -f "$temp/$name" "dist/$name"
(cd dist && shasum -a 256 "$name" > "$name.sha256")
printf '\n%s\n' "$PWD/dist/$name"
