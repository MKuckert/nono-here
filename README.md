# nono-here

Zero-config bootstrap for running AI agent harnesses (Claude, opencode, codex,
copilot, pi, ...) inside a [`nono`](https://nono.sh) sandbox.

Drop `nono-here.sh` on your `PATH` (keeping its sibling `templates/`
directory next to it, or overriding via `~/.nono-here/templates/`), run it
from any project, and it provisions a `.sandbox/` directory plus a
`run_harness.sh` entry point — then hands over to the harness. Every subsequent run in that project takes
a silent fast path straight to the harness.

## Usage

```sh
cd /path/to/project
nono-here.sh [args passed through to the harness]
```

**First run (provisioning):** no `run_harness.sh` in the workspace yet.
- Pick a harness: interactively (via `select`, requires a TTY) or
  non-interactively via `NONO_HERE_HARNESS=<harness>`.
- Resolve a template (see [Template resolution](#template-resolution)).
- Validate the template.
- Check that the harness's official `nolabs-ai` profile pack is installed
  in the local nono pack store; if missing, run `nono pull <pack>`
  (e.g. `nono pull nolabs-ai/codex`). Skipped with a warning when `nono`
  is not on the PATH; a failed pull aborts with exit 11. The pack store
  is `$NONO_PACKAGES`, else `$NONO_CONFIG/packages`, else
  `${XDG_CONFIG_HOME:-~/.config}/nono/packages`.
- Create `.sandbox/`, copy the template into it, substitute the chosen
  harness into `.sandbox/defaults.sh`, move `run_harness.sh` into the
  workspace root.
- Hand over to `./run_harness.sh "$@"`.

**Subsequent runs (fast path):** `run_harness.sh` already exists and is
executable, `.sandbox/start.sh` is executable → hands over immediately,
silently.

The workspace is the Git root (`git rev-parse --show-toplevel`) if inside a
repo, otherwise `$PWD`.

## When it earns its keep

### Long sandboxed invocations collapse to one word

Without nono-here, every run spells out the full sandbox:

```sh
nono wrap --profile .sandbox/profile.json --workdir "$PWD" --allow-cwd -- \
  claude --allowed-tools "Grep Glob" --model sonnet --max-turns 25
```

After provisioning, the same run is:

```sh
nono-here.sh --max-turns 25
```

(`run_harness.sh` is what `nono-here.sh` hands over to; you never need
to call it yourself.)

The harness command and its repeated flags live in
`.sandbox/defaults.sh` (copied once at provisioning, then yours to edit);
the profile path and workdir are handled by `start.sh`:

```sh
SANDBOX_COMMAND="claude"
SANDBOX_COMMAND_DEFAULTS=(--allowed-tools "Grep Glob" --model sonnet)
```

`run_harness.sh` prepends `SANDBOX_COMMAND_DEFAULTS` whenever you pass no
arguments or start with a flag, so a bare `nono-here.sh` runs the full
default invocation — and the fast path is silent, so it stays out of the
way in a daily workflow.

### Sharing a sandboxed setup with your team

Commit `run_harness.sh` and `.sandbox/` to the project. The template's
`.gitignore` excludes only the local `profile.json`, so the shared parts —
`profile.template.json`, `hooks/`, `start.sh`, `defaults.sh` — travel with
the source. A teammate who has installed [nono](https://nono.sh) clones the
repo and runs `./run_harness.sh` (or `nono-here.sh`, if it is on their
PATH — the fast path takes over); no provisioning needed. On first
start, `start.sh` copies `profile.template.json` to `profile.json` (with a
"check and adjust" notice), so each person keeps local overrides private
while the team shares one baseline.

### Per-project profiles, tuned per project

Each project gets its own `.sandbox/profile.template.json` — network
domains, filesystem rules, and allowed environment variables scoped to
what that project actually needs. Local tweaks go in the git-ignored
`profile.json`; bump `meta.version` in the template to get a diff prompt
whenever the shared baseline changes (version comparison requires `jq`;
without it you get a plain "differs from template" notice).

### Scripted and non-interactive provisioning

```sh
NONO_HERE_HARNESS=pi nono-here.sh   # no TTY required; args pass through
```

Useful in CI, remote shells, and dotfiles bootstrap scripts where the
interactive `select` prompt is unavailable.

## Template resolution

The first existing directory wins, checked in this order:

1. `~/.nono-here/templates/<harness>` — user override, harness-specific
2. `~/.nono-here/templates/default` — user override, default
3. `$NONO_HERE_HOME/templates/<harness>` — bundled, harness-specific
4. `$NONO_HERE_HOME/templates/default` — bundled, default

`NONO_HERE_HOME` defaults to `nono-here.sh`'s own resolved directory
(symlinks followed), so the script works regardless of where it's
symlinked from. `templates/claude` and `templates/default` ship in this
repo.

A template directory must contain:

- `run_harness.sh` — executable
- `start.sh` — executable
- `defaults.sh` — must contain the `__NONO_HERE_SANDBOX_COMMAND__`
  placeholder, substituted with the selected harness at provisioning time

`defaults.sh` is copied once, then never touched again by `nono-here.sh` —
edit it freely afterward (e.g. to set `SANDBOX_COMMAND_DEFAULTS`).

## Adding a harness

Add the name to the `HARNESSES` array at the top of `nono-here.sh`. If the
harness has an official `nolabs-ai` registry pack, add a matching case
branch to `nono_pack_for()` so provisioning checks for and pulls it; without
a branch the profile check is skipped with a notice. Add a matching
`templates/<harness>/` directory if it needs a non-default template;
otherwise it falls back to `templates/default`.

## Exit codes

| Code | Meaning |
| --- | --- |
| 1 | Unexpected internal failure (e.g. symlink cycle resolving the script's own path) |
| 2 | `run_harness.sh` exists but is not executable |
| 3 | `.sandbox/start.sh` missing or not executable (fast path) |
| 4 | No TTY for interactive harness selection and `NONO_HERE_HARNESS` unset |
| 5 | No template directory found in any of the four probed locations |
| 6 | Stale/incomplete `.sandbox` left in place (no TTY to confirm, or user declined re-creation) |
| 7 | Template invalid (missing/non-executable required file, missing placeholder, or copy lost permissions) |
| 8 | Invalid `NONO_HERE_HARNESS` value |
| 9 | A path that must be a regular file/directory is something else (e.g. `.sandbox` is not a directory) |
| 10 | Interactive harness selection aborted (input closed) |
| 11 | `nono pull` of the harness's profile pack failed |

## Testing

```sh
./test_nono_here.sh
```

Plain-Bash test harness — no `bats`, `jq`, or `rsync` required. Each case
runs in its own `mktemp -d` fixture with `HOME` and `NONO_HERE_HOME`
overridden, so the real `$HOME` is never touched.

## Layout

```
nono-here.sh              # the entry point
templates/
  default/                 # fallback template for any harness:
                           # run_harness.sh, start.sh, defaults.sh,
                           # profile.template.json, hooks/, .gitignore
  claude/                  # claude-specific template (same layout)
test_nono_here.sh          # test suite
```
