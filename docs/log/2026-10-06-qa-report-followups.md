# 2026-10-06 full-test-report follow-ups: dogfood refresh, validate dual-config warn, lint scope

- **Date:** 2026-10-06
- **Issue / PR:** — / (this PR)
- **Type:** feat (+ fix, docs, ci)
- **Version:** 1.16.1 → 1.17.0 (`install.sh --self` is a new flag → minor)

## What changed
Fixes every finding in `docs/qa/2026-10-06-full-test-report.md`:
- **F1 — `install.sh --self`:** the toolkit source still refuses itself as a target, but
  the error now names `--self`. With the flag (and only when target == source), install.sh
  refreshes **only** the version-stamped engine payload: `scripts/orchestration/`,
  `references/lanes/`, and `.claude/commands/` for claude targets. It skips config, assets,
  `docs/SETUP.md`, `CLAUDE.md`/`AGENTS.md`, and `.agents/skills`. `--self` against any other
  target is refused. This repo's dogfood copy was refreshed from v1.15.1 to v1.17.0 with it,
  and `RELEASE_PLAYBOOK.md` §7 now lists the refresh as a post-release step.
- **F2:** `install.sh` is added to the shellcheck command in CI, `CLAUDE.md`,
  `RELEASE_PLAYBOOK.md`, and `RELEASE_CHECKLIST.md`.
- **F3 — `ganpan validate`:** when `$ORCH_CONFIG` is unset and both `.ganpan/` and `.claude/`
  configs exist with different bytes, validate prints
  `warn both … exist and differ; using .ganpan` (exit code unchanged). This matches install.sh.
- **F4 — `update-info.sh`:** the copy-in install.sh hint printed `./install.sh . --target both`.
  It now prints the detected repo root and a `<codex|claude|antigravity|both|all>` placeholder:
  `./install.sh "<root>" --target <…> --force   # run from a ganpan checkout`.
  `docs/SETUP.md` is worded to match.
- **F5:** `marketplace.json` gains `metadata.description`, so `claude plugin validate .` no
  longer warns.
- **F6:** the "Current release readiness" section of `RELEASE_PLAYBOOK.md` no longer contains
  the stale `204/204` count. It now tells the reader to re-run the §3 gate for each release.
- **I1:** `queue_response` in the test helper counts responses with a glob instead of
  `ls | grep` (SC2010). The payload is saved before `set --` reuses the positional args.

## Why
The lanes that work on this repo's own issues (with `reviewer.autoMerge: true`) ran a v1.15.1
engine, and there was no supported way to upgrade it. The other findings were consistency gaps
or misleading output found by the full test run.

## Key decisions
- **F1 uses report option 1 (an explicit flag).** The self-refusal stays the default, so a
  mistyped target still fails loudly. The flag also reuses install.sh's tested
  copy/stamp/needs_write logic instead of adding a wrapper.
- **Self mode copies only the engine payload.** This checkout's `CLAUDE.md`/`AGENTS.md` are
  tracked dev docs with no conventions sentinel, so a normal install would append the
  user-facing conventions block to them. A root `.agents/skills/` would shadow the six real
  skills under `npx skills` discovery (see CLAUDE.md gotcha). The repo's config and `.github/`
  assets are already maintained by hand.
- **`bin/ganpan.mjs init` still refuses a checkout.** It does not forward `--self`, because npx
  users never need it.
- **F4 shows a placeholder, not a guessed target.** The 2026-06-26 update-command spec put a
  per-repo `--target` heuristic out of scope. A placeholder keeps that decision and stops
  suggesting the wrong `both`.
- **F3 compares bytes**, as install.sh's `cmp -s` does. A file that cannot be read skips the
  warning, and the main config read reports the error.

## Alternatives considered (not chosen)
- **`scripts/dogfood-sync.sh` wrapper (report option 2):** it needs another `.gitignore`
  exception and a temp-dir round-trip, and it would duplicate install.sh's file selection.
- **Docs-only manual procedure (option 3):** hand-copying files is the drift that caused F1.
- **Keeping `--target both` in the update hint:** wrong for codex-only, claude-only, and
  antigravity installs.
