#!/usr/bin/env bash
set -euo pipefail

SELF=$(basename "$BASH_SOURCE")

# The sandbox directory is anchored to this script's own location, not the
# CWD or the surrounding git repo: start.sh lives in <workspace>/.sandbox,
# so it works no matter which directory it is invoked from (and keeps
# working when the workspace is not a git repo at all). Symlinks are
# followed, bounded to guard against cycles; portable — no readlink -f /
# realpath (must work on macOS/Bash 3.2).
resolve_script_dir() {
    local src dir target hops
    src="$0"
    hops=0
    while [[ -L "$src" ]]; do
        hops=$((hops + 1))
        if [[ "$hops" -gt 40 ]]; then
            echo "$SELF: symlink resolution exceeded 40 hops (possible cycle) for '$0'" >&2
            exit 1
        fi
        dir="$(cd -P "$(dirname "$src")" && pwd)"
        target="$(readlink "$src")"
        case "$target" in
            /*) src="$target" ;;
            *) src="$dir/$target" ;;
        esac
    done
    cd -P "$(dirname "$src")" && pwd
}

# Bare assignment (no local/export): under set -e a failure inside
# resolve_script_dir must abort the script.
SANDBOX_DIR="$(resolve_script_dir)"
WORKSPACE="$(dirname "$SANDBOX_DIR")"
PROFILE_JSON="$SANDBOX_DIR/profile.json"
PROFILE_TEMPLATE="$SANDBOX_DIR/profile.template.json"

if ! command -v nono >/dev/null 2>&1; then
    echo "$SELF: 'nono' sandbox is not installed or not in PATH." >&2
    echo "Install nono from https://nono.sh/" >&2
    exit 127
fi

# Hash of profile.json as last copied from the template. If profile.json
# still matches it, the file is an untouched template copy and can be
# replaced safely on a template update; otherwise it was edited by hand.
PROFILE_HASH="$SANDBOX_DIR/profile.json.sha256"

file_hash() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | cut -d' ' -f1
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        return 1
    fi
}

# Copy the template to profile.json and record its hash. A missing hash
# tool is surfaced, not fatal: the copy still happens, but future template
# updates fall back to the manual-diff prompt.
install_profile() {
    cp "$PROFILE_TEMPLATE" "$PROFILE_JSON"
    if ! file_hash "$PROFILE_JSON" >"$PROFILE_HASH.tmp"; then
        rm -f "$PROFILE_HASH.tmp" "$PROFILE_HASH"
        echo -e "\033[33m$SELF: Warning: neither 'shasum' nor 'sha256sum' found; cannot track manual changes to profile.json.\033[0m" >&2
        return 0
    fi
    mv "$PROFILE_HASH.tmp" "$PROFILE_HASH"
}

# True when profile.json is byte-identical to the copy recorded in the hash.
profile_pristine() {
    local stored current
    [[ -f "$PROFILE_HASH" ]] || return 1
    stored=$(<"$PROFILE_HASH")
    current=$(file_hash "$PROFILE_JSON") || return 1
    [[ -n "$stored" && "$stored" == "$current" ]]
}

# There's no local profile.json yet, copy from template
if [[ ! -f "$PROFILE_JSON" ]]; then
    if [[ -f "$PROFILE_TEMPLATE" ]]; then
        local_ver=$(jq -r '.meta.version // 1' "$PROFILE_TEMPLATE" 2>/dev/null || echo "1")
        echo "$SELF: Copying profile.json from template (v$local_ver). Check contents and adjust to your local environment." >&2
        install_profile
    else
        echo "$SELF: Could not find either profile.json or profile.template.json" >&2
        exit 1
    fi
else
    # Check for version mismatch via meta.version
    if command -v jq >/dev/null 2>&1; then
        tpl_ver=$(jq -r '.meta.version // 0' "$PROFILE_TEMPLATE" 2>/dev/null || echo "0")
        local_ver=$(jq -r '.meta.version // 0' "$PROFILE_JSON" 2>/dev/null || echo "0")

        if (( local_ver < tpl_ver )) && profile_pristine; then
            echo "$SELF: profile.json is an unmodified copy (v$local_ver); updating it to the template (v$tpl_ver)." >&2
            install_profile
        elif (( local_ver < tpl_ver )); then
            echo -e "\n\033[33mYour '$PROFILE_JSON' (v$local_ver) has local changes and is older than the template (v$tpl_ver)!\033[0m" >&2
            echo -e "\033[36m (diff between local config (-) and template (+))\033[0m" >&2
            echo -e "\033[36m--------------------------------------------------------\033[0m" >&2
            # --color=always is GNU-only; BSD diff (macOS) rejects it and the
            # error would be swallowed by `|| true`, losing the diff itself.
            # Probe once and degrade to plain output where unsupported.
            color_opt=""
            if diff --color=always /dev/null /dev/null >/dev/null 2>&1; then
                color_opt="--color=always"
            fi
            diff -u $color_opt "$PROFILE_JSON" "$PROFILE_TEMPLATE" || true
            echo -e "\033[36m--------------------------------------------------------\033[0m" >&2
            echo "Please adjust your '$PROFILE_JSON' (at least the .meta.version field to $tpl_ver) or delete it to reset.\n" >&2
        fi
    else
        if diff -q "$PROFILE_JSON" "$PROFILE_TEMPLATE" >/dev/null 2>&1; then
            :
        elif profile_pristine; then
            echo "$SELF: profile.json is an unmodified copy; updating it to the current template." >&2
            install_profile
        else
          # No version here: tpl_ver is only assigned in the jq branch, and
          # interpolating it would abort under set -u on this degraded path.
          echo -e "\n\033[33mYour '$PROFILE_JSON' differs from the template, but there's no 'jq' installed to check versions.\033[0m" >&2
        fi
    fi
fi

run_hook() {
    local hook_script="$SANDBOX_DIR/hooks/$1"
    if [[ -x "$hook_script" ]]; then
        ( "$hook_script" ) || echo "\033[33mWarning: Hook $1 exited with non-zero status.\033[0m" >&2
    fi
}

cd "$WORKSPACE"
run_hook before
trap 'run_hook after' EXIT

nono wrap \
  --profile "$PROFILE_JSON" \
  --workdir "$WORKSPACE" \
  --allow-cwd \
  -- "$@"
