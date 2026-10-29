#!/bin/sh
set -eu
cd "$(dirname "$0")"
mkdir -p .build/tmp .build/module-cache
export TMPDIR="$PWD/.build/tmp" CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
swift build -c release --disable-sandbox --scratch-path "$PWD/.build" --product MacMiniMonitor
APP="$PWD/build/Mac Mini Health Monitor.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$PWD/.build/AppIcon.iconset"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Assets/AppIcon.png --out "$PWD/.build/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" Assets/AppIcon.png --out "$PWD/.build/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$PWD/.build/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
cp Assets/GreateLogo.png "$APP/Contents/Resources/GreateLogo.png"
xattr -c "$APP/Contents/Resources/GreateLogo.png"
cp Assets/AppIcon.png "$APP/Contents/Resources/MenuBarIcon.png"
xattr -c "$APP/Contents/Resources/MenuBarIcon.png"
cp "$PWD/.build/release/MacMiniMonitor" "$APP/Contents/MacOS/MacMiniMonitor"
cp "$PWD/Info.plist" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
printf 'Built: %s\n' "$APP"
