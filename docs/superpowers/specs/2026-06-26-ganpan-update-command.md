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

The owner chose **advisory-only** (asked 2026-06-26): `/ganpan:update` detects the install mode, shows installed vs latest version, and **prints the exact steps for the user to run**. It **never modifies the repo** and never runs the plugin manager. This is uniform across both modes and carries no risk of an agent mutating a user's environment.

## Goals

1. Add a `scripts/orchestration/update-info.sh` engine script (testable) that emits a structured, advisory report: install mode, installed version, latest version, an up-to-date/update-available/unknown status, and the exact per-mode update command(s). Read-only; exit 0 always (an advisory must never hard-fail).
2. Reuse `version-check.sh` for the latest-version lookup, invoked with `VERSION_CHECK_INTERVAL_DAYS=0` so an explicit user request always does a **fresh** check (never returns `skip`).
3. Add the Claude command `commands/update.md` (`/ganpan:update`) that runs the script and presents its advisory output; explicitly advisory (no repo mutation).
4. Add a Codex skill `ganpan-update` (parity) that calls the same script.
5. Document `/ganpan:update` in `docs/SETUP.md` (and the shipped `assets/CLAUDE.md` lane list if it enumerates commands).
6. Tests: `tests/orchestration/update-info.bats` covering mode detection, the three version states, and that the right guidance text is emitted per mode.

## Install-mode detection (design)

`update-info.sh` decides mode from the target repo's working directory (`cwd`):
- **copy-in** when `./scripts/orchestration/version-check.sh` exists in `cwd` (install.sh copied the engine into the repo). Installed version = the `ganpan-orchestration: v<X>` sentinel stamped into an installed file (`./scripts/orchestration/lib.sh`); the script parses `vX` from that line.
- **plugin** otherwise. Installed version = `.version` of the plugin manifest at `$CLAUDE_PLUGIN_ROOT/.claude-plugin/plugin.json` when `$CLAUDE_PLUGIN_ROOT` is set; if it cannot be determined, the script reports the installed version as `unknown` and still prints latest + generic guidance.

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
2. In **copy-in** mode (a `cwd` with `./scripts/orchestration/version-check.sh` and a sentinel-stamped `lib.sh`), the script reports `mode: copy-in`, the sentinel version as installed, and the `install.sh … --force` guidance.
3. In **plugin** mode (no local `./scripts/orchestration/`, `$CLAUDE_PLUGIN_ROOT` pointing at a manifest), it reports `mode: plugin`, the manifest version as installed, and the `/plugin` guidance.
4. Latest-version lookup uses `version-check.sh` with `VERSION_CHECK_INTERVAL_DAYS=0`; an `update-available: a -> b` maps to an "update available" status, `current` to "up to date", `unknown` to "could not determine latest" — and the script never prints `skip`.
5. `commands/update.md` (`/ganpan:update`) invokes the script and presents its output, stating it is advisory (the user runs the printed steps). A Codex `ganpan-update` skill calls the same script.
6. `tests/orchestration/update-info.bats` covers: copy-in detection + version + guidance; plugin detection + version + guidance; the three latest-version states (via a `gh`/`version-check` stub); installed-version-unknown fallback. Full suite green; `shellcheck` clean; JSON manifests valid.
7. `plugin.json` bumped (feat → minor) against `main` at implementation time.
8. A `docs/log/` entry records the advisory-only decision (owner-chosen), the mode-detection design, and rejected alternatives.
