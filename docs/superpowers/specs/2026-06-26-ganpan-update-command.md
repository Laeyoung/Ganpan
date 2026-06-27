# Spec: Interactive `/ganpan:update` command (advisory)

- **Issue:** #55 (follow-up to #49 / PR #53)
- **Date:** 2026-06-26
- **Type:** feat

## Problem

#49 asked for both a version **check** and an **update** capability. PR #53 shipped only the throttled, non-interactive check (`version-check.sh`) — interactive update was deferred because prompting inside an unattended `/loop` is unsafe. #55 adds the user-invoked half: a `/ganpan:update` command (run by a human, never in a loop, so it may be interactive) that tells the user how their install is updated.

The update **mechanism** differs by install mode and an agent cannot perform it programmatically in plugin mode:
- **plugin** install → updated through Claude Code's `/plugin` marketplace UI (an interactive built-in; not agent-scriptable).
- **copy-in** install → updated by re-running `install.sh <target> --force`.

## Owner design decision (resolved)

Issue #55 originally described a user-confirmation-then-**perform** flow. The owner overrode that to **advisory-only** (asked 2026-06-26) because an agent performing the update in plugin mode is not programmatically possible (`/plugin` is an interactive built-in), and performing it in copy-in mode risks unintended environment mutation. So `/ganpan:update` detects the install mode, shows installed vs latest version, and **prints the exact steps for the user to run**. It **never modifies the repo** and never runs the plugin manager. This is uniform across both modes and carries no risk of an agent mutating a user's environment.

## Goals

1. Add a `scripts/orchestration/update-info.sh` engine script (testable) that emits a structured, advisory report: install mode, installed version, latest version, an up-to-date/update-available/unknown status, and the exact per-mode update command(s). Read-only; exit 0 always (an advisory must never hard-fail).
2. Reuse `version-check.sh` for the latest-version lookup, invoked with `VERSION_CHECK_INTERVAL_DAYS=0` **and a disposable `GANPAN_STATE_DIR`** (e.g. `GANPAN_STATE_DIR="$(mktemp -d)"`) so an explicit user request always does a **fresh** check (never `skip`) **without clobbering the lanes' shared throttle stamp** — `version-check.sh` writes `now` to `$GANPAN_STATE_DIR/version-check.epoch` on every non-throttled run, so the advisory must point it at a throwaway dir or it would suppress the lanes' next notice for days.
3. Add the Claude command `commands/update.md` (`/ganpan:update`) that runs the script and presents its advisory output; explicitly advisory (no repo mutation).
4. Add a Codex skill `ganpan-update` (parity) that calls the same script. It follows the existing skill structure: `skills/ganpan-update/SKILL.md` (frontmatter + advisory instructions) and `skills/ganpan-update/agents/openai.yaml` (mirroring a sibling skill, pointing the agent at `scripts/orchestration/update-info.sh`). `install.sh` already copies Codex skills via a `find … -type f` glob, so the new skill dir is picked up automatically — **no install.sh change needed for Codex**.
5. **Wire the new command into copy-in installs:** `install.sh` copies lane commands from a **hardcoded list** (`for name in work-issue work-issue-deep triage review-queue qa-check run-all`). Add `update` to that list and to its `info` line so copy-in users get `.claude/commands/update.md`.
6. Document `/ganpan:update` in `docs/SETUP.md` (and the shipped `assets/CLAUDE.md` if it enumerates commands).
7. Tests: `tests/orchestration/update-info.bats` covering mode detection, the three version states, and the per-mode guidance text. If `tests/install.bats` asserts the command set, update it to include `update`.

## Install-mode detection (design)

`update-info.sh` decides mode from the target repo's working directory (`cwd`):
- **copy-in** when `./scripts/orchestration/lib.sh` in `cwd` contains the `ganpan-orchestration:` **sentinel line** (install.sh stamps every copied engine file). Detecting the sentinel — not mere file existence — avoids a false positive for an unrelated repo that happens to have a `scripts/orchestration/` directory. Installed version = the `vX` parsed from that sentinel line.
- **plugin** otherwise. Installed version is resolved in this order: (1) an explicit `$GANPAN_PLUGIN_MANIFEST` path if set — a test/override hook, mirroring `version-check.sh`'s existing `GANPAN_*` env overrides; (2) **script-relative** `$SCRIPT_DIR/../../.claude-plugin/plugin.json` (`update-info.sh` lives at `<plugin-root>/scripts/orchestration/update-info.sh`, manifest at `<plugin-root>/.claude-plugin/plugin.json`); (3) `$CLAUDE_PLUGIN_ROOT/.claude-plugin/plugin.json`. If none resolves, installed version is `unknown` and the script still prints latest + the `/plugin` guidance. (Script-relative is preferred over `$CLAUDE_PLUGIN_ROOT` because it survives a var-unset invocation; `lib.sh` already exports `SCRIPT_DIR`. The `GANPAN_PLUGIN_MANIFEST` hook exists because in bats `$SCRIPT_DIR` resolves to the real source tree, so the override is how the test exercises plugin-mode resolution without touching the source.)

Per-mode guidance text:
- copy-in → `Run:  ./install.sh <repo> --target both --force`  (uses the repo path / `.`).
- plugin → `Run /plugin, then update "ganpan@laeyoung" from the marketplace manager.`

## Constraints

- **Never rename engine internals** (`scripts/orchestration/`, `orchestration.json`, the `ganpan-orchestration` sentinel).
- `update-info.sh` is **read-only**: it must not write, fetch-and-apply, or call any mutating `gh`/`git`/`install.sh`. It only reads local files and (via `version-check.sh`) does one read-only `gh api` GET.
- **Keep stdout clean for the return value** (CLAUDE.md Gotchas): `update-info.sh`'s stdout is its advisory payload; it makes no mutating `gh` calls, so there is no write-URL leak vector, but diagnostics still go to stderr via `log`.
- Latest-version lookup must not hammer the API: it is a single GET per invocation (the command is human-invoked, not looped); `VERSION_CHECK_INTERVAL_DAYS=0` only disables the *throttle stamp short-circuit*, it does not add calls.
- `version-check.sh` is on `main` and **must not be modified** by this PR (reused as-is via env var).
- `assets/CLAUDE.md` is shipped to users — editing it changes deploy output.
- Shipped artifacts under `plugins/` change → bump `plugins/orchestration/.claude-plugin/plugin.json` (feat → minor) against the version on `main` **at implementation time** (currently `1.9.0`; re-check before bumping since concurrent PRs move it).

## Non-goals

- **Performing** the update (running `install.sh --force` or the plugin manager) — explicitly excluded by the owner's advisory-only decision.
- Changing `version-check.sh` or the lanes' check-notice behavior.
- Auto-detecting/упgrading across modes beyond the two documented paths.
- A `--target codex`-only vs `both` heuristic for the copy-in command — the guidance prints the general `--target both` form with a note; refining per-repo is out of scope.

## Acceptance criteria

1. `scripts/orchestration/update-info.sh` exists, is read-only, exits 0 in all paths, and prints an advisory containing: detected mode (`copy-in`|`plugin`), installed version (or `unknown`), latest version (or `unknown`), a status line, and the exact per-mode update step(s).
2. In **copy-in** mode (a `cwd` whose `./scripts/orchestration/lib.sh` carries the `ganpan-orchestration:` sentinel), the script reports `mode: copy-in`, the sentinel version as installed, and the `install.sh … --force` guidance.
3. In **plugin** mode (no sentinel-stamped local `lib.sh`), it reports `mode: plugin`, the installed version resolved via `$GANPAN_PLUGIN_MANIFEST` → script-relative `$SCRIPT_DIR/../../.claude-plugin/plugin.json` → `$CLAUDE_PLUGIN_ROOT` → `unknown`, and the `/plugin` guidance.
4. Latest-version lookup uses `version-check.sh` with `VERSION_CHECK_INTERVAL_DAYS=0` and a **disposable `GANPAN_STATE_DIR`** so the lanes' real throttle stamp is untouched; `update-available: a -> b` maps to an "update available" status, `current` to "up to date", `unknown` to "could not determine latest" — and the script never prints `skip`.
5. `commands/update.md` (`/ganpan:update`) invokes the script and presents its output, stating it is advisory (the user runs the printed steps). A Codex `ganpan-update` skill (`SKILL.md` + `agents/openai.yaml`, mirroring a sibling skill) calls the same script.
6. `install.sh` ships the new command to copy-in installs: `update` added to the lane-command name list (and its `info` line). `tests/install.bats`, if it asserts the command set, is updated to include `update`.
7. `tests/orchestration/update-info.bats` covers: copy-in detection + version + guidance; plugin detection + version + guidance; the three latest-version states; installed-version-unknown fallback. Its `setup()` exports `VERSION_CHECK_INTERVAL_DAYS=0` and an isolated `GANPAN_STATE_DIR="$BATS_TEST_TMPDIR/state"`, calls `queue_response` before any case that reaches `version-check.sh`'s `gh api` GET (mirroring `version-check.bats`), builds the copy-in fixture by writing a `scripts/orchestration/lib.sh` containing the sentinel line, and the plugin fixture by writing a `.claude-plugin/plugin.json` (with a `version`) in a tmpdir and pointing `GANPAN_PLUGIN_MANIFEST` at it (since in bats `$SCRIPT_DIR` resolves to the real source tree, the override is how the plugin-resolution branch is exercised without touching the source). Full suite green; `shellcheck` clean; JSON manifests valid.
8. `plugin.json` bumped (feat → minor) against `main` at implementation time.
9. A `docs/log/` entry records the advisory-only decision (owner-chosen, overriding the issue's perform-update), the sentinel-based mode detection, the disposable-state-dir fix, the script-relative version resolution, and rejected alternatives.
