# GitHub Project Integration: docs + verification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make GitHub Projects status-sync set-up-able: a read-only `project-check.sh` verifier + full SETUP/orch-setup docs, without changing the existing `project_sync` contract.

**Architecture:** New read-only engine script `project-check.sh` (loads config, probes the board via `gh project view`/`field-list`, checks the four required Status options). Docs in `docs/SETUP.md` + `orch-setup.md` explain board creation and point at the verifier. Engine scripts are glob-installed, so no `install.sh` change.

**Tech Stack:** Bash, `jq`, `gh` (read-only project GETs), `bats`, `shellcheck`.

## Global Constraints

- Never rename engine internals; do NOT change `project_sync` or `load_config`.
- The four required Status option names — `In Progress`, `In Review`, `QA`, `Done` — are the values the lanes pass to `project_sync`; use them verbatim in the script and docs. They are the single contract to update if a lane's status value ever changes.
- `project-check.sh` is read-only: only `gh project view`/`field-list` (GET) + config reads. No mutation.
- Report lines go to **stdout** (human-facing diagnostic, like `bootstrap-labels.sh`); suppress `gh`'s own stderr with `2>/dev/null`.
- Exit 0 when not-configured (number null) or fully valid; exit 1 when configured but broken.
- `load_config` requires `project.statusField` even when `number` is null — docs must tell users to keep it.
- Bump `plugin.json` (feat → minor) from current `main` (baseline `1.9.0`; re-check before bumping).
- Work in worktree `wt-issue-59` on branch `issue-59`; tests from repo root.

---

### Task 1: `project-check.sh` verifier (TDD)

**Files:**
- Create: `plugins/orchestration/scripts/orchestration/project-check.sh`
- Test: `tests/orchestration/project-check.bats`

**Interfaces:**
- Produces: a script printing a `ganpan project-check: …` report; exit 0 (not-configured / OK) or 1 (broken).
- Consumes: `lib.sh` (`load_config`, `$PROJECT_NUMBER`, `$PROJECT_STATUS_FIELD`, `$REPO`, `$BOT`); `gh project view`/`field-list`.

- [ ] **Step 1: Write the failing tests**

Create `tests/orchestration/project-check.bats`:

```bash
#!/usr/bin/env bats

# project-check.sh — read-only diagnostic for GitHub Projects status-sync config.

setup() {
  load helpers/common
  setup_gh_stub
  SCRIPT="$BATS_TEST_DIRNAME/../../plugins/orchestration/scripts/orchestration/project-check.sh"
  export GH_STUB_LOGIN=botx                    # actor gate not used here, but keep parity
  export ORCH_CONFIG="$BATS_TEST_TMPDIR/orchestration.json"
}

# config with project.number SET (non-null) so checks run past the null short-circuit.
cfg_with_number() {
  cat > "$ORCH_CONFIG" <<'JSON'
{ "repo":"o/r","bot":"botx","candidateN":3,"wipLimit":4,
  "reclaim":{"timeoutMinutes":120,"heartbeatMinutes":15},
  "commands":{"test":null,"build":null,"lint":null},
  "worktreeBaseDir":"../","project":{"number":1,"statusField":"Status"} }
JSON
}

# config with project.number null (sync disabled).
cfg_null() {
  cat > "$ORCH_CONFIG" <<'JSON'
{ "repo":"o/r","bot":"botx","candidateN":3,"wipLimit":4,
  "reclaim":{"timeoutMinutes":120,"heartbeatMinutes":15},
  "commands":{"test":null,"build":null,"lint":null},
  "worktreeBaseDir":"../","project":{"number":null,"statusField":"Status"} }
JSON
}

@test "not configured (number null) → exit 0, no gh call" {
  cfg_null
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no-op"* ]]
}

@test "project view fails → exit 1 (access guidance)" {
  cfg_with_number
  export GH_FAIL_MATCH='project view'   # short-circuits before the queue → no queue_response needed
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot access project"* ]]
}

@test "missing a required option → exit 1 naming it" {
  cfg_with_number
  queue_response '{"id":"PVT_x"}'                                                   # gh project view
  queue_response '{"fields":[{"name":"Status","options":[{"name":"In Progress"},{"name":"In Review"},{"name":"QA"}]}]}'  # field-list (no Done)
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Done"* ]]
}

@test "all four options present → exit 0 with summary" {
  cfg_with_number
  queue_response '{"id":"PVT_x"}'                                                   # gh project view
  queue_response '{"fields":[{"name":"Status","options":[{"name":"In Progress"},{"name":"In Review"},{"name":"QA"},{"name":"Done"}]}]}'  # field-list
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "duplicate-named status field → exit 1" {
  cfg_with_number
  queue_response '{"id":"PVT_x"}'
  queue_response '{"fields":[{"name":"Status","options":[]},{"name":"Status","options":[]}]}'
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unique"* ]]
}
```

- [ ] **Step 2: Run tests, expect FAIL**

Run: `bats tests/orchestration/project-check.bats`
Expected: all FAIL — script does not exist (exit 127).

- [ ] **Step 3: Write `project-check.sh`**

Create `plugins/orchestration/scripts/orchestration/project-check.sh`:

```bash
#!/usr/bin/env bash
# project-check.sh — read-only diagnostic for the GitHub Projects (v2) status-sync config.
# Verifies the configured board is reachable as config.bot and its status field carries the
# option names the lanes emit. Run from the target repo root. READ-ONLY: mutates nothing.
#
# REQUIRED below = the exact values the lanes pass to project_sync (work-issue*/review-queue/
# qa-check). If a lane's status value ever changes, update BOTH the lane and this list.
#
# exit 0: not configured (number null) OR fully valid.   exit 1: configured but broken.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$DIR/lib.sh"
load_config || exit 1

REQUIRED=("In Progress" "In Review" "QA" "Done")

if [ "$PROJECT_NUMBER" = "null" ]; then
  echo "ganpan project-check: project.number is null → status sync is OFF (no-op). Valid state."
  echo "  Keep project.statusField in the config even when disabled — load_config requires it."
  exit 0
fi

owner="${REPO%%/*}"
if ! gh project view "$PROJECT_NUMBER" --owner "$owner" --format json >/dev/null 2>&1; then
  echo "ganpan project-check: FAIL — cannot access project #$PROJECT_NUMBER as '$BOT' (owner '$owner')."
  echo "  Likely: wrong project.number, the PAT lacks Projects access, or the board is owned by a"
  echo "  different org/user than the repo (owner is derived from config.repo)."
  exit 1
fi

fl=$(gh project field-list "$PROJECT_NUMBER" --owner "$owner" --format json 2>/dev/null) || {
  echo "ganpan project-check: FAIL — could not list fields for project #$PROJECT_NUMBER."; exit 1; }

nmatch=$(printf '%s' "$fl" | jq --arg n "$PROJECT_STATUS_FIELD" '[.fields[] | select(.name==$n)] | length' 2>/dev/null || echo 0)
if [ "${nmatch:-0}" -eq 0 ]; then
  echo "ganpan project-check: FAIL — no field named '$PROJECT_STATUS_FIELD' on project #$PROJECT_NUMBER."
  echo "  Use the built-in 'Status' field, or set project.statusField to your field's exact name."
  exit 1
fi
if [ "$nmatch" -gt 1 ]; then
  echo "ganpan project-check: FAIL — more than one field is named '$PROJECT_STATUS_FIELD'; field names must be unique (use the built-in Status field)."
  exit 1
fi

have=$(printf '%s' "$fl" | jq -r --arg n "$PROJECT_STATUS_FIELD" '.fields[] | select(.name==$n) | .options[].name' 2>/dev/null)
missing=()
for want in "${REQUIRED[@]}"; do
  printf '%s\n' "$have" | grep -qxF "$want" || missing+=("$want")
done
if [ "${#missing[@]}" -gt 0 ]; then
  echo "ganpan project-check: FAIL — field '$PROJECT_STATUS_FIELD' is missing required option(s): ${missing[*]}"
  echo "  The lanes set these exact values; add them as options: ${REQUIRED[*]}"
  exit 1
fi

echo "ganpan project-check: OK — project #$PROJECT_NUMBER, field '$PROJECT_STATUS_FIELD' has all required options (${REQUIRED[*]})."
echo "  Reminder: issues must be added to the board as items (enable the board's auto-add workflow) for sync to take effect."
exit 0
```

- [ ] **Step 4: `chmod +x`, run tests, expect PASS**

Run: `chmod +x plugins/orchestration/scripts/orchestration/project-check.sh && bats tests/orchestration/project-check.bats`
Expected: all 5 PASS.

- [ ] **Step 5: shellcheck**

Run: `shellcheck plugins/orchestration/scripts/orchestration/project-check.sh`
Expected: exit 0. (If it flags `source "$DIR/lib.sh"`, the existing scripts use the same `# shellcheck source=/dev/null` directive — already included.)

- [ ] **Step 6: Commit**

```bash
git add plugins/orchestration/scripts/orchestration/project-check.sh tests/orchestration/project-check.bats
git commit -m "feat(orch): add project-check.sh Projects-config verifier

Read-only diagnostic: confirms the configured board is reachable as the
bot and its status field has the option names the lanes emit (In
Progress/In Review/QA/Done); reports the specific problem otherwise.
Refs #59"
```

---

### Task 2: Docs — `docs/SETUP.md` + `orch-setup.md`

**Files:**
- Modify: `docs/SETUP.md` (item 5, the one-line GitHub Project entry)
- Modify: `plugins/orchestration/commands/orch-setup.md` (step 5 checklist + step 6 verify)

- [ ] **Step 1: Expand the `docs/SETUP.md` Project item**

In `docs/SETUP.md`, replace item 5:

```
5. **(Optional) GitHub Project:** create it, set `project.number`; otherwise leave `null` (sync becomes a no-op).
```

with:

```
5. **(Optional) GitHub Project status sync.** Lanes mirror each issue's status onto a Projects (v2) board via `project_sync` when `project.number` is set (leave it `null` to disable — but keep `project.statusField`, which `load_config` always requires). To enable:
   1. Create a Projects v2 board owned by the **same org/user as the repo** (the board owner is derived from `repo`).
   2. On the board's status single-select field (the built-in **Status** field is recommended; field names must be unique), ensure options named **exactly** `In Progress`, `In Review`, `QA`, `Done` — these are the values the lanes set; a missing option makes sync fail.
   3. Add repo issues to the board as items — enable the board's built-in **auto-add workflow** (Project → Workflows → "Auto-add to project") so new/updated issues appear; `project_sync` edits an existing item and can't add one.
   4. Give the bot **Projects access** (the PAT's Projects RW scope) and set `project.number` (and `project.statusField` if not `Status`) in the config.
   5. Verify: `scripts/orchestration/project-check.sh` — it reports missing access, wrong field, or missing options.
```

- [ ] **Step 2: Add the Project steps to `orch-setup.md`**

In `plugins/orchestration/commands/orch-setup.md` step 5 (the manual-steps checklist), after the "Branch protection on `main`" bullet, add:

```
   - **(Optional) GitHub Project status sync:** to mirror issue status onto a Projects (v2) board, create the board (owned by the same org/user as the repo), ensure its Status single-select field has options named exactly `In Progress`, `In Review`, `QA`, `Done`, enable the board's auto-add workflow so issues become items, set `project.number` in the config, and verify with `${CLAUDE_PLUGIN_ROOT}/scripts/orchestration/project-check.sh`. Leave `project.number` null to keep sync off (but keep `project.statusField`).
```

In step 6 (Verify), after the label-count block, add a line:

```
   If a GitHub Project is configured, also run `${CLAUDE_PLUGIN_ROOT}/scripts/orchestration/project-check.sh` to confirm the board's status field has the required options.
```

- [ ] **Step 3: Commit**

```bash
git add docs/SETUP.md plugins/orchestration/commands/orch-setup.md
git commit -m "docs(orch): document GitHub Project setup + project-check verify (#59)"
```

---

### Task 3: Version bump + dev-log + final gate

**Files:**
- Create: `docs/log/2026-06-26-github-project-setup.md`
- Modify: `plugins/orchestration/.claude-plugin/plugin.json`

- [ ] **Step 1: Write the dev-log**

Create `docs/log/2026-06-26-github-project-setup.md` per `docs/log/README.md`, recording: the verifier + docs (what); the silent-failure modes it addresses — missing Status options, unadded issues, no bot access, board-owner mismatch, deleted statusField (why); key decisions — verify-and-document not auto-create (board creation is a human action, consistent with branch protection / bot account; `gh project create` needs Projects scope + structural choices), the four-option contract mirrored from `project_sync` with a single-source-to-update note, wiring into `orch-setup` instead of a new top-level command; rejected alternatives — auto-creating/configuring the board, a standalone `/ganpan:project-check` command + Codex skill, changing `load_config` to make `statusField` optional.

- [ ] **Step 2: Commit the dev-log (before the bump)**

```bash
git add docs/log/2026-06-26-github-project-setup.md
git commit -m "docs(log): #59 GitHub Project integration docs + verifier"
```

- [ ] **Step 3: Bump the minor version**

Run `git fetch origin main && git show origin/main:plugins/orchestration/.claude-plugin/plugin.json | jq -r .version` for main's `M.m.p`. Set `version` to `M.(m+1).0`. Validate `jq . plugins/orchestration/.claude-plugin/plugin.json .claude-plugin/marketplace.json`.

- [ ] **Step 4: Commit the bump**

```bash
NEW_VER=$(jq -r .version plugins/orchestration/.claude-plugin/plugin.json)
git add plugins/orchestration/.claude-plugin/plugin.json
git commit -m "chore(release): bump orchestration to ${NEW_VER} for #59 (feat -> minor)"
```

- [ ] **Step 5: Final gate**

Run: `bats tests/*.bats tests/orchestration/*.bats`  → all green.
Run: `shellcheck plugins/orchestration/scripts/orchestration/*.sh`  → exit 0.
Run: `jq . plugins/orchestration/.claude-plugin/plugin.json .claude-plugin/marketplace.json plugins/orchestration/assets/orchestration.json`  → valid.

> **Cross-PR version note:** compute the bump from `origin/main` at Step 3; flag in the PR body that a merge-time re-bump may be needed. The dev-log is a separate commit so a re-bump never drops it.
