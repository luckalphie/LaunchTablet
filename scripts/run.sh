#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
. "$ROOT/scripts/swift-env.sh"
cd "$ROOT"
exec "$LAUNCHTABLET_SWIFT" run LaunchTablet "$@"
