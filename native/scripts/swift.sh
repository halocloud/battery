#!/bin/bash
set -euo pipefail
native_root="$(cd "$(dirname "$0")/.." && pwd)"
operation="${1:-build}"
if [[ $# -gt 0 ]]; then shift; fi
if [[ "$operation" == test ]]; then set -- --disable-xctest "$@"; fi
export CLANG_MODULE_CACHE_PATH="$native_root/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$native_root/.build/module-cache"
mkdir -p "$native_root/.build/module-cache" "$native_root/.build/cache" "$native_root/.build/config" "$native_root/.build/security"
# Optional workaround for CLT installations containing stale Swift 5 private manifest
# interfaces alongside a Swift 6 library. All repairs stay inside build artifacts.
if [[ "${BATTERYCORE_FIX_MANIFEST_INTERFACE:-0}" == 1 ]]; then
    toolchain="$(/usr/bin/xcrun --find swift)"
    pm_libs="$(dirname "$toolchain")/../lib/swift/pm"
    overlay="$native_root/.build/toolchain"
    mkdir -p "$overlay"
    cp -R "$pm_libs/ManifestAPI" "$overlay/"
    for interface in "$overlay"/ManifestAPI/*.swiftmodule/*.swiftinterface; do
        [[ "$interface" != *.private.swiftinterface ]] || continue
        cp "$interface" "${interface%.swiftinterface}.private.swiftinterface"
    done
    export SWIFTPM_CUSTOM_LIBS_DIR="$overlay"
    # Some affected CLT installs also retain two definitions of SwiftBridging.
    # Hide only the obsolete auto-discovered map using a compiler VFS overlay.
    : > "$overlay/empty.modulemap"
    /usr/bin/python3 - "$overlay" "$(dirname "$toolchain")/../include/swift/module.modulemap" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
original = str(pathlib.Path(sys.argv[2]).resolve())
(root / 'clang-overlay.json').write_text(json.dumps({
    'version': 0, 'roots': [{'type': 'file', 'name': original,
                           'external-contents': str(root / 'empty.modulemap')}]
}))
PY
    set -- -Xswiftc -vfsoverlay -Xswiftc "$overlay/clang-overlay.json" \
        -Xcc -ivfsoverlay -Xcc "$overlay/clang-overlay.json" "$@"
fi
exec /usr/bin/swift "$operation" --package-path "$native_root" \
    --scratch-path "$native_root/.build" --cache-path "$native_root/.build/cache" \
    --config-path "$native_root/.build/config" --security-path "$native_root/.build/security" "$@"
