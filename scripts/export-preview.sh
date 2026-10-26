#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
. "$ROOT/scripts/swift-env.sh"
cd "$ROOT"
mkdir -p "$ROOT/.build" "$ROOT/docs/images"
STAGING="$(mktemp -d "$ROOT/.build/preview.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT HUP INT TERM

# 使用真实 SwiftUI View 和隔离的示例数据离屏绘制，不读取应用清单或用户壁纸，不显示窗口。
LAUNCHTABLET_SWIFTC="$(xcrun --find swiftc)"
"$LAUNCHTABLET_SWIFTC" -sdk "$SDKROOT" \
    Sources/LaunchTablet/AppIdentity.swift \
    Sources/LaunchTablet/Localization.swift \
    Sources/LaunchTablet/ApplicationCatalog.swift \
    Sources/LaunchTablet/GlobalShortcut.swift \
    Sources/LaunchTablet/GridDisplayMode.swift \
    Sources/LaunchTablet/LauncherLayout.swift \
    Sources/LaunchTablet/LauncherModel.swift \
    Sources/LaunchTablet/LauncherDragSource.swift \
    Sources/LaunchTablet/LauncherView.swift \
    scripts/export-preview.swift -o "$STAGING/export-preview"
cp -R "$ROOT/Sources/LaunchTablet/Resources" "$STAGING/Resources"
mkdir -p "$ROOT/.build/localization-previews"
"$STAGING/export-preview" "$ROOT/docs/images/overview.png" "$STAGING" zh-Hans overview
"$STAGING/export-preview" "$ROOT/docs/images/overview-en.png" "$STAGING" en overview
for language in zh-Hans en; do
    "$STAGING/export-preview" "$ROOT/.build/localization-previews/settings-$language.png" "$STAGING" "$language" settings
    "$STAGING/export-preview" "$ROOT/.build/localization-previews/folder-$language.png" "$STAGING" "$language" folder
done
for mode in fullScreen macBook14 macBook16 display24 display27; do
    "$STAGING/export-preview" "$ROOT/.build/localization-previews/grid-$mode.png" "$STAGING" en overview "$mode"
done
for mode in fullScreen macBook14 macBook16 display24 display27; do
    "$STAGING/export-preview" "$ROOT/.build/localization-previews/paging-$mode.png" "$STAGING" en paging "$mode"
done
for scene in large ultrawide portrait; do
    "$STAGING/export-preview" "$ROOT/.build/localization-previews/fullScreen-$scene.png" "$STAGING" en "$scene" fullScreen
done
