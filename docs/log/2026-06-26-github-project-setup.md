# GitHub Project integration: docs + verifier (#59)

- **Date:** 2026-06-26
- **Issue / PR:** #59 / (this PR)
- **Type:** docs + feat

## What changed
- New read-only `scripts/orchestration/project-check.sh`: diagnoses the GitHub Projects status-sync config — confirms the board is reachable as the bot and its status field has the four option names the lanes emit (`In Progress`, `In Review`, `QA`, `Done`), reporting the specific problem otherwise. Exit 0 (not-configured / OK) | 1 (broken).
- `docs/SETUP.md` item 5 expanded from a one-liner into a full how-to; `orch-setup.md` checklist (step 5) + verify step (step 6) gained the Project steps and point at `project-check.sh`.
- Tests: `tests/orchestration/project-check.bats` (not-configured, access-fail, missing-option, all-good, duplicate-field).

## Why
`project_sync` has existed but Project setup was undocumented (SETUP.md had a single line), and it silently breaks in several non-obvious ways: the status field must have options named **exactly** what the lanes pass; issues must be **added as items** (sync edits an existing item, can't add one); the bot needs **Projects access**; the board must be owned by the **same org/user as the repo** (owner is derived from `repo`); and `load_config` requires `project.statusField` **even when `number` is null**. Each produced an opaque `project_sync` failure.

## Key decisions
- **Verify + document, do NOT auto-create the board.** Creating/configuring a Projects v2 board (`gh project create`, fields, options) is structural, needs Projects scope, and is consistent with how branch protection and the bot account are human setup steps. The deliverable is a verifier + docs; the issue's "verify it works on the Ganpan repo" is satisfied by the owner following the docs and running `project-check.sh`.
- **Four required option names mirrored from `project_sync`** with a comment marking this list as the single source to update if a lane status value changes.
- **Wire into the existing `orch-setup` setup command** + ship the directly-runnable script, rather than adding a new top-level `/ganpan:project-check` command + Codex skill (avoids command sprawl). Engine scripts are glob-installed, so no `install.sh` change.
- **`project-check.sh` exits 1 on misconfiguration** (a usable gate) but 0 on the valid not-configured state — it's a standalone diagnostic, not a lane-wrapped advisory, so the nonzero-on-broken contract is appropriate.

## Alternatives considered (not chosen)
- **Auto-create/auto-configure the board** — rejected: structural, scope-heavy, owner's action.
- **A standalone `/ganpan:project-check` command + `ganpan-project-check` Codex skill** — rejected: command sprawl; wiring into `orch-setup` + a runnable script covers the need.
- **Change `load_config` to make `statusField` optional when `number` is null** — rejected: out of scope (don't touch the engine contract); documented the requirement instead.
- **Auto-adding issues to the board** — rejected: documented GitHub's built-in auto-add workflow as a board setting.
