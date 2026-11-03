#!/bin/bash
set -euo pipefail
umask 022
native_root="$(cd "$(dirname "$0")/.." && pwd)"
"$native_root/scripts/stage-release.sh" "$@"
out="$native_root/out"
flat="$out/remote"
tools="$out/stage/root/Library/PrivilegedHelperTools/local.batterycore"
/bin/rm -rf "$flat"
/bin/mkdir -p "$flat"
for item in batteryctl batteryd smc uninstall common.sh manifest.json verified-hardware.json SMC-LICENSE SMC-SOURCE.md README.md; do
    /bin/cp "$tools/$item" "$flat/$item"
done
/bin/cp "$out/stage/root/Library/LaunchDaemons/local.batterycore.daemon.plist" "$flat/"
/bin/cp "$out/stage/scripts/preinstall" "$out/stage/scripts/postinstall" "$flat/"
version=$(/usr/bin/plutil -extract version raw -o - "$flat/manifest.json")
asset="BatteryCore-$version-macos-arm64.tar.gz"
# Fixed regular-file entries simplify validation and prohibit archive path traversal.
COPYFILE_DISABLE=1 /usr/bin/tar -czf "$out/$asset" -C "$flat" \
    batteryctl batteryd smc uninstall common.sh manifest.json verified-hardware.json \
    SMC-LICENSE SMC-SOURCE.md README.md local.batterycore.daemon.plist preinstall postinstall
(cd "$out" && /usr/bin/shasum -a 256 "$asset" > "$asset.sha256")
/bin/cp "$native_root/install.sh" "$out/install.sh"
printf 'Remote release: %s\nChecksum: %s\nGitHub release tag: native-v%s\n' "$out/$asset" "$out/$asset.sha256" "$version"
