#!/bin/sh
set -eu

case "${1:-}" in
    "") TEST_MODE=NO ;;
    --test-secondary) TEST_MODE=SECONDARY ;;
    --test-main) TEST_MODE=MAIN ;;
    *) echo "Usage: sh scripts/build-app.sh [--test-secondary|--test-main]" >&2; exit 2 ;;
esac

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
APP="$ROOT/dist/LaunchTablet.app"
BUNDLE_ID="com.local.launchtablet"
DISPLAY_NAME="LaunchTablet"
# dist 只交付一个正式应用；副屏测试包放在内部构建目录，使用独立标识避免系统缓存混淆。
if [ "$TEST_MODE" != NO ]; then
    APP="$ROOT/.build/ui-testing/LaunchTablet.app"
    BUNDLE_ID="com.local.launchtablet.secondary-test"
    DISPLAY_NAME="LaunchTablet Display Test"
fi

cd "$ROOT"
. "$ROOT/scripts/swift-env.sh"
"$LAUNCHTABLET_SWIFT" build -c release --arch arm64
BINARY_DIRECTORY="$("$LAUNCHTABLET_SWIFT" build -c release --arch arm64 --show-bin-path)"

STAGING="$(mktemp -d "$ROOT/.build/package.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT HUP INT TERM
CONTENTS="$STAGING/LaunchTablet.app/Contents"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BINARY_DIRECTORY/LaunchTablet" "$CONTENTS/MacOS/LaunchTablet"
cp "$ROOT/LICENSE" "$CONTENTS/Resources/LICENSE.txt"
cp -R "$ROOT/Sources/LaunchTablet/Resources/" "$CONTENTS/Resources/"
ICONSET="$STAGING/LaunchTablet.iconset"
"$CONTENTS/MacOS/LaunchTablet" --export-icon "$ICONSET"
iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/LaunchTablet.icns"
rm -rf "$ICONSET"
cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>LaunchTablet</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.launchtablet</string>
    <key>CFBundleName</key>
    <string>LaunchTablet</string>
    <key>CFBundleDisplayName</key>
    <string>LaunchTablet</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleLocalizations</key>
    <array><string>zh-Hans</string><string>en</string></array>
    <key>CFBundleIconFile</key>
    <string>LaunchTablet.icns</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.3</string>
    <key>CFBundleVersion</key>
    <string>16</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $DISPLAY_NAME" "$CONTENTS/Info.plist"
if [ "$TEST_MODE" = SECONDARY ]; then
    /usr/libexec/PlistBuddy -c "Add :LauncherTestOnSecondaryDisplay bool true" "$CONTENTS/Info.plist"
    printf '%s\n' '"CFBundleDisplayName" = "LaunchTablet 副屏测试";' > "$CONTENTS/Resources/zh-Hans.lproj/InfoPlist.strings"
    printf '%s\n' '"CFBundleDisplayName" = "LaunchTablet Secondary Display Test";' > "$CONTENTS/Resources/en.lproj/InfoPlist.strings"
elif [ "$TEST_MODE" = MAIN ]; then
    /usr/libexec/PlistBuddy -c "Add :LauncherTestOnMainDisplay bool true" "$CONTENTS/Info.plist"
    printf '%s\n' '"CFBundleDisplayName" = "LaunchTablet 主屏测试";' > "$CONTENTS/Resources/zh-Hans.lproj/InfoPlist.strings"
    printf '%s\n' '"CFBundleDisplayName" = "LaunchTablet Main Display Test";' > "$CONTENTS/Resources/en.lproj/InfoPlist.strings"
fi
chmod +x "$CONTENTS/MacOS/LaunchTablet"
# Xcode 的 Release 也可能携带指向本机源码/中间文件的调试符号；移除后再签名，避免随测试包泄露路径。
xcrun strip -S "$CONTENTS/MacOS/LaunchTablet"
codesign --force --sign - "$STAGING/LaunchTablet.app"
# 图标与签名齐备后再替换正式目录，避免 Finder 在打包中途缓存“没有图标”的半成品。
mkdir -p "$(dirname -- "$APP")"
rm -rf "$APP"
mv "$STAGING/LaunchTablet.app" "$APP"
touch "$APP"
if [ "$TEST_MODE" = NO ]; then
    LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    if ! "$LSREGISTER" -f "$APP"; then
        echo "Application built; macOS registration refresh was unavailable." >&2
    fi
fi
echo "Created $APP"
