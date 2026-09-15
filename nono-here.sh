#!/usr/bin/env bash
set -euo pipefail
# VERSION 2

SELF="$(basename "$0")"

# Documented extension point: adding a harness is a one-token edit to this
# array and nothing else.
HARNESSES=(claude opencode codex copilot pi)

die() {
  local code="$1"
  shift
  echo "$SELF: $*" >&2
  exit "$code"
}

# Resolve the script's own directory, following symlinks (portable, no
# readlink -f / realpath — must work on macOS/Bash 3.2). Bounded to guard
# against symlink cycles (e.g. a -> b -> a).
resolve_script_dir() {
  local src dir target hops
  src="$0"
  hops=0
  while [[ -L "$src" ]]; do
    hops=$((hops + 1))
    if [[ "$hops" -gt 40 ]]; then
      die 1 "symlink resolution exceeded 40 hops (possible cycle) for '$0'"
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

# Keep this assignment bare (no `local`/`export`): with `set -e`, a failure
# inside resolve_script_dir must abort the script. Wrapping it would replace
# $? with the local/export builtin's exit status, masking the failure.
script_dir="$(resolve_script_dir)"

# Exported so a future child process can inherit the resolved home; nothing
# consumes it yet.
export NONO_HERE_HOME="${NONO_HERE_HOME:-$script_dir}"

workdir=$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")

# The single exec site, shared by the fast path and the end of provisioning
# so both hand over identically (same CWD, same argument handling).
handover() {
  cd "$workdir" || die 1 "cannot enter $workdir"
  exec ./run_harness.sh "$@"
}

# Fast path: an already-provisioned workspace hands straight over, silently.
# (workdir and template are echoed to stderr only when provisioning happens.)
if [[ -e "$workdir/run_harness.sh" || -L "$workdir/run_harness.sh" ]] && [[ ! -f "$workdir/run_harness.sh" ]]; then
  die 9 "$workdir/run_harness.sh exists but is not a regular file"
elif [[ -f "$workdir/run_harness.sh" ]] && [[ ! -x "$workdir/run_harness.sh" ]]; then
  die 2 "$workdir/run_harness.sh is not executable; run: chmod +x \"$workdir/run_harness.sh\""
elif [[ -f "$workdir/run_harness.sh" ]] && [[ -x "$workdir/run_harness.sh" ]]; then
  if [[ ! -x "$workdir/.sandbox/start.sh" ]]; then
    die 3 "$workdir/.sandbox/start.sh is missing or not executable; run: chmod +x \"$workdir/.sandbox/start.sh\""
  fi
  handover "$@"
fi

# Provisioning begins here: run_harness.sh is entirely absent. Nothing on
# disk changes until a harness and template have been validated.

if [[ -n "${NONO_HERE_HARNESS:-}" ]]; then
  harness=""
  for h in "${HARNESSES[@]}"; do
    if [[ "$h" == "$NONO_HERE_HARNESS" ]]; then
      harness="$h"
      break
    fi
  done
  if [[ -z "$harness" ]]; then
    die 8 "invalid NONO_HERE_HARNESS '$NONO_HERE_HARNESS'; valid values: ${HARNESSES[*]}"
  fi
elif [[ ! -t 0 ]]; then
  die 4 "no TTY for interactive harness selection; set NONO_HERE_HARNESS to one of: ${HARNESSES[*]}"
else
  PS3="harness> "
  select harness in "${HARNESSES[@]}"; do
    if [[ -n "${harness:-}" ]]; then
      break
    fi
    echo "$SELF: invalid selection '$REPLY'; choose a number from the list" >&2
  done
  if [[ -z "${harness:-}" ]]; then
    die 10 "no harness selected (input closed)"
  fi
fi

# Template resolution: user overrides beat bundled templates,
# harness-specific beats default; the first existing directory wins.
template=""
for candidate in \
  "${HOME:-}/.nono-here/templates/$harness" \
  "${HOME:-}/.nono-here/templates/default" \
  "$NONO_HERE_HOME/templates/$harness" \
  "$NONO_HERE_HOME/templates/default"; do
  if [[ -d "$candidate" ]]; then
    template="$candidate"
    break
  fi
done

if [[ -z "$template" ]]; then
  die 5 "no template directory found; probed in order:
${HOME:-}/.nono-here/templates/$harness
${HOME:-}/.nono-here/templates/default
$NONO_HERE_HOME/templates/$harness
$NONO_HERE_HOME/templates/default"
fi

echo "$SELF: workdir: $workdir" >&2
echo "$SELF: template: $template" >&2

for required in run_harness.sh start.sh; do
  if [[ ! -f "$template/$required" ]]; then
    die 7 "template '$template' is missing required file '$required'"
  fi
  if [[ ! -x "$template/$required" ]]; then
    die 7 "template '$template' has '$required' without the executable bit; run: chmod +x \"$template/$required\""
  fi
done

# defaults.sh is sourced, not executed, so it carries no executable-bit
# requirement — but it must exist and still contain the placeholder that
# gets substituted with the chosen harness below.
if [[ ! -f "$template/defaults.sh" ]]; then
  die 7 "template '$template' is missing required file 'defaults.sh'"
fi
if ! grep -q '__NONO_HERE_SANDBOX_COMMAND__' "$template/defaults.sh"; then
  die 7 "template '$template' has 'defaults.sh' without the '__NONO_HERE_SANDBOX_COMMAND__' placeholder"
fi

# A .sandbox without run_harness.sh is the remnant of an interrupted
# previous run. This point is only reached with a fully validated template
# in hand, so deleting it never leaves the workspace with neither sandbox
# nor replacement.
if [[ -e "$workdir/.sandbox" ]]; then
  if [[ ! -t 0 ]]; then
    die 6 "$workdir/.sandbox exists but is incomplete; remove it manually and re-run: rm -r \"$workdir/.sandbox\""
  fi

  echo -e "\033[33mWarning: '$workdir/.sandbox' exists but 'run_harness.sh' is missing — the sandbox is incomplete.\033[0m" >&2
  echo -e "\033[33mIt will be re-created from template '$template'.\033[0m" >&2
  echo -e "\033[33mThis is self-healing: it is the expected result of a previous run interrupted between the copy and completion; re-creating from the template repairs it.\033[0m" >&2

  reply=""
  read -r -p "delete .sandbox and re-create from $template? [y/N] " reply || reply=""
  case "$reply" in
    y | Y) ;;
    *) die 6 "aborted; '$workdir/.sandbox' left untouched" ;;
  esac

  rm -r "$workdir/.sandbox"
fi

# A dangling symlink named .sandbox is invisible to the `-e` test above
# (false for a broken link). Without this guard, `mkdir -p` would abort via
# set -e with a bare, unexplained `File exists`. Every other kind of
# pre-existing .sandbox was already intercepted with exit 6.
if [[ -e "$workdir/.sandbox" || -L "$workdir/.sandbox" ]] && [[ ! -d "$workdir/.sandbox" ]]; then
  die 9 "$workdir/.sandbox exists but is not a directory"
fi

mkdir -p "$workdir/.sandbox"
cp -R "$template/." "$workdir/.sandbox/"

# defaults.sh came from the template via the cp -R above, placeholder and
# all; only the SANDBOX_COMMAND placeholder is substituted here, so every
# other line (including any user-added customization in a custom template)
# passes through untouched. Substitution happens before run_harness.sh is
# moved into place: if it fails, run_harness.sh is still absent, so the
# next invocation re-enters provisioning instead of taking the fast path
# against a workspace that is missing its defaults file.
#
# A dangling symlink named defaults.sh is invisible to `-e`, and writing
# through it would escape .sandbox. Reject any non-regular path. This
# should be unreachable (the template's defaults.sh was already validated
# as a regular file above and cp -R preserves that), but is kept as a
# defensive guard against a template with a symlinked defaults.sh.
if [[ -e "$workdir/.sandbox/defaults.sh" || -L "$workdir/.sandbox/defaults.sh" ]] && [[ ! -f "$workdir/.sandbox/defaults.sh" ]]; then
  die 9 "$workdir/.sandbox/defaults.sh exists but is not a regular file"
fi

sed "s/__NONO_HERE_SANDBOX_COMMAND__/$harness/" "$workdir/.sandbox/defaults.sh" >"$workdir/.sandbox/defaults.sh.tmp"
mv "$workdir/.sandbox/defaults.sh.tmp" "$workdir/.sandbox/defaults.sh"

mv "$workdir/.sandbox/run_harness.sh" "$workdir/run_harness.sh"

# The template's mode bits were validated above; if the copy lost them,
# name the template rather than suggest a `chmod` on a file that will be
# regenerated on the next run.
if [[ ! -x "$workdir/run_harness.sh" ]]; then
  die 7 "template '$template' produced a non-executable 'run_harness.sh'; the copy did not preserve permissions"
fi
if [[ ! -x "$workdir/.sandbox/start.sh" ]]; then
  die 7 "template '$template' produced a non-executable 'start.sh'; the copy did not preserve permissions"
fi

# Provisioning complete: run_harness.sh in place, .sandbox populated,
# defaults.sh generated or preserved. Hand over through the same single
# exec site as the fast path.
handover "$@"
