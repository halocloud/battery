#!/bin/bash
# Standalone bootstrap: download as the user; re-verify in private root-owned staging before installing.
set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

fail() { printf 'BatteryCore: %s\n' "$*" >&2; exit 1; }
check_platform() {
    [[ "$(/usr/bin/uname -m)" == arm64 ]] || fail 'Apple Silicon is required.'
    local version
    version=$(/usr/bin/sw_vers -productVersion)
    [[ "${version%%.*}" -ge 15 ]] || fail 'macOS 15 or later is required.'
}
verify_hash() {
    local file="$1" expected="$2" actual
    [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || fail 'Invalid SHA-256 value.'
    [[ -f "$file" && ! -L "$file" ]] || fail 'Release archive must be a regular file.'
    [[ "$(/usr/bin/stat -f '%z' "$file")" -le 20971520 ]] || fail 'Release archive exceeds the size limit.'
    actual=$(/usr/bin/shasum -a 256 "$file")
    [[ "${actual%% *}" == "$expected" ]] || fail 'Release checksum mismatch; nothing was installed.'
}
validate_archive() {
    local archive="$1" destination="$2" entry count=0 seen='|' listing file architecture
    /bin/mkdir -p "$destination"
    # Check both names and types before extracting anything. No links, paths, duplicates or extra files.
    listing=$(/usr/bin/tar -tzf "$archive") || fail 'Cannot list release archive.'
    while IFS= read -r entry; do
        case "$entry" in
            batteryctl|batteryd|smc|uninstall|common.sh|manifest.json|verified-hardware.json|SMC-LICENSE|SMC-SOURCE.md|README.md|local.batterycore.daemon.plist|preinstall|postinstall) ;;
            *) fail "Unexpected archive entry: $entry" ;;
        esac
        [[ "$seen" != *"|$entry|"* ]] || fail "Duplicate archive entry: $entry"
        seen="$seen$entry|"; count=$((count + 1))
    done <<< "$listing"
    [[ "$count" == 13 ]] || fail 'Release archive is incomplete.'
    listing=$(/usr/bin/tar -tvzf "$archive") || fail 'Cannot inspect release archive.'
    while IFS= read -r entry; do
        [[ "$entry" == -* ]] || fail 'Archive links and special files are not allowed.'
    done <<< "$listing"
    (ulimit -f 32768; umask 077; /usr/bin/tar -xzf "$archive" -C "$destination" --no-same-owner --no-same-permissions) || fail 'Archive extraction failed.'
    for file in batteryctl batteryd smc; do
        [[ -f "$destination/$file" && ! -L "$destination/$file" ]] || fail "Invalid executable: $file"
        /usr/bin/codesign --verify --strict "$destination/$file" || fail "Code signature check failed: $file"
        # /usr/bin/lipo is a developer-tool shim on macOS; file is available without CLT.
        architecture=$(/usr/bin/file -b "$destination/$file")
        [[ "$architecture" == *Mach-O* && "$architecture" == *arm64* ]] || fail "Missing arm64 executable: $file"
    done
    /usr/bin/plutil -lint "$destination/local.batterycore.daemon.plist" >/dev/null || fail 'Invalid service definition.'
    local expected_smc actual_smc
    expected_smc=$(/usr/bin/plutil -extract smcSHA256 raw -o - "$destination/manifest.json") || fail 'Invalid release manifest.'
    actual_smc=$(/usr/bin/shasum -a 256 "$destination/smc")
    [[ "${actual_smc%% *}" == "$expected_smc" ]] || fail 'SMC does not match the release manifest.'
}

restore_previous_tools() {
    local root="$1" backup="$2" had_tools="$3"
    if [[ -d "$backup/tools" ]]; then
        /bin/rm -rf "$root" && /bin/mv "$backup/tools" "$root"
    elif [[ "$had_tools" == 0 ]]; then
        /bin/rm -rf "$root"
    fi
    # If the old directory was never moved, leave it untouched.
}

install_as_root() (
    set -euo pipefail
    umask 077
    [[ "$EUID" == 0 ]] || fail 'Administrator authorization is required.'
    check_platform
    local archive="$1" expected="$2" temporary extracted root state parent file new backup old_loaded=0 changed=0 had_tools=0 had_link=0
    root=/Library/PrivilegedHelperTools/local.batterycore
    state='/Library/Application Support/BatteryCore'
    temporary=$(/usr/bin/mktemp -d /private/tmp/batterycore-root.XXXXXXXX)
    /bin/chmod 700 "$temporary"
    extracted="$temporary/verified"
    new=''; backup=''
    cleanup() {
        local result=$? recovery_failed=0
        trap - EXIT
        set +e
        if [[ "$result" != 0 && "$changed" == 1 ]]; then
            printf '%s\n' 'BatteryCore: installation failed; restoring the previous service.' >&2
            /bin/launchctl bootout system/local.batterycore.daemon >/dev/null 2>&1 || true
            if [[ -n "$backup" ]]; then
                restore_previous_tools "$root" "$backup" "$had_tools" || recovery_failed=1
                if [[ -f "$backup/daemon.plist" ]]; then
                    /usr/bin/install -o root -g wheel -m 644 "$backup/daemon.plist" /Library/LaunchDaemons/local.batterycore.daemon.plist || recovery_failed=1
                else /bin/rm -f /Library/LaunchDaemons/local.batterycore.daemon.plist; fi
            fi
            if [[ "$old_loaded" == 1 && "$recovery_failed" == 0 ]]; then
                /bin/launchctl enable system/local.batterycore.daemon || true
                /bin/launchctl bootstrap system /Library/LaunchDaemons/local.batterycore.daemon.plist || true
                /bin/launchctl kickstart system/local.batterycore.daemon || recovery_failed=1
            fi
            if [[ "$had_link" == 0 && -L /usr/local/bin/batteryctl && "$(/usr/bin/readlink /usr/local/bin/batteryctl)" == "$root/batteryctl" ]]; then
                /bin/rm /usr/local/bin/batteryctl
            fi
        fi
        [[ -z "$new" ]] || /bin/rm -rf "$new"
        if [[ "$recovery_failed" == 0 ]]; then
            [[ -z "$backup" ]] || /bin/rm -rf "$backup"
        else printf 'BatteryCore: recovery needs attention. Backup retained at %s\n' "$backup" >&2; fi
        /bin/rm -rf "$temporary"
        exit "$result"
    }
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    # Copy first, then verify again as root. Never execute scripts from user-writable staging.
    /bin/cp "$archive" "$temporary/release.tar.gz"
    verify_hash "$temporary/release.tar.gz" "$expected"
    validate_archive "$temporary/release.tar.gz" "$extracted"
    source "$extracted/common.sh"
    /bin/bash "$extracted/preinstall" --check-only
    if [[ -d "$root" ]]; then had_tools=1; fi
    if [[ -L /usr/local/bin/batteryctl ]]; then had_link=1; fi
    for parent in /Library/PrivilegedHelperTools /Library/LaunchDaemons; do
        if [[ ! -e "$parent" && ! -L "$parent" ]]; then /usr/bin/install -d -o root -g wheel -m 755 "$parent"; fi
        assert_secure_path "$parent"
    done
    backup=$(/usr/bin/mktemp -d /Library/PrivilegedHelperTools/.batterycore-backup.XXXXXXXX)
    new=$(/usr/bin/mktemp -d /Library/PrivilegedHelperTools/.batterycore-new.XXXXXXXX)
    /bin/chmod 700 "$backup" "$new"
    for file in batteryctl batteryd smc uninstall; do /usr/bin/install -o root -g wheel -m 755 "$extracted/$file" "$new/$file"; done
    for file in common.sh manifest.json verified-hardware.json SMC-LICENSE SMC-SOURCE.md README.md; do
        /usr/bin/install -o root -g wheel -m 644 "$extracted/$file" "$new/$file"
    done
    /bin/chmod 755 "$new"
    if [[ -f /Library/LaunchDaemons/local.batterycore.daemon.plist ]]; then
        /bin/cp /Library/LaunchDaemons/local.batterycore.daemon.plist "$backup/daemon.plist"
    fi
    if /bin/launchctl print system/local.batterycore.daemon >/dev/null 2>&1; then
        old_loaded=1
        # Mark before quiescing so an interrupted upgrade can reactivate the old service.
        changed=1
        "$root/batteryctl" --prepare-upgrade
        /bin/launchctl bootout system/local.batterycore.daemon
    fi
    changed=1
    if [[ -d "$root" ]]; then /bin/mv "$root" "$backup/tools"; fi
    /bin/mv "$new" "$root"; new=''
    /usr/bin/install -o root -g wheel -m 644 "$extracted/local.batterycore.daemon.plist" /Library/LaunchDaemons/local.batterycore.daemon.plist
    /bin/bash "$extracted/postinstall"
    "$root/batteryctl" status >/dev/null
    changed=0
    printf '%s\n' 'Installed. Run batteryctl diagnose. Uninstall with batteryctl uninstall.'
)

download_release() {
    local version="$1" destination="$2" asset base
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'Version must have the form 0.1.0.'
    asset="BatteryCore-$version-macos-arm64.tar.gz"
    base="https://github.com/halocloud/battery/releases/download/native-v$version"
    printf 'Downloading BatteryCore %s…\n' "$version"
    /usr/bin/curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
        --connect-timeout 15 --max-time 300 --output "$destination/release.tar.gz" "$base/$asset" || fail 'Download failed. Confirm this native release has been published.'
    /usr/bin/curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
        --connect-timeout 15 --max-time 60 --output "$destination/release.sha256" "$base/$asset.sha256" || fail 'Cannot download the release checksum.'
    local digest name extra
    read -r digest name extra < "$destination/release.sha256"
    [[ "$name" == "$asset" && -z "${extra:-}" ]] || fail 'Unexpected checksum file.'
    DOWNLOADED_SHA="$digest"
}

main() (
    umask 077
    local version=0.1.0 archive='' expected='' check_only=0 temporary
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --version) [[ $# -ge 2 ]] || fail 'Missing version.'; version="$2"; shift 2 ;;
            --archive) [[ $# -ge 2 ]] || fail 'Missing archive path.'; archive="$2"; shift 2 ;;
            --sha256) [[ $# -ge 2 ]] || fail 'Missing checksum.'; expected="$2"; shift 2 ;;
            --check-only) check_only=1; shift ;;
            --help) printf '%s\n' 'Usage: bash install.sh [--version 0.1.0] [--check-only]' 'Offline: bash install.sh --archive FILE --sha256 SHA256 [--check-only]'; exit 0 ;;
            *) fail "Unknown argument: $1" ;;
        esac
    done
    check_platform
    [[ "$EUID" != 0 ]] || fail 'Run as your normal user; the installer requests sudo only after verification.'
    temporary=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/batterycore-user.XXXXXXXX")
    trap '/bin/rm -rf "$temporary"' EXIT
    if [[ -z "$archive" ]]; then
        download_release "$version" "$temporary"
        archive="$temporary/release.tar.gz"
        if [[ -n "$expected" && "$expected" != "$DOWNLOADED_SHA" ]]; then fail 'Pinned checksum differs from the release checksum.'; fi
        expected="$DOWNLOADED_SHA"
    else
        [[ -n "$expected" ]] || fail '--archive requires --sha256.'
        archive="$(cd "$(/usr/bin/dirname "$archive")" && pwd)/$(/usr/bin/basename "$archive")"
    fi
    verify_hash "$archive" "$expected"
    validate_archive "$archive" "$temporary/check"
    if [[ "$check_only" == 1 ]]; then printf '%s\n' 'Release verified. Check-only: no sudo, service installation, or SMC execution.'; exit 0; fi
    printf '%s\n' 'Release verified. Administrator authorization is needed to install/update the system service.'
    {
        printf '%s\n' 'set -euo pipefail' 'PATH=/usr/bin:/bin:/usr/sbin:/sbin' 'export PATH' 'umask 077'
        declare -f fail check_platform verify_hash validate_archive restore_previous_tools install_as_root
        printf '%s\n' 'install_as_root "$1" "$2"'
    } | /usr/bin/sudo /bin/bash -s -- "$archive" "$expected"
)

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then main "$@"; fi
