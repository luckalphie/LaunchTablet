#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"

# DMG 只分发 Apple 芯片正式版。
sh "$ROOT/scripts/build-app.sh"
APP="$ROOT/dist/LaunchTablet.app"
PLIST="$APP/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
NAME="LaunchTablet-$VERSION-$BUILD-arm64"
DMG="$ROOT/dist/$NAME.dmg"

codesign --verify --deep --strict "$APP"
if [ "$(lipo -archs "$APP/Contents/MacOS/LaunchTablet")" != arm64 ]; then
    echo "Expected an Apple Silicon (arm64) application." >&2
    exit 1
fi
if /usr/libexec/PlistBuddy -c 'Print :LauncherTestOnSecondaryDisplay' "$PLIST" >/dev/null 2>&1 || \
   /usr/libexec/PlistBuddy -c 'Print :LauncherTestOnMainDisplay' "$PLIST" >/dev/null 2>&1; then
    echo "Refusing to distribute a display test application." >&2
    exit 1
fi

STAGING="$(mktemp -d "$ROOT/.build/dmg.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT HUP INT TERM
mkdir -p "$STAGING/payload"
ditto "$APP" "$STAGING/payload/LaunchTablet.app"
ln -s /Applications "$STAGING/payload/Applications"
cp "$ROOT/docs/安装与使用说明.txt" "$STAGING/payload/安装与使用说明.txt"
cp "$ROOT/LICENSE" "$STAGING/payload/LICENSE.txt"

# 只装入应用和说明，不包含本机保存的布局、用户偏好或源码。先验证镜像再替换输出。
hdiutil create -volname "LaunchTablet $VERSION" -srcfolder "$STAGING/payload" -format UDZO -imagekey zlib-level=9 "$STAGING/$NAME.dmg"
hdiutil verify "$STAGING/$NAME.dmg"
mv -f "$STAGING/$NAME.dmg" "$DMG"
(cd "$ROOT/dist" && shasum -a 256 "$NAME.dmg" > "$NAME.dmg.sha256")
echo "Created $DMG"
