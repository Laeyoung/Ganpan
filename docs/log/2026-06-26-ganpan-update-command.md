# Interactive `/ganpan:update` advisory command (#55)

- **Date:** 2026-06-26
- **Issue / PR:** #55 / PR #60
- **Type:** feat

> **Rework (2026-06-26):** rebased onto `main` (advanced to `1.10.1`); resolved `plugin.json` → **`1.11.0`** (feat) and merged the install command-list / `install.bats` additions with the concurrently-landed `review-queue-deep` command (kept both `update` and `review-queue-deep`). Full suite green (193 tests).

## What changed
- New read-only engine script `scripts/orchestration/update-info.sh`: detects install mode (copy-in vs plugin), resolves installed vs latest version, and prints the exact per-mode update steps. Exit 0 always.
- New Claude command `/ganpan:update` (`commands/update.md`) and Codex skill `ganpan-update` that present the advisory; both stress it is advisory (the user runs the printed step).
- `install.sh` ships `update.md` to copy-in installs (added to the hardcoded command list); the Codex skill is auto-picked-up by the existing `find` glob.
- Docs: `docs/SETUP.md` "Checking for updates". Tests: `tests/orchestration/update-info.bats` (+ skill-list additions in `install.bats`/`codex-skills.bats`).

## Why
#49/PR #53 shipped only the throttled version **check**; the **update** half was deferred (prompting inside an unattended `/loop` is unsafe). #55 adds the user-invoked, prompt-safe half.

## Owner decision
The owner chose **advisory-only**, overriding the issue's original "user-confirmation-then-perform" flow: an agent cannot perform a plugin-mode update (`/plugin` is an interactive built-in) and performing a copy-in update risks unintended environment mutation. So the command only reports and instructs — it never mutates the repo.

## Key decisions
- **Reuse `version-check.sh`** for the latest lookup (no API-call duplication), invoked with a **disposable `GANPAN_STATE_DIR`** (mktemp) + `VERSION_CHECK_INTERVAL_DAYS=0` so the explicit check is fresh *and* never clobbers the lanes' shared throttle stamp (which would otherwise silence their update notice for days).
- **Sentinel-based mode detection**, walking **up** from cwd to find a `scripts/orchestration/lib.sh` carrying the `ganpan-orchestration:` sentinel — robust to running the command from any subdirectory, and avoids the false positive of mere `scripts/orchestration/` existence.
- **Script-relative plugin-manifest resolution** (`$DIR/../../.claude-plugin/plugin.json`) with a `GANPAN_PLUGIN_MANIFEST` test hook; **dropped the `$CLAUDE_PLUGIN_ROOT` branch** — it was redundant with script-relative resolution AND the install path-drift guard forbids a `${CLAUDE_PLUGIN_ROOT}/` path token in copied engine scripts.
- **`probe=0.0.0` when installed is unknown** so `version-check.sh` still yields the latest version to display; guarded the `current` branch so an unknown-installed never prints a contradictory "up to date".

## Alternatives considered (not chosen)
- **Performing the update** (run `install.sh --force` / `/plugin`) — rejected: owner's advisory-only override (agent-mutation risk; plugin path not scriptable).
- **Inlining the `gh api` latest lookup** in `update-info.sh` — rejected: duplicates `version-check.sh`'s logic; reuse with an isolated state dir is cleaner.
- **Filename-existence mode detection** — rejected: false positives for unrelated `scripts/orchestration/` dirs; sentinel grep is unambiguous.
- **cwd-relative (root-only) detection** — rejected: a user-invoked command may run from a subdirectory; the upward walk handles that.
- **`$CLAUDE_PLUGIN_ROOT`-based version** — rejected: redundant with script-relative and trips the path-drift guard.
