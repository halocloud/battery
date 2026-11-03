#!/bin/bash
# Compatibility builder; remote installs use build-release.sh.
set -euo pipefail
native_root="$(cd "$(dirname "$0")/.." && pwd)"
"$native_root/scripts/stage-release.sh" "$@"
out="$native_root/out"
stage="$out/stage"
payload="$stage/root"
version=0.1.0
unsigned="$out/BatteryCore-$version-local.pkg"
/usr/bin/pkgbuild --root "$payload" --scripts "$stage/scripts" --ownership recommended \
    --identifier local.batterycore --version "$version" --install-location / "$unsigned"
if [[ -n "${BATTERYCORE_INSTALLER_IDENTITY:-}" ]]; then
    [[ -n "${BATTERYCORE_APP_IDENTITY:-}" ]] || { echo 'Developer ID Application identity is also required.' >&2; exit 1; }
    signed="$out/BatteryCore-$version.pkg"
    /usr/bin/productsign --sign "$BATTERYCORE_INSTALLER_IDENTITY" "$unsigned" "$signed"
    /usr/sbin/pkgutil --check-signature "$signed"
    if [[ -n "${BATTERYCORE_NOTARY_PROFILE:-}" ]]; then
        /usr/bin/xcrun notarytool submit "$signed" --keychain-profile "$BATTERYCORE_NOTARY_PROFILE" --wait
        /usr/bin/xcrun stapler staple "$signed"
        /usr/bin/xcrun stapler validate "$signed"
    fi
    echo "$signed"
else
    echo "Local test package (not Developer ID signed or notarized): $unsigned"
fi
