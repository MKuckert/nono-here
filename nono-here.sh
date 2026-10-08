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

# Official nolabs-ai registry pack for each harness (nolabs-ai/nono-packs).
# Adding a harness with an official pack is one case branch; a harness
# without a mapping skips the profile check with a notice.
nono_pack_for() {
  case "$1" in
    claude) echo "nolabs-ai/claude" ;;
    opencode) echo "nolabs-ai/opencode" ;;
    codex) echo "nolabs-ai/codex" ;;
    copilot) echo "nolabs-ai/copilot-cli" ;;
    pi) echo "nolabs-ai/pi" ;;
    *) echo "" ;;
  esac
}

# Installed packs live in the pack store: $NONO_PACKAGES, else
# ${XDG_CONFIG_HOME:-$HOME/.config}/nono/packages (nono resolves its config
# via $XDG_CONFIG_HOME/nono; NONO_CONFIG, when set, is its config root).
nono_pack_store() {
  if [[ -n "${NONO_PACKAGES:-}" ]]; then
    echo "$NONO_PACKAGES"
  elif [[ -n "${NONO_CONFIG:-}" ]]; then
    echo "$NONO_CONFIG/packages"
  else
    # ${HOME:-.} keeps set -u happy under launchers that leave HOME unset;
    # the relative ./.config path simply will not contain a pack store.
    echo "${XDG_CONFIG_HOME:-${HOME:-.}/.config}/nono/packages"
  fi
}

# Ensure the selected harness's official nolabs-ai profile pack is installed;
# pull it from the registry when missing. Called only during provisioning,
# immediately before .sandbox creation, so no confirmation prompt or
# validation can abort after the pull has taken effect.
ensure_nono_profile() {
  local harness="$1" pack store
  pack="$(nono_pack_for "$harness")"
  if [[ -z "$pack" ]]; then
    echo "$SELF: no nolabs-ai pack mapping for harness '$harness'; skipping profile check" >&2
    return 0
  fi
  if ! command -v nono >/dev/null 2>&1; then
    echo "$SELF: 'nono' not found in PATH; cannot check for pack '$pack'. Install nono from https://nono.sh/ before running the harness." >&2
    return 0
  fi
  store="$(nono_pack_store)"
  if [[ -d "$store/$pack" ]]; then
    echo "$SELF: profile pack '$pack' is installed ($store/$pack)" >&2
    return 0
  fi
  echo "$SELF: profile pack '$pack' not installed; running: nono pull $pack" >&2
  if ! nono pull "$pack"; then
    die 11 "nono pull $pack failed; re-run $SELF or install it manually: nono pull $pack"
  fi
  # Non-fatal: if the local nono resolves its pack store differently than
  # nono_pack_store() (version drift), surface the mismatch instead of
  # proceeding silently with the profile still missing.
  if [[ ! -d "$store/$pack" ]]; then
    echo "$SELF: Warning: 'nono pull $pack' succeeded but '$store/$pack' was not found; the local nono may use a different pack store. Verify with: nono profile list" >&2
  fi
}

# Export the nono profile JSON schema to $HOME/.nono-here/ so the $schema
# reference in profile.template.json resolves for editors that expand ~.
# Called only during provisioning, alongside the profile pack check above.
# Best-effort by design: the schema only feeds editor validation, so a
# missing nono, an unwritable home, or a failed export warns and
# provisioning continues. SCHEMA_DEST records the destination on success
# (consumed by provision_summary below); it stays empty otherwise.
SCHEMA_DEST=""

export_nono_schema() {
  local home dest
  home="${HOME:-}"
  if [[ -z "$home" ]]; then
    echo "$SELF: HOME is not set; cannot export the nono profile schema to ~/.nono-here/ (editor validation of profile.template.json will be unavailable)" >&2
    return 0
  fi
  if ! command -v nono >/dev/null 2>&1; then
    echo "$SELF: 'nono' not found in PATH; cannot export the nono profile schema to ~/.nono-here/ (editor validation of profile.template.json will be unavailable)" >&2
    return 0
  fi
  dest="$home/.nono-here/nono-profile.schema.json"
  if ! mkdir -p "$home/.nono-here"; then
    echo "$SELF: Warning: cannot create $home/.nono-here; skipping profile schema export" >&2
    return 0
  fi
  if ! nono profile schema --output "$dest"; then
    echo "$SELF: Warning: 'nono profile schema --output $dest' failed; editor validation of profile.template.json will be unavailable" >&2
    return 0
  fi
  # Non-fatal, mirroring the pack-check warning above: a nono that reports
  # success without producing the file (version drift) is surfaced, not fatal.
  if [[ ! -f "$dest" ]]; then
    echo "$SELF: Warning: 'nono profile schema' succeeded but $dest was not created; editor validation of profile.template.json will be unavailable" >&2
    return 0
  fi
  SCHEMA_DEST="$dest"
  echo "$SELF: profile schema exported to $dest" >&2
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

# The single exec site, used by the fast path. Provisioning deliberately
# does not exec (it prints a summary and stops — see provision_summary
# below); whenever a handover does happen, it is from this one place with
# the same CWD and argument handling.
handover() {
  cd "$workdir" || die 1 "cannot enter $workdir"
  exec ./run_harness.sh "$@"
}

# End of provisioning: print a small summary and stop — the first run does
# not launch the harness. The user starts it with ./run_harness.sh (or
# re-runs $SELF, which now takes the silent fast path). Arguments passed to
# the provisioning run are not forwarded; when there are any, the summary
# offers the exact re-run command so they are not lost.
provision_summary() {
  local quoted=() a
  {
    echo "$SELF: provisioned:"
    echo "  workdir:   $workdir"
    echo "  harness:   $harness"
    echo "  template:  $template"
    echo "  sandbox:   $workdir/.sandbox"
    if [[ -n "$SCHEMA_DEST" ]]; then
      echo "  schema:    $SCHEMA_DEST"
    fi
    echo
    echo "  Start the harness:  ./run_harness.sh   (from $workdir)"
    if [[ $# -gt 0 ]]; then
      for a in "$@"; do
        quoted+=("$(printf '%q' "$a")")
      done
      echo
      echo "  Your arguments were not forwarded to the harness (the first run only provisions)."
      echo "  Re-run with them:  ./run_harness.sh ${quoted[*]}"
    fi
    echo
    echo "  Re-running $SELF now takes the fast path and launches the harness."
  } >&2
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

# Profile check (which may pull a pack into the user-level pack store) runs
# only after every path that can still abort — template validation, the
# stale-.sandbox confirmation prompt, the exit-9 guards — so a pull never
# takes effect for a provisioning that ends without creating .sandbox.
ensure_nono_profile "$harness"
export_nono_schema

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

# profile.template.json came from the template via the cp -R above, still
# carrying the generic "NAME" placeholder in meta.name. Substitute it with
# the base name of the workdir so the provisioned project's profile carries
# a unique, meaningful name (its directory) rather than the literal "NAME".
# Only the per-project .sandbox copy is adjusted; the bundled template keeps
# "NAME" as the neutral placeholder. Gracefully skipped when the template
# ships no profile.template.json (a custom template), and a no-op when
# meta.name was already customized away from "NAME" (the sed matches nothing
# and rewrites the file unchanged). Same tmp-then-mv pattern as defaults.sh:
# if it fails before the mv, the placeholder is left in place and the next
# invocation re-enters provisioning to retry.
profile_tpl="$workdir/.sandbox/profile.template.json"
if [[ -f "$profile_tpl" ]]; then
  name_base=$(basename "$workdir")
  # JSON-encode the name so it survives a JSON decode of the profile AND
  # sed's replacement-string processing (in a sed replacement, \\ -> \,
  # \& -> &, and a bare & -> the whole match). A directory base name cannot
  # contain the / delimiter, but can contain \\, &, and ". Per character:
  #   \\  -> \\\\  (file gets \\, which JSON decodes back to \\)
  #   &  -> \&    (file gets &)
  #   "  -> \\"   (file gets \", which JSON decodes back to ")
  # Backslash is escaped first so the backslashes added for & and " are not
  # doubled in turn. (naive escaping of \\ alone would be silently wrong:
  # the file would carry a bare \, which JSON reads as an escape — a name
  # of a\b would decode to a<backspace>.)
  bs='\\'
  name_esc=${name_base//"\\"/"${bs}${bs}"}
  name_esc=${name_esc//&/\\&}
  name_esc=${name_esc//\"/"${bs}\""}
  sed "s/\"name\"[[:space:]]*:[[:space:]]*\"NAME\"/\"name\": \"$name_esc\"/" "$profile_tpl" >"$profile_tpl.tmp"
  mv "$profile_tpl.tmp" "$profile_tpl"
fi

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
# defaults.sh generated. Summarize and stop — the first run does not launch
# the harness; the next invocation takes the silent fast path.
provision_summary "$@"
