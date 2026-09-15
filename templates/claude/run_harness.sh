#!/usr/bin/env bash
# VERSION 3
set -euo pipefail

WORKSPACE=$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")
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
