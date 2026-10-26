#!/bin/sh
# 由 run/build/test 共用并通过“.”加载。遵循 xcode-select 或调用方的 DEVELOPER_DIR，不切换开发者目录。
if ! command -v xcrun >/dev/null 2>&1; then
    echo "macOS developer tools are required. Install Xcode or Command Line Tools." >&2
    return 1
fi
if ! LAUNCHTABLET_SWIFT="$(xcrun --find swift)"; then
    echo "Cannot locate Swift. Check xcode-select and DEVELOPER_DIR." >&2
    return 1
fi
if [ -z "${SDKROOT:-}" ]; then
    if ! SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"; then
        echo "Cannot locate the macOS SDK for the selected developer tools." >&2
        return 1
    fi
    export SDKROOT
fi

# 测试使用 Swift Testing，最低需要 Swift 6；版本不满足时提前给出原因。
if ! LAUNCHTABLET_SWIFT_VERSION="$("$LAUNCHTABLET_SWIFT" --version)"; then
    return 1
fi
LAUNCHTABLET_SWIFT_MAJOR="$(printf '%s\n' "$LAUNCHTABLET_SWIFT_VERSION" | sed -n 's/.*Swift version \([0-9][0-9]*\).*/\1/p' | head -n 1)"
if [ -z "$LAUNCHTABLET_SWIFT_MAJOR" ] || [ "$LAUNCHTABLET_SWIFT_MAJOR" -lt 6 ]; then
    echo "Swift 6 or later is required. Select a compatible Xcode or Swift toolchain." >&2
    return 1
fi
