# Throttled, loop-safe ganpan version-check notice (#49)

- **Date:** 2026-06-25
- **Issue / PR:** #49 / (this PR)
- **Type:** feat

## What changed
Added `scripts/orchestration/version-check.sh <installed-version>` — a throttled, read-only check that compares the installed plugin version against the latest on the source repo's `main` and prints one of `skip` / `current` / `update-available: <installed> -> <latest>` / `unknown`. The work-issue command surfaces an `update-available` result as a **one-line notice** during setup and continues.

## Why
Issue #49: periodically (every ~3–4 days) check for a newer ganpan and let the user update. The issue itself flags the key constraint: **asking the user mid-`/loop` breaks the loop**, so a check must not prompt during loop runs.

## Key decisions
- **Non-interactive by design — never prompt.** The script only prints; lanes echo the notice and continue. This is *the* resolution to the "don't break the loop" constraint and is strictly safer than trying to detect "first invocation vs loop tick" (which the lane has no reliable signal for). The interactive *decision* to update stays with the user.
- **Throttled via a per-user stamp** (`GANPAN_STATE_DIR`, default `~/.local/state/ganpan`; interval `VERSION_CHECK_INTERVAL_DAYS`, default 3). The attempt is stamped *before* branching on the result, so a transient offline blip cannot turn into per-tick API hammering inside a loop.
- **Never flags a downgrade** — `sort -V` ensures `update-available` only when the remote is strictly newer (a local dev checkout ahead of the published release reports `current`).
- **Always exit 0** — a version check must never fail a lane; offline/API errors report `unknown`.
- **Latest fetched via `gh api` raw** of `plugins/orchestration/.claude-plugin/plugin.json@main` on `GANPAN_SOURCE_REPO` (default `Laeyoung/Ganpan`) — reuses the authenticated `gh` already required, no new dependency.

## Deferred (flagged for human design in the PR)
- **Performing the update automatically on approval.** A Claude Code marketplace plugin update is a `/plugin`-manager / settings action the agent cannot safely perform programmatically; the notice points the user to their plugin manager (or re-running `install.sh` for copy-in). A future `/ganpan:update` *user-invoked* command (where prompting is safe, since it is not a loop) could ask + run `install.sh` for copy-in installs.
- **Notice on the Codex surface** — wired into the Claude `work-issue` command only (plugin mode has `plugin.json` for the installed version); the script ships everywhere via the install glob.

## Verification
- `tests/orchestration/version-check.bats` — 7 cases (update-available + stamps, current, downgrade→current, throttle skip without a network call, stale-stamp re-check, offline→unknown, minor-bump detection).
- Full suite (170) green; shellcheck clean; manifests valid; install smoke copies `version-check.sh +x`. feat → minor bump 1.6.0 → 1.7.0.
