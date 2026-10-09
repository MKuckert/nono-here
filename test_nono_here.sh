#!/usr/bin/env bash
set -euo pipefail

# Plain-Bash test harness for nono-here.sh (decision Q20b). No bats, no jq,
# no rsync. Every case runs in its own mktemp -d fixture with HOME and
# NONO_HERE_HOME overridden so the real $HOME is never touched and no
# artefact survives outside the fixture.
#
# Provisioning cases drive the shipped NONO_HERE_HARNESS override (Q22a) —
# the same non-interactive path real CI users get. No test-only branches
# exist in nono-here.sh or the template run_harness.sh.
#
# Exit code coverage: 2-9 are each exercised below, plus 11 (nono pull
# failure) in case 19. Exit 1 is excluded (unexpected-internal-only, S9).
# Exit 10 (Ctrl-D at the `select` prompt) is excluded here: it requires a
# real TTY and was verified manually at Task 3 review; nothing below fakes
# it with a PTY.
#
# Registry isolation: every run_nh child gets a stub `nono` first on PATH
# (NONO_SHIELD) so no case can reach the real registry or write into the
# user's real pack store on a host where nono is installed. Cases that need
# a specific fake nono (case17+) bypass run_nh and set their own PATH.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NONO_HERE="$REPO_ROOT/nono-here.sh"
DEFAULT_TEMPLATE_DIR="$REPO_ROOT/templates/default"

PASS_COUNT=0
FAIL_COUNT=0

# Fixture directories are recorded in a ledger file rather than a bash
# array: new_fixture() is always invoked via command substitution
# ("fx=$(new_fixture)"), which runs in a subshell, so array mutations
# there would never be visible to the parent shell. A file write does
# survive the subshell.
FIXTURE_LEDGER="$(mktemp "${TMPDIR:-/tmp}/nono-here-test-ledger.XXXXXX")"

# Stub `nono` that does nothing and exits 0; see the header note on
# registry isolation.
NONO_SHIELD="$(mktemp -d "${TMPDIR:-/tmp}/nono-here-test-shield.XXXXXX")"
printf '#!/bin/sh\nexit 0\n' >"$NONO_SHIELD/nono"
chmod +x "$NONO_SHIELD/nono"

cleanup() {
  local d
  if [[ -f "$FIXTURE_LEDGER" ]]; then
    while IFS= read -r d; do
      if [[ -n "$d" && -d "$d" ]]; then
        rm -rf "$d"
      fi
    done <"$FIXTURE_LEDGER"
    rm -f "$FIXTURE_LEDGER"
  fi
  rm -rf "$NONO_SHIELD"
  return 0
}
trap 'ec=$?; cleanup; exit $ec' EXIT

# Preflight: every case below writes a fixture script, chmod +x's it and
# executes it. On a noexec ${TMPDIR:-/tmp} (some hardened systems) all of
# those would fail with misleading "not executable" messages that look like
# product bugs. Probe once and fail loud with the real cause.
_probe="$(mktemp -d "${TMPDIR:-/tmp}/nono-here-test-exec.XXXXXX")"
printf '#!/bin/sh\nexit 0\n' >"$_probe/probe.sh"
chmod +x "$_probe/probe.sh"
if ! "$_probe/probe.sh" >/dev/null 2>&1; then
  echo "FATAL: fixture directory ${TMPDIR:-/tmp} is not executable (noexec mount?)." >&2
  echo "Set TMPDIR to an executable directory and re-run: TMPDIR=<dir> $0" >&2
  rm -rf "$_probe"
  exit 1
fi
rm -rf "$_probe"

new_fixture() {
  local dir
  dir="$(mktemp -d "${TMPDIR:-/tmp}/nono-here-test.XXXXXX")"
  echo "$dir" >>"$FIXTURE_LEDGER"
  echo "$dir"
}

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "PASS: $1"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  echo "FAIL: $1 -- $2" >&2
}

sha() {
  shasum -a 256 "$1" | awk '{print $1}'
}

# dir_digest <dir> -> a single digest covering every regular file's path
# and content under <dir>. Unlike hashing one sentinel file, this also
# detects additions, not just mutation/deletion of a known file — that is
# what "byte-for-byte untouched" requires.
dir_digest() {
  local dir="$1" f
  find "$dir" -type f | sort | while IFS= read -r f; do
    printf '%s  %s\n' "$(sha "$f")" "${f#"$dir"/}"
  done | shasum -a 256 | awk '{print $1}'
}

# --- stub scripts -----------------------------------------------------

# Writes a "record argv" stub in place of run_harness.sh. Records argc on
# line 1 followed by NUL-delimited argv, to the file named by
# $RUN_HARNESS_RECORD (env, required at run time).
write_stub_run_harness() {
  local path="$1"
  cat >"$path" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
: "${RUN_HARNESS_RECORD:?RUN_HARNESS_RECORD not set}"
{
  printf '%s\n' "$#"
  if [[ $# -gt 0 ]]; then
    printf '%s\0' "$@"
  fi
} >"$RUN_HARNESS_RECORD"
STUB
  chmod +x "$path"
}

# Same recording convention, for start.sh, via $START_RECORD.
write_stub_start() {
  local path="$1"
  cat >"$path" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
: "${START_RECORD:?START_RECORD not set}"
{
  printf '%s\n' "$#"
  if [[ $# -gt 0 ]]; then
    printf '%s\0' "$@"
  fi
} >"$START_RECORD"
STUB
  chmod +x "$path"
}

# make_template <dir> [marker-text]
# Builds a minimally valid template: executable run_harness.sh and
# start.sh stubs, a defaults.sh carrying the provisioning placeholder,
# optionally a marker.txt to identify it after copy.
make_template() {
  local dir="$1" marker="${2:-}"
  mkdir -p "$dir"
  write_stub_run_harness "$dir/run_harness.sh"
  write_stub_start "$dir/start.sh"
  cat >"$dir/defaults.sh" <<'EOF'
SANDBOX_COMMAND="__NONO_HERE_SANDBOX_COMMAND__"
SANDBOX_COMMAND_DEFAULTS=()
EOF
  if [[ -n "$marker" ]]; then
    printf '%s\n' "$marker" >"$dir/marker.txt"
  fi
}

# read_argv <record-file> -> populates array ARGV_RESULT
# Returns 1 (without aborting the whole suite) on a missing, empty or
# truncated record file, so a stub-script failure fails only the one
# case that produced it.
read_argv() {
  local file="$1" n i arg
  ARGV_RESULT=()
  if [[ ! -s "$file" ]]; then
    return 1
  fi
  exec 3<"$file" || return 1
  if ! IFS= read -r -u 3 n; then
    exec 3<&-
    return 1
  fi
  i=0
  while ((i < n)); do
    if ! IFS= read -r -d '' -u 3 arg; then
      exec 3<&-
      return 1
    fi
    ARGV_RESULT+=("$arg")
    i=$((i + 1))
  done
  exec 3<&-
  return 0
}

argv_eq() {
  # argv_eq expected... -- compares against ARGV_RESULT
  local expected=("$@")
  if [[ "${#ARGV_RESULT[@]}" -ne "${#expected[@]}" ]]; then
    return 1
  fi
  local i
  for ((i = 0; i < ${#expected[@]}; i++)); do
    [[ "${ARGV_RESULT[$i]}" == "${expected[$i]}" ]] || return 1
  done
  return 0
}

# run_nh <workdir> <home> <nono_home> <harness> <record> <stdin> <stdout> <stderr> [args...]
# Echoes the exit code. An empty nono_home/harness/record means genuinely
# unset in the child (via `env -u`), not merely an empty string — Task 4's
# review nit and S4/S5 both require the ambient environment (which may
# already export NONO_HERE_HOME/NONO_HERE_HARNESS for the person running
# this suite) to never leak into a case that means to test the unset
# state, and Case 4 specifically requires a genuinely-unset
# NONO_HERE_HARNESS ("no override"), not an empty one (a different code
# path reaching the same exit code by coincidence).
run_nh() {
  local wd="$1" home="$2" nh="$3" harness="$4" record="$5" stdin="$6" out="$7" err="$8"
  shift 8
  local rc=0
  local env_args=(-u NONO_HERE_HOME -u NONO_HERE_HARNESS -u RUN_HARNESS_RECORD)
  env_args+=(-u XDG_CONFIG_HOME -u NONO_CONFIG -u NONO_PACKAGES)
  env_args+=("HOME=$home")
  env_args+=("PATH=$NONO_SHIELD:$PATH") # registry isolation, see header
  [[ -n "$nh" ]] && env_args+=("NONO_HERE_HOME=$nh")
  [[ -n "$harness" ]] && env_args+=("NONO_HERE_HARNESS=$harness")
  [[ -n "$record" ]] && env_args+=("RUN_HARNESS_RECORD=$record")
  (
    cd "$wd" &&
      env "${env_args[@]}" "$NONO_HERE" "$@"
  ) <"$stdin" >"$out" 2>"$err" || rc=$?
  echo "$rc"
}

# ==================================================================
# Case 1: fast path execs existing run_harness.sh, args forwarded
# verbatim, including one containing a space.
# ==================================================================
case01() {
  local id="1: fast path forwards argv verbatim (incl. arg with space)"
  local fx wd home nh record rc
  fx="$(new_fixture)"
  wd="$fx/work"
  home="$fx/home"
  nh="$fx/nonohome"
  mkdir -p "$wd" "$home" "$nh" "$wd/.sandbox"
  write_stub_run_harness "$wd/run_harness.sh"
  write_stub_start "$wd/.sandbox/start.sh"
  record="$fx/record.bin"

  rc="$(run_nh "$wd" "$home" "$nh" "" "$record" /dev/null "$fx/out" "$fx/err" one "hello world" --flag)"

  if [[ "$rc" != "0" ]]; then
    fail "$id" "expected exit 0, got $rc (stderr: $(cat "$fx/err"))"
    return
  fi
  if ! read_argv "$record"; then
    fail "$id" "record file missing/short: $record"
    return
  fi
  if argv_eq one "hello world" --flag; then
    pass "$id"
  else
    fail "$id" "argv mismatch: ${ARGV_RESULT[*]}"
  fi
}

# ==================================================================
# Case 2: non-executable run_harness.sh -> exit 2
# ==================================================================
case02() {
  local id="2: non-executable run_harness.sh -> exit 2"
  local fx wd home nh rc
  fx="$(new_fixture)"
  wd="$fx/work"
  home="$fx/home"
  nh="$fx/nonohome"
  mkdir -p "$wd" "$home" "$nh"
  echo "not a real script" >"$wd/run_harness.sh"
  chmod -x "$wd/run_harness.sh"

  rc="$(run_nh "$wd" "$home" "$nh" "" "" /dev/null "$fx/out" "$fx/err")"

  if [[ "$rc" == "2" ]]; then
    pass "$id"
  else
    fail "$id" "expected exit 2, got $rc"
  fi
}

# ==================================================================
# Case 3: missing/non-executable start.sh -> exit 3 (fast path)
# ==================================================================
case03() {
  local fx wd home nh rc

  # sub-case: start.sh missing entirely
  fx="$(new_fixture)"
  wd="$fx/work"
  home="$fx/home"
  nh="$fx/nonohome"
  mkdir -p "$wd" "$home" "$nh" "$wd/.sandbox"
  write_stub_run_harness "$wd/run_harness.sh"
  rc="$(run_nh "$wd" "$home" "$nh" "" "" /dev/null "$fx/out" "$fx/err")"
  if [[ "$rc" == "3" ]]; then
    pass "3a: start.sh missing -> exit 3"
  else
    fail "3a: start.sh missing -> exit 3" "got $rc"
  fi

  # sub-case: start.sh present but not executable
  fx="$(new_fixture)"
  wd="$fx/work"
  home="$fx/home"
  nh="$fx/nonohome"
  mkdir -p "$wd" "$home" "$nh" "$wd/.sandbox"
  write_stub_run_harness "$wd/run_harness.sh"
  echo "not executable" >"$wd/.sandbox/start.sh"
  chmod -x "$wd/.sandbox/start.sh"
  rc="$(run_nh "$wd" "$home" "$nh" "" "" /dev/null "$fx/out" "$fx/err")"
  if [[ "$rc" == "3" ]]; then
    pass "3b: start.sh not executable -> exit 3"
  else
    fail "3b: start.sh not executable -> exit 3" "got $rc"
  fi
}

# ==================================================================
# Case 4: non-TTY with no NONO_HERE_HARNESS override -> exit 4
# ==================================================================
case04() {
  local fx wd home nh rc

  # 4a: NONO_HERE_HARNESS genuinely unset (env -u), the common user state
  # the plan wording ("no override") describes. run_nh scrubs it via
  # `env -u` when the harness argument is empty (S4/S5).
  fx="$(new_fixture)"
  wd="$fx/work"
  home="$fx/home"
  nh="$fx/nonohome"
  mkdir -p "$wd" "$home" "$nh"
  rc="$(run_nh "$wd" "$home" "$nh" "" "" /dev/null "$fx/out" "$fx/err")"
  if [[ "$rc" == "4" ]]; then
    pass "4a: non-TTY, NONO_HERE_HARNESS genuinely unset -> exit 4"
  else
    fail "4a: non-TTY, NONO_HERE_HARNESS genuinely unset -> exit 4" "got $rc"
  fi

  # 4b: NONO_HERE_HARNESS explicitly exported as an empty string — a
  # different route (the script's [[ -n ]] check is false either way)
  # that must reach the same exit 4, not fall through undetected.
  fx="$(new_fixture)"
  wd="$fx/work"
  home="$fx/home"
  nh="$fx/nonohome"
  mkdir -p "$wd" "$home" "$nh"
  local rc2=0
  (
    cd "$wd" &&
      env -u NONO_HERE_HARNESS \
        HOME="$home" \
        NONO_HERE_HOME="$nh" \
        NONO_HERE_HARNESS="" \
        "$NONO_HERE"
  ) </dev/null >"$fx/out" 2>"$fx/err" || rc2=$?
  if [[ "$rc2" == "4" ]]; then
    pass "4b: non-TTY, NONO_HERE_HARNESS explicitly empty -> exit 4"
  else
    fail "4b: non-TTY, NONO_HERE_HARNESS explicitly empty -> exit 4" "got $rc2"
  fi
}

# ==================================================================
# Case 5: invalid NONO_HERE_HARNESS -> exit 8, no prompt, nothing written
# ==================================================================
case05() {
  local id="5: invalid NONO_HERE_HARNESS -> exit 8, nothing written"
  local fx wd home nh rc
  fx="$(new_fixture)"
  wd="$fx/work"
  home="$fx/home"
  nh="$fx/nonohome"
  mkdir -p "$wd" "$home" "$nh"

  rc="$(run_nh "$wd" "$home" "$nh" "no-such-harness" "" /dev/null "$fx/out" "$fx/err")"

  if [[ "$rc" != "8" ]]; then
    fail "$id" "expected exit 8, got $rc"
    return
  fi
  if [[ -e "$wd/.sandbox" || -e "$wd/run_harness.sh" ]]; then
    fail "$id" "unexpected filesystem writes in workdir"
    return
  fi
  pass "$id"
}

# ==================================================================
# Case 6: template precedence across all four positions
# ==================================================================
case06_sub() {
  local label="$1" harness="$2" want_marker="$3"
  shift 3
  local positions=("$@") # list of position names to actually create: A B C D
  local fx wd home nh record rc pos
  fx="$(new_fixture)"
  wd="$fx/work"
  home="$fx/home"
  nh="$fx/nonohome"
  mkdir -p "$wd" "$home" "$nh"
  record="$fx/record.bin"

  for pos in "${positions[@]}"; do
    case "$pos" in
      A) make_template "$home/.nono-here/templates/$harness" A ;;
      B) make_template "$home/.nono-here/templates/default" B ;;
      C) make_template "$nh/templates/$harness" C ;;
      D) make_template "$nh/templates/default" D ;;
    esac
  done

  rc="$(run_nh "$wd" "$home" "$nh" "$harness" "$record" /dev/null "$fx/out" "$fx/err")"

  if [[ "$rc" != "0" ]]; then
    fail "$label" "expected exit 0, got $rc (stderr: $(cat "$fx/err"))"
    return
  fi
  if [[ ! -f "$wd/.sandbox/marker.txt" ]]; then
    fail "$label" "marker.txt missing from .sandbox"
    return
  fi
  local got
  got="$(cat "$wd/.sandbox/marker.txt")"
  if [[ "$got" == "$want_marker" ]]; then
    pass "$label"
  else
    fail "$label" "expected marker $want_marker, got $got"
  fi
}

case06() {
  local harness="codex"
  case06_sub "6a: HOME/.nono-here/templates/\$harness wins" "$harness" A A B C D
  case06_sub "6b: HOME/.nono-here/templates/default wins (no harness-specific)" "$harness" B B C D
  case06_sub "6c: NONO_HERE_HOME/templates/\$harness wins (no HOME overrides)" "$harness" C C D
  case06_sub "6d: NONO_HERE_HOME/templates/default is last resort" "$harness" D D
}

# ==================================================================
# Case 7: no template found -> exit 5, all four paths in stderr
# ==================================================================
case07() {
  local id="7: no template found -> exit 5, all four paths listed"
  local fx wd home nh rc err_content
  fx="$(new_fixture)"
  wd="$fx/work"
  home="$fx/home"
  nh="$fx/nonohome"
  mkdir -p "$wd" "$home" "$nh"

  rc="$(run_nh "$wd" "$home" "$nh" "codex" "" /dev/null "$fx/out" "$fx/err")"

  if [[ "$rc" != "5" ]]; then
    fail "$id" "expected exit 5, got $rc"
    return
  fi
  err_content="$(cat "$fx/err")"
  local expect_paths=(
    "$home/.nono-here/templates/codex"
    "$home/.nono-here/templates/default"
    "$nh/templates/codex"
    "$nh/templates/default"
  )
  local p
  for p in "${expect_paths[@]}"; do
    if [[ "$err_content" != *"$p"* ]]; then
      fail "$id" "stderr missing path: $p"
      return
    fi
  done
  pass "$id"
}

# ==================================================================
# Case 8: malformed template -> exit 7, pre-existing .sandbox untouched
# ==================================================================
case08_sub() {
  local label="$1" mangle="$2"
  local fx wd home nh rc digest_before digest_after
  fx="$(new_fixture)"
  wd="$fx/work"
  home="$fx/home"
  nh="$fx/nonohome"
  mkdir -p "$wd" "$home" "$nh" "$wd/.sandbox"
  echo "stale-sentinel-$RANDOM" >"$wd/.sandbox/sentinel.txt"
  digest_before="$(dir_digest "$wd/.sandbox")"

  make_template "$nh/templates/default"
  case "$mangle" in
    missing_run_harness) rm "$nh/templates/default/run_harness.sh" ;;
    missing_start) rm "$nh/templates/default/start.sh" ;;
    start_not_exec) chmod -x "$nh/templates/default/start.sh" ;;
  esac

  rc="$(run_nh "$wd" "$home" "$nh" "codex" "" /dev/null "$fx/out" "$fx/err")"

  if [[ "$rc" != "7" ]]; then
    fail "$label" "expected exit 7, got $rc (stderr: $(cat "$fx/err"))"
    return
  fi
  digest_after="$(dir_digest "$wd/.sandbox")"
  if [[ "$digest_before" != "$digest_after" ]]; then
    fail "$label" ".sandbox contents changed (digest mismatch)"
    return
  fi
  pass "$label"
}

case08() {
  case08_sub "8a: template missing run_harness.sh -> exit 7, .sandbox intact" missing_run_harness
  case08_sub "8b: template missing start.sh -> exit 7, .sandbox intact" missing_start
  case08_sub "8c: template start.sh not executable -> exit 7, .sandbox intact" start_not_exec
}

# ==================================================================
# Case 9: stale .sandbox, non-TTY -> exit 6, directory untouched
# ==================================================================
case09() {
  local id="9: stale .sandbox, non-TTY -> exit 6, untouched"
  local fx wd home nh rc before after
  fx="$(new_fixture)"
  wd="$fx/work"
  home="$fx/home"
  nh="$fx/nonohome"
  mkdir -p "$wd" "$home" "$nh" "$wd/.sandbox"
  echo "stale-sentinel-$RANDOM" >"$wd/.sandbox/sentinel.txt"
  make_template "$nh/templates/default"
  before="$(dir_digest "$wd/.sandbox")"

  rc="$(run_nh "$wd" "$home" "$nh" "codex" "" /dev/null "$fx/out" "$fx/err")"

  if [[ "$rc" != "6" ]]; then
    fail "$id" "expected exit 6, got $rc"
    return
  fi
  after="$(dir_digest "$wd/.sandbox")"
  if [[ "$before" != "$after" ]]; then
    fail "$id" ".sandbox contents changed (digest mismatch)"
    return
  fi
  pass "$id"
}

# ==================================================================
# Case 10: stale .sandbox, 'y' piped on stdin, no TTY -> still exit 6
# ==================================================================
case10() {
  local id="10: stale .sandbox, piped 'y' without TTY -> still exit 6"
  local fx wd home nh rc before after stdin_file
  fx="$(new_fixture)"
  wd="$fx/work"
  home="$fx/home"
  nh="$fx/nonohome"
  mkdir -p "$wd" "$home" "$nh" "$wd/.sandbox"
  echo "stale-sentinel-$RANDOM" >"$wd/.sandbox/sentinel.txt"
  make_template "$nh/templates/default"
  before="$(dir_digest "$wd/.sandbox")"
  stdin_file="$fx/stdin"
  printf 'y\n' >"$stdin_file"

  rc="$(run_nh "$wd" "$home" "$nh" "codex" "" "$stdin_file" "$fx/out" "$fx/err")"

  if [[ "$rc" != "6" ]]; then
    fail "$id" "expected exit 6, got $rc"
    return
  fi
  after="$(dir_digest "$wd/.sandbox")"
  if [[ "$before" != "$after" ]]; then
    fail "$id" ".sandbox was modified despite no TTY (digest mismatch)"
    return
  fi
  pass "$id"
}

# ==================================================================
# Case 11: generated defaults.sh content matches selected harness
# ==================================================================
case11() {
  local id="11: generated defaults.sh matches selected harness"
  local fx wd home nh record rc content
  fx="$(new_fixture)"
  wd="$fx/work"
  home="$fx/home"
  nh="$fx/nonohome"
  mkdir -p "$wd" "$home" "$nh"
  make_template "$nh/templates/default"
  record="$fx/record.bin"

  rc="$(run_nh "$wd" "$home" "$nh" "opencode" "$record" /dev/null "$fx/out" "$fx/err")"

  if [[ "$rc" != "0" ]]; then
    fail "$id" "expected exit 0, got $rc (stderr: $(cat "$fx/err"))"
    return
  fi
  if [[ ! -f "$wd/.sandbox/defaults.sh" ]]; then
    fail "$id" "defaults.sh not generated"
    return
  fi
  content="$(cat "$wd/.sandbox/defaults.sh")"
  if [[ "$content" == *'SANDBOX_COMMAND="opencode"'* && "$content" == *'SANDBOX_COMMAND_DEFAULTS=()'* ]]; then
    pass "$id"
  else
    fail "$id" "unexpected content: $content"
  fi
}

# ==================================================================
# Case 12: template-provided defaults.sh passes through untouched except
# the placeholder, which is substituted with the selected harness
# ==================================================================
case12() {
  local id="12: template-provided defaults.sh passes through, placeholder substituted"
  local fx wd home nh record rc content
  fx="$(new_fixture)"
  wd="$fx/work"
  home="$fx/home"
  nh="$fx/nonohome"
  mkdir -p "$wd" "$home" "$nh"
  make_template "$nh/templates/default"
  cat >"$nh/templates/default/defaults.sh" <<'EOF'
# custom harness-provided defaults
SANDBOX_COMMAND="__NONO_HERE_SANDBOX_COMMAND__"
EXTRA_LINE="keep me"
SANDBOX_COMMAND_DEFAULTS=("--custom-flag")
EOF
  record="$fx/record.bin"

  rc="$(run_nh "$wd" "$home" "$nh" "pi" "$record" /dev/null "$fx/out" "$fx/err")"

  if [[ "$rc" != "0" ]]; then
    fail "$id" "expected exit 0, got $rc (stderr: $(cat "$fx/err"))"
    return
  fi
  if [[ ! -f "$wd/.sandbox/defaults.sh" ]]; then
    fail "$id" "defaults.sh missing after provisioning"
    return
  fi
  content="$(cat "$wd/.sandbox/defaults.sh")"
  if [[ "$content" == *'SANDBOX_COMMAND="pi"'* \
      && "$content" == *'EXTRA_LINE="keep me"'* \
      && "$content" == *'SANDBOX_COMMAND_DEFAULTS=("--custom-flag")'* \
      && "$content" != *'__NONO_HERE_SANDBOX_COMMAND__'* ]]; then
    pass "$id"
  else
    fail "$id" "unexpected content: $content"
  fi
}

# ==================================================================
# Case 13: run_harness.sh argv correctness with empty/unset/populated
# SANDBOX_COMMAND_DEFAULTS, under /bin/bash and any newer bash on PATH.
# (Regression test for Task 10.)
# ==================================================================
find_bashes() {
  BASHES=()
  local candidate resolved already existing

  for candidate in /bin/bash "$(command -v bash)" /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [[ -n "$candidate" && -x "$candidate" ]] || continue
    resolved="$(cd "$(dirname "$candidate")" && pwd)/$(basename "$candidate")"
    already=0
    for existing in "${BASHES[@]+"${BASHES[@]}"}"; do
      [[ "$existing" == "$resolved" ]] && already=1
    done
    ((already)) || BASHES+=("$resolved")
  done

  # S2: never silently trust that Bash 3.2 coverage was exercised. Print
  # the version of every binary under test, and if none is 3.2-era,
  # disclose the degraded coverage loudly instead of printing passing
  # lines that prove nothing about Task 10's regression.
  local b ver have_32=0
  for b in "${BASHES[@]}"; do
    ver="$("$b" --version | head -1)"
    echo "case13: bash under test: $b -> $ver"
    # Match 3.2 explicitly: a host with only Bash 3.0/3.1 does not verify
    # the targeted macOS 3.2 behavior and must still trigger the warning.
    if [[ "$ver" == *"version 3.2."* ]]; then
      have_32=1
    fi
  done
  if ((! have_32)); then
    echo "WARN: case13: no Bash 3.2-era binary found on PATH or at the usual" \
      "locations (/bin/bash, /opt/homebrew/bin/bash, /usr/local/bin/bash);" \
      "Task 10's Bash-3.2 empty-array regression coverage is DEGRADED to" \
      "${BASHES[*]} only on this host. This is a disclosed environment gap," \
      "not a passing 3.2 check." >&2
  fi
}

# copy_named_array <src-array-name> <dest-array-name>
# Bash 3.2 has no nameref; this copies an array given only its name,
# without ever expanding "${name[@]}" on a possibly-empty array (which
# traps under set -u on Bash 3.2 — the same class of bug this suite
# regression-tests in run_harness.sh).
copy_named_array() {
  local __src="$1" __dst="$2" __n __i __val
  eval "__n=\${#${__src}[@]}"
  eval "$__dst=()"
  for ((__i = 0; __i < __n; __i++)); do
    eval "__val=\"\${${__src}[$__i]}\""
    eval "$__dst+=(\"\$__val\")"
  done
}

# case13_sub <label> <bash_bin> <defaults_body> <invoke_args_arrayname> <expected_arrayname>
case13_sub() {
  local label="$1" bash_bin="$2" defaults_body="$3" invoke_args_name="$4" expected_name="$5"
  local fx wd start_record rc
  local invoke_args=() expected=()
  copy_named_array "$invoke_args_name" invoke_args
  copy_named_array "$expected_name" expected

  fx="$(new_fixture)"
  wd="$fx/work"
  mkdir -p "$wd/.sandbox"
  cp "$DEFAULT_TEMPLATE_DIR/run_harness.sh" "$wd/run_harness.sh"
  chmod +x "$wd/run_harness.sh"
  write_stub_start "$wd/.sandbox/start.sh"
  start_record="$fx/start_record.bin"
  printf '%s\n' "$defaults_body" >"$wd/.sandbox/defaults.sh"

  local out_file="$fx/out" err_file="$fx/err"
  rc=0
  (
    cd "$wd" &&
      env -u DEFAULTS_FILE -u SANDBOX_COMMAND -u SANDBOX_COMMAND_DEFAULTS \
        START_RECORD="$start_record" \
        "$bash_bin" ./run_harness.sh "${invoke_args[@]+"${invoke_args[@]}"}"
  ) >"$out_file" 2>"$err_file" || rc=$?

  if [[ "$rc" != "0" ]]; then
    fail "$label" "expected exit 0 under $bash_bin, got $rc (stderr: $(cat "$err_file"))"
    return
  fi
  if ! read_argv "$start_record"; then
    fail "$label ($bash_bin)" "record file missing/short: $start_record"
    return
  fi
  if argv_eq "${expected[@]}"; then
    pass "$label ($bash_bin)"
  else
    fail "$label ($bash_bin)" "expected [${expected[*]}] got [${ARGV_RESULT[*]}]"
  fi
}

case13() {
  find_bashes
  local b
  local empty_args=() no_defaults_expected=(foo)
  local flagonly_args=(--verbose) populated_expected=(foo --msg "hello world" --verbose)
  for b in "${BASHES[@]}"; do
    case13_sub "13a: empty SANDBOX_COMMAND_DEFAULTS, no args" "$b" \
      $'SANDBOX_COMMAND="foo"\nSANDBOX_COMMAND_DEFAULTS=()' \
      empty_args no_defaults_expected

    case13_sub "13b: unset SANDBOX_COMMAND_DEFAULTS, no args" "$b" \
      $'SANDBOX_COMMAND="foo"' \
      empty_args no_defaults_expected

    case13_sub "13c: populated defaults (incl. arg with space) prepended on flag-only invocation" "$b" \
      $'SANDBOX_COMMAND="foo"\nSANDBOX_COMMAND_DEFAULTS=("--msg" "hello world")' \
      flagonly_args populated_expected
  done
}

# ==================================================================
# Case 14: NONO_HERE_HOME derived correctly when invoked through a
# symlink (must resolve to the *real* script's directory, not
# wherever the symlink lives).
# ==================================================================
case14() {
  local id="14: NONO_HERE_HOME resolves through a symlink"
  local fx real_dir link_path wd home record rc
  fx="$(new_fixture)"
  real_dir="$fx/real"
  mkdir -p "$real_dir"
  cp "$NONO_HERE" "$real_dir/nono-here.sh"
  chmod +x "$real_dir/nono-here.sh"
  make_template "$real_dir/templates/default" "SYMLINK-RESOLVED"

  mkdir -p "$fx/elsewhere"
  link_path="$fx/elsewhere/nono-here.sh"
  ln -s "$real_dir/nono-here.sh" "$link_path"

  wd="$fx/work"
  home="$fx/home"
  mkdir -p "$wd" "$home"
  record="$fx/record.bin"

  local rc2=0
  (
    cd "$wd" &&
      env -u NONO_HERE_HOME \
        -u XDG_CONFIG_HOME -u NONO_CONFIG -u NONO_PACKAGES \
        HOME="$home" \
        NONO_HERE_HARNESS="codex" \
        RUN_HARNESS_RECORD="$record" \
        PATH="$NONO_SHIELD:$PATH" \
        "$link_path"
  ) >"$fx/out" 2>"$fx/err" || rc2=$?
  rc="$rc2"

  if [[ "$rc" != "0" ]]; then
    fail "$id" "expected exit 0, got $rc (stderr: $(cat "$fx/err"))"
    return
  fi
  if [[ ! -f "$wd/.sandbox/marker.txt" ]]; then
    fail "$id" "marker.txt missing; template not resolved via symlink's real directory"
    return
  fi
  local got
  got="$(cat "$wd/.sandbox/marker.txt")"
  if [[ "$got" == "SYMLINK-RESOLVED" ]]; then
    pass "$id"
  else
    fail "$id" "expected marker SYMLINK-RESOLVED, got $got"
  fi
}

# ==================================================================
# Case 15: workdir is the git root when run from a nested subdirectory
# ==================================================================
case15() {
  local id="15: workdir resolves to git root from nested subdir"
  local fx repo nested home nh record rc
  fx="$(new_fixture)"
  repo="$fx/repo"
  mkdir -p "$repo"
  git -C "$repo" init -q
  nested="$repo/a/b"
  mkdir -p "$nested"
  home="$fx/home"
  nh="$fx/nonohome"
  mkdir -p "$home" "$nh"
  make_template "$nh/templates/default"
  record="$fx/record.bin"

  rc="$(run_nh "$nested" "$home" "$nh" "codex" "$record" /dev/null "$fx/out" "$fx/err")"

  if [[ "$rc" != "0" ]]; then
    fail "$id" "expected exit 0, got $rc (stderr: $(cat "$fx/err"))"
    return
  fi
  if [[ -d "$repo/.sandbox" && ! -d "$nested/.sandbox" ]]; then
    pass "$id"
  else
    fail "$id" "expected .sandbox at git root only (repo=$([[ -d "$repo/.sandbox" ]] && echo yes || echo no), nested=$([[ -d "$nested/.sandbox" ]] && echo yes || echo no))"
  fi
}

# ==================================================================
# Case 16: workspace run_harness.sh is a directory -> exit 9, nothing
# moved into it.
# ==================================================================
case16() {
  local id="16: workspace run_harness.sh is a directory -> exit 9"
  local fx wd home nh rc
  fx="$(new_fixture)"
  wd="$fx/work"
  home="$fx/home"
  nh="$fx/nonohome"
  mkdir -p "$wd" "$home" "$nh" "$wd/run_harness.sh"
  make_template "$nh/templates/default"

  rc="$(run_nh "$wd" "$home" "$nh" "codex" "" /dev/null "$fx/out" "$fx/err")"

  if [[ "$rc" != "9" ]]; then
    fail "$id" "expected exit 9, got $rc"
    return
  fi
  if [[ ! -d "$wd/run_harness.sh" ]]; then
    fail "$id" "run_harness.sh is no longer a directory"
    return
  fi
  if [[ -n "$(ls -A "$wd/run_harness.sh")" ]]; then
    fail "$id" "something was moved into the run_harness.sh directory"
    return
  fi
  pass "$id"
}

# ==================================================================
# Cases 17-20: nolabs-ai profile pack check during provisioning
# ==================================================================

# write_fake_nono <path> <calls-file> [fail_pull]
# Records each invocation as one "argv" line; `pull` exits fail_pull
# (default 0), everything else exits 0.
write_fake_nono() {
  local path="$1" calls="$2" fail_pull="${3:-0}"
  cat >"$path" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >>"$calls"
if [ "\${1:-}" = "pull" ]; then exit $fail_pull; fi
exit 0
STUB
  chmod +x "$path"
}

# write_schema_nono <path> <calls-file> [fail_schema]
# Like write_fake_nono, but also implements `profile schema --output <path>`
# (writes a sentinel file) and `profile schema` exits fail_schema (default
# 0). Lets cases 22/23 drive the schema-export code path deterministically.
write_schema_nono() {
  local path="$1" calls="$2" fail_schema="${3:-0}"
  cat >"$path" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >>"$calls"
if [ "\${1:-}" = "profile" ] && [ "\${2:-}" = "schema" ]; then
  if [ $fail_schema -ne 0 ]; then exit $fail_schema; fi
  out=""
  while [ \$# -gt 0 ]; do
    if [ "\$1" = "--output" ]; then out="\$2"; fi
    shift
  done
  if [ -n "\$out" ]; then printf '{"title":"nono-profile (test sentinel)"}\n' >"\$out"; fi
  exit 0
fi
exit 0
STUB
  chmod +x "$path"
}

# run_nh_profile <workdir> <home> <nono_home> <harness> <record> <calls>
# <bin-dir> <stdout> <stderr> [fail_pull] -> echoes the exit code. Like
# run_nh, but with a custom PATH ($bin-dir first) so the case controls which
# `nono` the child sees, and with a recording fake nono installed in
# $bin-dir.
run_nh_profile() {
  local wd="$1" home="$2" nh="$3" harness="$4" record="$5" calls="$6" bindir="$7" out="$8" err="$9" fail_pull="${10:-0}"
  local rc=0
  write_fake_nono "$bindir/nono" "$calls" "$fail_pull"
  (
    cd "$wd" &&
      env -u NONO_HERE_HOME -u NONO_HERE_HARNESS -u RUN_HARNESS_RECORD \
        -u XDG_CONFIG_HOME -u NONO_CONFIG -u NONO_PACKAGES \
        HOME="$home" NONO_HERE_HOME="$nh" NONO_HERE_HARNESS="$harness" \
        RUN_HARNESS_RECORD="$record" PATH="$bindir:$PATH" \
        "$NONO_HERE"
  ) </dev/null >"$out" 2>"$err" || rc=$?
  echo "$rc"
}

# ==================================================================
# Case 17: pack already installed -> no pull, provisioning completes
# ==================================================================
case17() {
  local id="17: pack installed -> no pull, exit 0"
  local fx wd home nh record calls bin rc
  fx="$(new_fixture)"
  wd="$fx/work"; home="$fx/home"; nh="$fx/nonohome"; bin="$fx/bin"
  mkdir -p "$wd" "$home" "$nh" "$bin"
  make_template "$nh/templates/default"
  # Installed pack in the child's HOME pack store.
  mkdir -p "$home/.config/nono/packages/nolabs-ai/codex"
  echo '{}' >"$home/.config/nono/packages/nolabs-ai/codex/package.json"
  record="$fx/record.bin"; calls="$fx/nono_calls"

  rc="$(run_nh_profile "$wd" "$home" "$nh" "codex" "$record" "$calls" "$bin" "$fx/out" "$fx/err")"

  if [[ "$rc" != "0" ]]; then
    fail "$id" "expected exit 0, got $rc (stderr: $(cat "$fx/err"))"
    return
  fi
  if [[ -s "$calls" ]] && grep -q '^pull ' "$calls"; then
    fail "$id" "nono pull was called although the pack is installed: $(cat "$calls")"
    return
  fi
  if grep -q "profile pack 'nolabs-ai/codex' is installed" "$fx/err"; then
    pass "$id"
  else
    fail "$id" "stderr missing installed notice: $(cat "$fx/err")"
  fi
}

# ==================================================================
# Case 18: pack missing -> nono pull with the mapped name, exit 0
# ==================================================================
case18() {
  local id="18: pack missing -> nono pull nolabs-ai/codex, exit 0"
  local fx wd home nh record calls bin rc
  fx="$(new_fixture)"
  wd="$fx/work"; home="$fx/home"; nh="$fx/nonohome"; bin="$fx/bin"
  mkdir -p "$wd" "$home" "$nh" "$bin"
  make_template "$nh/templates/default"
  record="$fx/record.bin"; calls="$fx/nono_calls"

  rc="$(run_nh_profile "$wd" "$home" "$nh" "codex" "$record" "$calls" "$bin" "$fx/out" "$fx/err")"

  if [[ "$rc" != "0" ]]; then
    fail "$id" "expected exit 0, got $rc (stderr: $(cat "$fx/err"))"
    return
  fi
  if [[ ! -f "$wd/run_harness.sh" ]]; then
    fail "$id" "run_harness.sh not provisioned"
    return
  fi
  if [[ -f "$calls" ]] && grep -q '^pull nolabs-ai/codex$' "$calls"; then
    pass "$id"
  else
    fail "$id" "expected 'pull nolabs-ai/codex', calls: $(cat "$calls" 2>/dev/null)"
  fi
}

# ==================================================================
# Case 19: nono pull fails -> exit 11, workspace untouched
# ==================================================================
case19() {
  local id="19: nono pull fails -> exit 11, workspace untouched"
  local fx wd home nh record calls bin rc
  fx="$(new_fixture)"
  wd="$fx/work"; home="$fx/home"; nh="$fx/nonohome"; bin="$fx/bin"
  mkdir -p "$wd" "$home" "$nh" "$bin"
  make_template "$nh/templates/default"
  record="$fx/record.bin"; calls="$fx/nono_calls"

  rc="$(run_nh_profile "$wd" "$home" "$nh" "codex" "$record" "$calls" "$bin" "$fx/out" "$fx/err" 7)"

  if [[ "$rc" != "11" ]]; then
    fail "$id" "expected exit 11, got $rc (stderr: $(cat "$fx/err"))"
    return
  fi
  if [[ -e "$wd/run_harness.sh" || -e "$wd/.sandbox" ]]; then
    fail "$id" "workspace modified despite failed pull"
    return
  fi
  if grep -q 'nono pull nolabs-ai/codex failed' "$fx/err"; then
    pass "$id"
  else
    fail "$id" "stderr missing failure message: $(cat "$fx/err")"
  fi
}

# ==================================================================
# Case 20: nono absent from PATH -> warning, provisioning still completes
# ==================================================================
case20() {
  local id="20: nono absent -> warning, exit 0"
  local fx wd home nh record bin rc t
  fx="$(new_fixture)"
  wd="$fx/work"; home="$fx/home"; nh="$fx/nonohome"; bin="$fx/bin"
  mkdir -p "$wd" "$home" "$nh" "$bin"
  make_template "$nh/templates/default"
  record="$fx/record.bin"

  # Minimal PATH: only the tools nono-here.sh needs, and no `nono`.
  for t in bash basename dirname git grep mkdir cp sed mv; do
    ln -s "$(command -v "$t")" "$bin/$t"
  done

  local rc2=0
  (
    cd "$wd" &&
      env -u NONO_HERE_HOME -u NONO_HERE_HARNESS -u RUN_HARNESS_RECORD \
        -u XDG_CONFIG_HOME -u NONO_CONFIG -u NONO_PACKAGES \
        HOME="$home" NONO_HERE_HOME="$nh" NONO_HERE_HARNESS="pi" \
        RUN_HARNESS_RECORD="$record" PATH="$bin" \
        "$NONO_HERE"
  ) </dev/null >"$fx/out" 2>"$fx/err" || rc2=$?
  rc="$rc2"

  if [[ "$rc" != "0" ]]; then
    fail "$id" "expected exit 0, got $rc (stderr: $(cat "$fx/err"))"
    return
  fi
  if [[ ! -f "$wd/run_harness.sh" ]]; then
    fail "$id" "run_harness.sh not provisioned"
    return
  fi
  if grep -q "'nono' not found in PATH" "$fx/err" && grep -q "nolabs-ai/pi" "$fx/err"; then
    pass "$id"
  else
    fail "$id" "stderr missing warning: $(cat "$fx/err")"
  fi
}

# ==================================================================
# Case 21: provisioning summarizes and stops — it must not exec the
# harness, and arguments must come back as an exact re-run command.
# ==================================================================
case21() {
  local id="21: provisioning prints a summary, does not exec the harness"
  local fx wd home nh record rc
  fx="$(new_fixture)"
  wd="$fx/work"; home="$fx/home"; nh="$fx/nonohome"
  mkdir -p "$wd" "$home" "$nh"
  make_template "$nh/templates/default"
  record="$fx/record.bin"

  rc="$(run_nh "$wd" "$home" "$nh" "codex" "" /dev/null "$fx/out" "$fx/err" --max-turns 25 "hello world")"

  if [[ "$rc" != "0" ]]; then
    fail "$id" "expected exit 0, got $rc (stderr: $(cat "$fx/err"))"
    return
  fi
  if [[ -f "$record" ]]; then
    fail "$id" "harness was launched on the provisioning run (record file exists)"
    return
  fi
  if [[ ! -f "$wd/run_harness.sh" || ! -d "$wd/.sandbox" ]]; then
    fail "$id" "provisioning artifacts missing"
    return
  fi
  if grep -q "provisioned:" "$fx/err" \
      && grep -q "nono-here.sh" "$fx/err" \
      && grep -q -- "--max-turns" "$fx/err" \
      && grep -q "25" "$fx/err" \
      && grep -qF 'hello\ world' "$fx/err"; then
    pass "$id"
  else
    fail "$id" "summary missing or incomplete: $(cat "$fx/err")"
  fi
}

# ==================================================================
# Case 22: `nono profile schema` is exported to ~/.nono-here/ and the
# bundled template's profile.template.json references it via $schema.
# ==================================================================
case22() {
  local id="22: schema exported to ~/.nono-here/; bundled template references it via \$schema"
  local fx wd home nh record calls bin rc schema
  fx="$(new_fixture)"
  wd="$fx/work"; home="$fx/home"; nh="$fx/nonohome"; bin="$fx/bin"
  mkdir -p "$wd" "$home" "$nh" "$bin" "$nh/templates"
  # The bundled real template (so profile.template.json is present), not
  # the minimal make_template stub.
  cp -R "$DEFAULT_TEMPLATE_DIR" "$nh/templates/default"
  record="$fx/record.bin"; calls="$fx/nono_calls"
  write_schema_nono "$bin/nono" "$calls"

  local rc2=0
  (
    cd "$wd" &&
      env -u NONO_HERE_HOME -u NONO_HERE_HARNESS -u RUN_HARNESS_RECORD \
        -u XDG_CONFIG_HOME -u NONO_CONFIG -u NONO_PACKAGES \
        HOME="$home" NONO_HERE_HOME="$nh" NONO_HERE_HARNESS="codex" \
        RUN_HARNESS_RECORD="$record" PATH="$bin:$PATH" \
        "$NONO_HERE"
  ) </dev/null >"$fx/out" 2>"$fx/err" || rc2=$?
  rc="$rc2"

  if [[ "$rc" != "0" ]]; then
    fail "$id" "expected exit 0, got $rc (stderr: $(cat "$fx/err"))"
    return
  fi
  schema="$home/.nono-here/nono-profile.schema.json"
  if [[ ! -f "$schema" ]]; then
    fail "$id" "schema not exported to $schema (stderr: $(cat "$fx/err"))"
    return
  fi
  if grep -q 'profile schema --output' "$calls"; then
    : # exported through the documented subcommand
  else
    fail "$id" "expected 'nono profile schema --output ...', calls: $(cat "$calls")"
    return
  fi
  if grep -q '"\$schema": "~/.nono-here/nono-profile.schema.json"' "$wd/.sandbox/profile.template.json"; then
    pass "$id"
  else
    fail "$id" "profile.template.json missing the \$schema reference: $(cat "$wd/.sandbox/profile.template.json")"
  fi
}

# ==================================================================
# Case 23: a failing schema export warns but provisioning still completes
# (best-effort: editor convenience only, never fatal).
# ==================================================================
case23() {
  local id="23: failing schema export warns, provisioning completes"
  local fx wd home nh record calls bin rc
  fx="$(new_fixture)"
  wd="$fx/work"; home="$fx/home"; nh="$fx/nonohome"; bin="$fx/bin"
  mkdir -p "$wd" "$home" "$nh" "$bin"
  make_template "$nh/templates/default"
  record="$fx/record.bin"; calls="$fx/nono_calls"
  write_schema_nono "$bin/nono" "$calls" 3

  local rc2=0
  (
    cd "$wd" &&
      env -u NONO_HERE_HOME -u NONO_HERE_HARNESS -u RUN_HARNESS_RECORD \
        -u XDG_CONFIG_HOME -u NONO_CONFIG -u NONO_PACKAGES \
        HOME="$home" NONO_HERE_HOME="$nh" NONO_HERE_HARNESS="codex" \
        RUN_HARNESS_RECORD="$record" PATH="$bin:$PATH" \
        "$NONO_HERE"
  ) </dev/null >"$fx/out" 2>"$fx/err" || rc2=$?
  rc="$rc2"

  if [[ "$rc" != "0" ]]; then
    fail "$id" "expected exit 0, got $rc (stderr: $(cat "$fx/err"))"
    return
  fi
  if [[ ! -f "$wd/run_harness.sh" ]]; then
    fail "$id" "run_harness.sh not provisioned"
    return
  fi
  if grep -q "nono profile schema --output" "$fx/err" && ! grep -q "profile schema exported" "$fx/err" \
      && ! grep -q '^  schema:' "$fx/err"; then
    pass "$id"
  else
    fail "$id" "expected a schema-export warning without a success line: $(cat "$fx/err")"
  fi
}

# ==================================================================
# Case 24: a re-run after provisioning takes the silent fast path and
# forwards arguments — the summary's "Re-running $SELF now takes the
# fast path and launches the harness" promise.
# ==================================================================
case24() {
  local id="24: re-run after provisioning takes the fast path, args forwarded"
  local fx wd home nh record rc
  fx="$(new_fixture)"
  wd="$fx/work"; home="$fx/home"; nh="$fx/nonohome"
  mkdir -p "$wd" "$home" "$nh"
  make_template "$nh/templates/default"
  record="$fx/record.bin"

  rc="$(run_nh "$wd" "$home" "$nh" "codex" "" /dev/null "$fx/out" "$fx/err")"
  if [[ "$rc" != "0" ]]; then
    fail "$id" "provisioning run: expected exit 0, got $rc (stderr: $(cat "$fx/err"))"
    return
  fi
  if [[ -f "$record" ]]; then
    fail "$id" "harness was launched on the provisioning run (record file exists)"
    return
  fi

  rm -f "$fx/out" "$fx/err"
  rc="$(run_nh "$wd" "$home" "$nh" "" "$record" /dev/null "$fx/out" "$fx/err" --max-turns 25 "hello world")"
  if [[ "$rc" != "0" ]]; then
    fail "$id" "re-run: expected exit 0, got $rc (stderr: $(cat "$fx/err"))"
    return
  fi
  if [[ -s "$fx/err" ]]; then
    fail "$id" "fast-path re-run was not silent: $(cat "$fx/err")"
    return
  fi
  if [[ -f "$record" ]] && read_argv "$record" && argv_eq --max-turns 25 "hello world"; then
    pass "$id"
  else
    fail "$id" "re-run did not forward argv to the harness"
  fi
}

# ==================================================================
# Case 25: the provisioned profile's meta.name is substituted with the
# workdir's base name (unique per project) instead of the "NAME" placeholder.
# Exercises both bundled profile templates (25a/25b) and a base name full of
# sed/JSON special characters (25c: quote, ampersand, backslash, spaces) to
# lock in the escaping — the provisioned value must JSON-decode back to the
# directory's actual name.
# ==================================================================
case25_sub() {
  local label="$1" tmpl="$2" base="$3" expected_file_form="$4"
  local fx wd home nh record rc tpl
  fx="$(new_fixture)"
  wd="$fx/$base"; home="$fx/home"; nh="$fx/nonohome"
  mkdir -p "$wd" "$home" "$nh" "$nh/templates"
  cp -R "$tmpl" "$nh/templates/default"
  record="$fx/record.bin"

  rc="$(run_nh "$wd" "$home" "$nh" "codex" "$record" /dev/null "$fx/out" "$fx/err")"

  if [[ "$rc" != "0" ]]; then
    fail "$label" "expected exit 0, got $rc (stderr: $(cat "$fx/err"))"
    return
  fi
  tpl="$wd/.sandbox/profile.template.json"
  if [[ ! -f "$tpl" ]]; then
    fail "$label" "profile.template.json missing from .sandbox"
    return
  fi
  if grep -qF "\"name\": \"$expected_file_form\"" "$tpl" && ! grep -q '"name": "NAME"' "$tpl"; then
    pass "$label"
  else
    fail "$label" "meta.name not substituted to the expected file form: $(cat "$tpl")"
  fi
}

case25() {
  case25_sub "25a: bundled default template profile named after workdir" "$DEFAULT_TEMPLATE_DIR" work work
  case25_sub "25b: bundled claude template profile named after workdir" "$REPO_ROOT/templates/claude" work work
  # We"ird & na\me proj: the file must carry the JSON-encoded form
  # (\" for the quote, \\ for the backslash) so it decodes back to the name.
  case25_sub "25c: sed/JSON special chars in workdir name (\" & \\ spaces)" "$DEFAULT_TEMPLATE_DIR" 'we"ird & na\me proj' 'we\"ird & na\\me proj'
}

# ==================================================================
# Driver
# ==================================================================
main() {
  case01
  case02
  case03
  case04
  case05
  case06
  case07
  case08
  case09
  case10
  case11
  case12
  case13
  case14
  case15
  case16
  case17
  case18
  case19
  case20
  case21
  case22
  case23
  case24
  case25

  echo "----"
  echo "passed: $PASS_COUNT, failed: $FAIL_COUNT"
  if ((FAIL_COUNT > 0)); then
    exit 1
  fi
  exit 0
}

main
