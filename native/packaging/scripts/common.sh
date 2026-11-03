#!/bin/bash
# Shared by installer scripts and the installed uninstaller. No environment-selected paths.
fail() { printf 'BatteryCore: %s\n' "$*" >&2; exit 1; }

assert_secure_path() {
    local target="$1" current="" component mode owner
    local -a components
    [[ "$target" == /* && "$target" != *'/../'* && "$target" != *'/./'* ]] || fail "Invalid path."
    local previous_ifs="$IFS"
    IFS='/' read -r -a components <<< "$target"
    IFS="$previous_ifs"
    for component in "${components[@]}"; do
        [[ -n "$component" ]] || continue
        current="$current/$component"
        [[ ! -L "$current" && -e "$current" ]] || fail "Missing or symlinked path: $current"
        owner=$(/usr/bin/stat -f '%u' "$current")
        mode=$(/usr/bin/stat -f '%Lp' "$current")
        [[ "$owner" == 0 && "$mode" =~ ^[0-7]{3,4}$ ]] || fail "Untrusted owner/mode: $current"
        (( (8#$mode & 8#022) == 0 )) || fail "Writable installation path: $current"
    done
}

legacy_files_present() {
    local volume="$1" home
    [[ -e "$volume/private/etc/sudoers.d/battery" || -L "$volume/private/etc/sudoers.d/battery" ]] && return 0
    for home in "$volume"/Users/* "$volume"/var/root; do
        [[ -e "$home/Library/LaunchAgents/com.battery.app.plist" || -L "$home/Library/LaunchAgents/com.battery.app.plist" ]] && return 0
    done
    return 1
}

check_legacy() {
    if legacy_files_present "" || /usr/bin/pgrep -f '^(/bin/bash |/bin/sh |bash |sh )?/usr/local/bin/battery( |$)' >/dev/null; then
        fail "Legacy battery controller detected. Use the migration instructions to stop/remove it before installing BatteryCore."
    fi
}
