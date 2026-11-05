#!/usr/bin/env bash
# VERSION 4
set -euo pipefail

SELF="$(basename "$0")"

# The workspace is anchored to this script's own location, not the CWD or
# the surrounding git repo: run_harness.sh lives in the workspace root, so
# it works no matter which directory it is invoked from (and keeps working
# when the workspace is not a git repo at all). Symlinks are followed,
# bounded to guard against cycles; portable — no readlink -f / realpath
# (must work on macOS/Bash 3.2).
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
WORKSPACE="$(resolve_script_dir)"
DEFAULTS_FILE="${DEFAULTS_FILE:-$WORKSPACE/.sandbox/defaults.sh}"

if [[ ! -f "$DEFAULTS_FILE" ]]; then
  echo "missing defaults file $DEFAULTS_FILE"
  exit 1
fi

source "$DEFAULTS_FILE"
SANDBOX_COMMAND="${SANDBOX_COMMAND:-}"
if [[ "$SANDBOX_COMMAND" = "" ]]; then
  echo "missing 'SANDBOX_COMMAND' in $DEFAULTS_FILE"
  exit 2
fi

if [[ $# -eq 0 || "${1:-}" == -* ]]; then
    set -- ${SANDBOX_COMMAND_DEFAULTS[@]+"${SANDBOX_COMMAND_DEFAULTS[@]}"} "$@"
fi

if [[ "${1:-}" == "$SANDBOX_COMMAND" ]]; then
    shift
fi

"$WORKSPACE/.sandbox/start.sh" "$SANDBOX_COMMAND" "$@"
