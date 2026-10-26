#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
. "$ROOT/scripts/swift-env.sh"
cd "$ROOT"

# CLT 没有 XCTest。仅运行 Swift Testing；宏插件从同一个 Swift 工具链查找，兼容 Xcode 与 CLT 目录结构。
PLUGIN="$(dirname -- "$LAUNCHTABLET_SWIFT")/../lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [ -f "$PLUGIN" ]; then
    exec "$LAUNCHTABLET_SWIFT" test --disable-xctest -Xswiftc -load-plugin-library -Xswiftc "$PLUGIN" "$@"
fi
exec "$LAUNCHTABLET_SWIFT" test --disable-xctest "$@"
