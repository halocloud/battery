#!/bin/bash
set -euo pipefail
umask 022
native_root="$(cd "$(dirname "$0")/.." && pwd)"
repo_root="$(cd "$native_root/.." && pwd)"
out="$native_root/out"
stage="$out/stage"
version=0.1.0
expected_smc=e3b4392c966dee700f3e1d6cc3812c0d487954c3d6d77b91f521a9590aadae44
actual_smc=$(/usr/bin/shasum -a 256 "$repo_root/dist/smc")
[[ "${actual_smc%% *}" == "$expected_smc" ]] || { echo 'Repository smc changed; audit and update its pinned digest before packaging.' >&2; exit 1; }
"$native_root/scripts/swift.sh" build -c release --arch arm64 "$@"
bin_dir="$("$native_root/scripts/swift.sh" build -c release --arch arm64 --show-bin-path)"
/bin/mkdir -p "$out"
# Only delete the script's fixed staging directory, never a caller-selected path.
/bin/rm -rf "$stage"
payload="$stage/root"
tools="$payload/Library/PrivilegedHelperTools/local.batterycore"
/bin/mkdir -p "$tools" "$payload/Library/LaunchDaemons" "$stage/scripts"
/usr/bin/install -m 755 "$bin_dir/batteryctl" "$bin_dir/batteryd" "$repo_root/dist/smc" "$tools/"
/usr/bin/install -m 755 "$native_root/packaging/uninstall" "$tools/uninstall"
/usr/bin/install -m 644 "$native_root/packaging/scripts/common.sh" "$tools/common.sh"
/usr/bin/install -m 644 "$native_root/packaging/verified-hardware.json" "$tools/verified-hardware.json"
/usr/bin/install -m 644 "$native_root/packaging/local.batterycore.daemon.plist" "$payload/Library/LaunchDaemons/"
/bin/cp "$repo_root/dist/LICENSE" "$tools/SMC-LICENSE"
/bin/cp "$repo_root/dist/README.md" "$tools/SMC-SOURCE.md"
/bin/cp "$native_root/README.md" "$tools/README.md"
/usr/bin/install -m 755 "$native_root/packaging/scripts/preinstall" "$native_root/packaging/scripts/postinstall" "$stage/scripts/"
/usr/bin/install -m 644 "$native_root/packaging/scripts/common.sh" "$stage/scripts/common.sh"
for item in batteryctl batteryd smc; do
    signature_options=(--timestamp=none)
    if [[ -n "${BATTERYCORE_APP_IDENTITY:-}" ]]; then signature_options=(--timestamp); fi
    /usr/bin/codesign --force --sign "${BATTERYCORE_APP_IDENTITY:--}" \
        --identifier "local.batterycore.$item" --options runtime "${signature_options[@]}" "$tools/$item"
    /usr/bin/codesign --verify --strict "$tools/$item"
done
smc_digest=$(/usr/bin/shasum -a 256 "$tools/smc")
/usr/bin/printf '{"version":"%s","smcSHA256":"%s"}\n' "$version" "${smc_digest%% *}" > "$tools/manifest.json"
/usr/bin/plutil -lint "$payload/Library/LaunchDaemons/local.batterycore.daemon.plist"
echo "Release payload staged in $stage"
