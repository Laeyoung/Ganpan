# Spec: GitHub Project integration — docs + verification command

- **Issue:** #59
- **Date:** 2026-06-26
- **Type:** docs + feat

## Problem

ganpan already syncs issue status to a GitHub Projects (v2) board: config has `project.{number,statusField}` and `lib.sh`'s `project_sync <issue#> <statusValue>` updates the board (no-op when `project.number` is `null`). But **there is no documented way to set the board up**, and the setup has several non-obvious requirements that silently break `project_sync` if missed:

- The board's status single-select field must have **options whose names exactly match the values the lanes pass**. Those values are: **`In Progress`**, **`In Review`**, **`QA`**, **`Done`** (from `work-issue`/`work-issue-deep` → `In Review`; `review-queue` → `In Progress`, `QA`; `qa-check` → `Done`). A missing option makes `project_sync` fail (`jq -er` finds no option).
- Issues must be **added to the board as items** (`project_sync` looks the item up by `content.number`); an issue that was never added has no item to edit.
- The bot PAT needs **Projects access** and the board must be reachable as `config.bot` (`gh project …` runs as the bot).
- `project.statusField` must name the actual field (default `Status`).

Today SETUP.md covers this in one line ("create it, set `project.number`"), so a user who enables `project.number` typically hits an opaque `project_sync` failure.

## Goal

Make Project integration **set-up-able and verifiable**:
1. A read-only `scripts/orchestration/project-check.sh` that diagnoses the current Project config and reports exactly what is wrong (or that it is unconfigured / OK).
2. Wire that check into the existing setup command (`orch-setup.md`) and expand its manual-steps checklist with the concrete Project setup steps.
3. Expand `docs/SETUP.md`'s Project section into a complete how-to (create board, add the Status field with the four required options, add issues as items, grant the bot access, set `project.number`/`statusField`, run the check).

## Design

### `project-check.sh` (read-only diagnostic)
Run from the target repo root; reads config via `load_config`. Behavior:
- `project.number` is `null` → print "not configured (status sync is a no-op)"; **exit 0** (informational — this is a valid state). Note: `load_config` still requires `project.statusField` to be present even when `number` is null (it reads it with `jq -er`), so the report should remind users to keep `statusField` in the config — see the constraint below.
- Else resolve `gh project view <number> --owner <owner>` (owner = `${REPO%%/*}` — the org/user that owns the repo). On failure → print that the project can't be accessed as `config.bot`, naming the likely causes: wrong `project.number`, the PAT lacks Projects access, **or the board is owned by a different org/user than the repo** (the owner is derived from `repo`, so a personal board for an org repo won't resolve); **exit 1**.
- Fetch `gh project field-list`; if the `statusField` field is absent → report it; **exit 1**. If **more than one** field has that name, warn (the jq `select(.name==…)` would pick ambiguously) and recommend the built-in `Status` field / unique names; **exit 1**.
- Check the field's options against the four **required** names (`In Progress`, `In Review`, `QA`, `Done`); list any missing; **exit 1** if any missing.
- All present → print an OK summary (project number, field, options found) plus a one-line reminder that issues must be added to the board as items for sync to take effect; **exit 0**.
- Diagnostics go to stdout (this is a human-facing report, not a captured return value — it is **not** `$()`-captured, like `bootstrap-labels.sh`); genuine `gh` errors may surface on stderr.

### Wiring
- `orch-setup.md`: the manual-steps checklist (step 5) gains the Project setup steps; the Verify step (step 6) mentions running `project-check.sh`.
- `docs/SETUP.md`: the one-line "(Optional) GitHub Project" item becomes a full subsection.

## Constraints

- **Never rename engine internals.** Do **not** change `project_sync` or `load_config`'s project handling — this PR documents and verifies the existing contract.
- The four required option names are the contract `project_sync` already depends on; the docs and `project-check.sh` must use them **verbatim** (`In Progress`, `In Review`, `QA`, `Done`). If a future change alters a lane's status value, both must move together — call this out in the script as the single source to update.
- `project-check.sh` is **read-only**: only `gh project view/field-list` (GET) and config reads. No `gh project create/item-add/item-edit`, no mutation.
- The gh test stub already emits queued responses for `project view`/`project field-list`/`project item-list` (`tests/orchestration/helpers/gh-stub.sh`) — reuse it; no new test infra. **Stub queue semantics (critical for the tests):** each successful `gh project view`/`field-list` READ consumes one queued slot in call order, so the all-good and missing-option cases each need **exactly two** `queue_response` calls (view, then field-list). A `gh project view` *failure* is simulated with `GH_FAIL_MATCH='project view'`, which exits before the queue block and so consumes **zero** slots — the access-fail test queues **nothing**. The not-configured case makes **no** `gh` call (queue nothing).
- `project.statusField` must be present in the config even when `project.number` is `null`: `load_config` reads it with `jq -er` and fails the whole load if absent. The shipped template already includes `"statusField": "Status"`; the docs must tell users not to delete it. (This PR does not change `load_config`.)
- **Out of scope / owner action:** *creating* the board and *enabling* it on the Ganpan repo is a human GitHub action (structural, needs a `gh`/UI step and Projects scope), consistent with how branch protection and the bot account are human setup steps. This PR ships the docs + verifier; the issue's "verify it works on the Ganpan repo" is satisfied operationally by the owner following the docs + running `project-check.sh`.
- `plugins/` artifacts change → bump `plugin.json` (feat → minor) against `main` at implementation time.
- CLAUDE.md workflow: Spec → Plan → implement; `docs/log/` entry.

## Acceptance criteria

1. `scripts/orchestration/project-check.sh` exists, is read-only, and implements the four-state behavior above (not-configured → exit 0; access fail → exit 1; field/option missing → exit 1 with the specific missing items; all-good → exit 0 with summary). It loads config via the shared lib and uses `owner = ${REPO%%/*}`.
2. `project-check.sh` checks for exactly the four required option names `In Progress`, `In Review`, `QA`, `Done`, and lists which are missing. It also detects a duplicate-named status field (more than one field named `statusField`) and warns. The access-failure message names the three likely causes (number, PAT access, board-owner mismatch).
3. `tests/orchestration/project-check.bats` covers, using a config fixture **with `project.number` set to a non-null integer** (the default fixtures use `null`, which would short-circuit every case at the null check):
   - not-configured (a `null`-number config) → exit 0; **no** `queue_response`, no `gh` call;
   - project-view failure (`export GH_FAIL_MATCH='project view'`) → exit 1; **no** `queue_response` (the failure short-circuits before the queue);
   - missing required option → exit 1 naming the missing option; **two** `queue_response` (view JSON with `.id`; field-list JSON whose Status field omits one option);
   - all-options-present → exit 0 with summary; **two** `queue_response` (view; field-list with all four options).
4. `orch-setup.md` manual-steps checklist includes the Project setup steps (create board; Status field with the four options; add issues as items; bot Projects access; set `project.number`/`statusField`), and its verify step references `project-check.sh`.
5. `docs/SETUP.md`'s Project item is expanded into a complete how-to covering: creating a Projects v2 board; the Status single-select field (the built-in `Status` field is recommended; field names must be unique) with the exact four required option names; adding issues to the board as items via GitHub's built-in **auto-add workflow** (the recommended way; manual add also works); granting the bot Projects access; that the board owner must be the same org/user as the repo; keeping `project.statusField` in the config even when `number` is null; and running `project-check.sh` to verify.
6. Full suite green (`bats tests/*.bats tests/orchestration/*.bats`); `shellcheck` clean (incl. the new script); JSON manifests valid.
7. `plugin.json` bumped (feat → minor) against `main` at implementation time.
8. A `docs/log/` entry records the verify-and-document (not auto-create) decision, the four-option contract, and rejected alternatives.

## Non-goals

- Auto-creating or auto-configuring the Projects board (`gh project create`/field/option creation) — owner action; verify + document instead.
- Changing `project_sync`, `load_config`, or the status values the lanes emit.
- A standalone `/ganpan:project-check` top-level command + Codex skill — the verification is delivered as a script wired into the existing `orch-setup` setup command (avoids command sprawl); the script is also directly runnable (`scripts/orchestration/project-check.sh`).
- Auto-adding issues to the board (the GitHub "auto-add" workflow is documented as a manual board setting).
