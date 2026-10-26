#!/bin/bash
# Exercise the production panel without changing the user's system appearance.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
PROBE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pmap-appearance.XXXXXX")"
trap 'rm -rf "$PROBE_DIR"' EXIT
python3 - "$PROBE_DIR/Pmap.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Sources/Pmap.swift').read_text()
# Keep the real views and AppDelegate; replace only the application's entry point.
Path(sys.argv[1]).write_text(source[:source.index('@main\nstruct PmapApp: App')])
PY
SOURCES=()
for source in Sources/*.swift; do
    [[ "$source" == Sources/Pmap.swift ]] || SOURCES+=("$source")
done
xcrun swiftc -parse-as-library -swift-version 6 \
    -load-plugin-library "$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib" \
    -framework SwiftUI -framework AppKit -framework Combine -framework UserNotifications \
    "${SOURCES[@]}" "$PROBE_DIR/Pmap.swift" scripts/appearance-probe.swift -o "$PROBE_DIR/probe"
"$PROBE_DIR/probe"
