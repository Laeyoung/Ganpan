# Actor Identity Gate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `require_bot_actor` runtime gate so every orchestration write to GitHub is performed as the configured `config.bot`, hard-blocking when `gh`'s resolved actor differs.

**Architecture:** A single shared helper in `lib.sh` queries `gh api user` and compares the login to `$BOT`. The three engine scripts (`claim.sh`, `heartbeat.sh`, `reclaim.sh`) call it after `load_config` and before their first write; the four lane commands add a one-line preamble that calls it. `/orch-setup` prints the current actor as a warning (it does not block, since the PAT may not exist yet). `bootstrap-labels.sh` is intentionally **not** gated.

**Tech Stack:** Bash (`set -euo pipefail`), `gh` CLI, `jq`, `bats` tests with a fake-`gh` stub, `shellcheck`.

**Spec:** `docs/superpowers/specs/2026-06-19-actor-identity-gate-design.md`

## Global Constraints

- **Never rename engine internals** — `scripts/orchestration/` paths, the `.claude/orchestration.json` filename, and the `ganpan-orchestration` version sentinel are the deployed runtime contract.
- **Escape hatch:** `ORCH_SKIP_ACTOR_CHECK=1` short-circuits the gate to success; it must be honored and must be set per-invocation only (documented, never globally exported).
- **`bootstrap-labels.sh` is NOT gated** (per spec §4.3) — do not add `require_bot_actor` to it.
- **Commits:** Conventional Commits (`type(scope): subject`), body explains what & why.
- **Exit code on gate failure:** `require_bot_actor || exit 1` — engine scripts exit `1` when the actor mismatches.
- **Config bot in all test fixtures is `botx`** — gate tests set `GH_STUB_LOGIN` to control the stub's reported login.

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `plugins/orchestration/scripts/orchestration/lib.sh` | shared config + helpers | **add** `require_bot_actor` |
| `tests/orchestration/helpers/gh-stub.sh` | fake `gh` for bats | **add** `api user` branch |
| `tests/orchestration/lib.bats` | helper unit tests | **add** gate cases + stub wiring |
| `plugins/orchestration/scripts/orchestration/claim.sh` | claim an issue | **add** gate call |
| `plugins/orchestration/scripts/orchestration/heartbeat.sh` | refresh claim comment | **add** gate call |
| `plugins/orchestration/scripts/orchestration/reclaim.sh` | revert orphan locks | **add** gate call |
| `tests/orchestration/{claim,heartbeat,reclaim}.bats` | engine tests | **add** `GH_STUB_LOGIN=botx` to setup + one mismatch test each |
| `plugins/orchestration/commands/{triage,review-queue,work-issue,qa-check}.md` | lane commands | **add** gate preamble |
| `plugins/orchestration/commands/orch-setup.md` | setup lane | **add** actor-print warning + reframe PAT bullet |
| `README.md`, `plugins/orchestration/assets/CLAUDE.md` | docs | **reframe** PAT as runtime precondition + document escape hatch |

---

### Task 1: `require_bot_actor` helper + stub support + unit tests

**Files:**
- Modify: `tests/orchestration/helpers/gh-stub.sh` (after line 14, before line 15)
- Modify: `tests/orchestration/lib.bats` (setup + new tests)
- Modify: `plugins/orchestration/scripts/orchestration/lib.sh:26` (after `load_config`)

**Interfaces:**
- Produces: `require_bot_actor()` — no args; reads global `$BOT` (set by `load_config`); returns `0` when `gh api user --jq .login` equals `$BOT` or when `ORCH_SKIP_ACTOR_CHECK=1`; returns non-zero (with a `log ERROR` message) on mismatch, empty `$BOT`, empty login, or unresolvable identity. Called by Tasks 2–5.
- Produces (test stub): `gh api user …` echoes `${GH_STUB_LOGIN-bot-login}` and exits without consuming a queued-response slot. Tests set `GH_STUB_LOGIN`.

- [ ] **Step 1: Extend the gh stub with an `api user` branch**

In `tests/orchestration/helpers/gh-stub.sh`, insert this block **between** the `GH_FAIL_MATCH` `fi` (line 14) and the existing `case "${1:-} ${2:-}" in` (line 15):

```bash
# `gh api user` (the actor-identity probe) — emit a configurable login WITHOUT
# consuming a queued-response slot. Standalone case BEFORE the queue-emitting one;
# 3-word expansion so "api user "* matches `gh api user --jq .login`.
# `-` (not `:-`): GH_STUB_LOGIN set-but-empty yields an empty login, for the
# "empty login" gate test.
case "${1:-} ${2:-} ${3:-}" in
  "api user "*) echo "${GH_STUB_LOGIN-bot-login}"; exit "${GH_EXIT:-0}" ;;
esac
```

- [ ] **Step 2: Wire the stub into lib.bats setup and add failing gate tests**

In `tests/orchestration/lib.bats`, change `setup()` to load the stub. Replace:

```bash
setup() {
  LIB="$BATS_TEST_DIRNAME/../../plugins/orchestration/scripts/orchestration/lib.sh"
```

with:

```bash
setup() {
  load helpers/common
  setup_gh_stub
  LIB="$BATS_TEST_DIRNAME/../../plugins/orchestration/scripts/orchestration/lib.sh"
```

Then append these tests to the end of `tests/orchestration/lib.bats`:

```bash
@test "require_bot_actor passes when gh actor == config.bot" {
  export GH_STUB_LOGIN=botx
  run bash -c 'source "$0"; load_config; require_bot_actor' "$LIB"
  [ "$status" -eq 0 ]
}

@test "require_bot_actor fails (with message) when actor != bot" {
  export GH_STUB_LOGIN=intruder
  run bash -c 'source "$0"; load_config; require_bot_actor 2>&1' "$LIB"
  [ "$status" -ne 0 ]
  [[ "$output" == *"acting as 'intruder'"* ]]
}

@test "require_bot_actor fails when config.bot is empty" {
  printf '%s' '{"repo":"o/r","bot":"","candidateN":3,"wipLimit":4,"reclaim":{"timeoutMinutes":120,"heartbeatMinutes":15},"commands":{"test":null,"build":null,"lint":null},"worktreeBaseDir":"../","project":{"number":null,"statusField":"Status"}}' > "$ORCH_CONFIG"
  export GH_STUB_LOGIN=botx
  run bash -c 'source "$0"; load_config; require_bot_actor 2>&1' "$LIB"
  [ "$status" -ne 0 ]
  [[ "$output" == *"config.bot is empty"* ]]
}

@test "require_bot_actor fails when gh returns an empty login" {
  export GH_STUB_LOGIN=
  run bash -c 'source "$0"; load_config; require_bot_actor 2>&1' "$LIB"
  [ "$status" -ne 0 ]
  [[ "$output" == *"empty login"* ]]
}

@test "ORCH_SKIP_ACTOR_CHECK=1 short-circuits without calling gh" {
  export ORCH_SKIP_ACTOR_CHECK=1
  export GH_STUB_LOGIN=intruder
  run bash -c 'source "$0"; load_config; require_bot_actor' "$LIB"
  [ "$status" -eq 0 ]
  ! grep -q 'api user' "$GH_CALLS"
}
```

- [ ] **Step 3: Run the new tests to verify they fail**

Run: `bats tests/orchestration/lib.bats -f require_bot_actor` and `bats tests/orchestration/lib.bats -f ORCH_SKIP`
Expected: FAIL — `require_bot_actor: command not found` (helper not defined yet).

- [ ] **Step 4: Implement `require_bot_actor` in lib.sh**

In `plugins/orchestration/scripts/orchestration/lib.sh`, insert the function immediately after the `load_config` closing brace (line 26). Replace:

```bash
  export REPO BOT CANDIDATE_N WIP_LIMIT RECLAIM_TIMEOUT_MIN HEARTBEAT_MIN WORKTREE_BASE PROJECT_NUMBER PROJECT_STATUS_FIELD WORKER_ID
}
```

with:

```bash
  export REPO BOT CANDIDATE_N WIP_LIMIT RECLAIM_TIMEOUT_MIN HEARTBEAT_MIN WORKTREE_BASE PROJECT_NUMBER PROJECT_STATUS_FIELD WORKER_ID
}

# require_bot_actor — assert the gh actor matches config.bot before any write.
# Escape hatch: ORCH_SKIP_ACTOR_CHECK=1 (e.g. CI where the bot PAT *is* the actor).
# Must be set per-invocation, never exported globally.
require_bot_actor() {
  [ "${ORCH_SKIP_ACTOR_CHECK:-}" = "1" ] && return 0
  # jq -er in load_config rejects null but NOT an empty JSON string, so config.bot=""
  # yields BOT=""; without this guard an empty actor would compare equal and pass.
  [ -n "$BOT" ] || { log ERROR "config.bot is empty"; return 1; }
  local actor
  actor=$(gh api user --jq .login 2>/dev/null) \
    || { log ERROR "cannot resolve gh identity (gh authenticated?)"; return 1; }
  [ -n "$actor" ] || { log ERROR "gh api user returned empty login"; return 1; }
  if [ "$actor" != "$BOT" ]; then
    log ERROR "gh is acting as '$actor' but config.bot is '$BOT'."
    log ERROR "Export the bot PAT first:  export GH_TOKEN=github_pat_...  (HTTPS, not ssh)"
    return 1
  fi
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bats tests/orchestration/lib.bats`
Expected: PASS (all existing + 5 new cases).

- [ ] **Step 6: Lint**

Run: `shellcheck plugins/orchestration/scripts/orchestration/lib.sh`
Expected: no output (clean).

- [ ] **Step 7: Commit**

```bash
git add plugins/orchestration/scripts/orchestration/lib.sh tests/orchestration/helpers/gh-stub.sh tests/orchestration/lib.bats
git commit -m "feat(orch): add require_bot_actor identity gate helper

Asserts the gh actor matches config.bot. Empty-bot/empty-login guards and
ORCH_SKIP_ACTOR_CHECK escape hatch. gh stub gains an api-user branch.

Refs docs/superpowers/specs/2026-06-19-actor-identity-gate-design.md"
```

---

### Task 2: Gate `claim.sh`

**Files:**
- Modify: `tests/orchestration/claim.bats` (setup + new test)
- Modify: `plugins/orchestration/scripts/orchestration/claim.sh:8` (after `load_config`)

**Interfaces:**
- Consumes: `require_bot_actor` (Task 1).

- [ ] **Step 1: Pin the stub login for existing tests and add a failing mismatch test**

In `tests/orchestration/claim.bats`, add `export GH_STUB_LOGIN=botx` to `setup()` so the existing 11 tests pass the gate once it lands. Replace:

```bash
  export CLAIM_BACKOFF_SECS=0   # make tests fast
  SCRIPT="$BATS_TEST_DIRNAME/../../plugins/orchestration/scripts/orchestration/claim.sh"
}
```

with:

```bash
  export CLAIM_BACKOFF_SECS=0   # make tests fast
  export GH_STUB_LOGIN=botx     # gh actor matches config.bot so the identity gate passes
  SCRIPT="$BATS_TEST_DIRNAME/../../plugins/orchestration/scripts/orchestration/claim.sh"
}
```

Then append this test to the end of `tests/orchestration/claim.bats`:

```bash
@test "actor mismatch (wrong gh login) → aborts before any write" {
  export GH_STUB_LOGIN=intruder
  queue_response '[{"number":42,"createdAt":"2026-01-01T00:00:00Z"}]'   # would be claimed without the gate
  export CLAIM_TOKEN_OVERRIDE='2026-02-01T00:00:00Z-botx-h-1'
  queue_response '{"labels":[{"name":"status:in-progress"}],"assignees":[{"login":"botx"}],"comments":[{"id":1,"author":{"login":"botx"},"body":"claim: 2026-02-01T00:00:00Z-botx-h-1"}]}'
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  ! grep -q 'issue edit' "$GH_CALLS"
  ! grep -q 'issue comment' "$GH_CALLS"
}
```

- [ ] **Step 2: Run claim.bats to verify the new test fails (RED)**

Run: `bats tests/orchestration/claim.bats`
Expected: the 11 existing tests PASS; the new test FAILS (no gate yet → claim proceeds and `issue edit` is recorded).

- [ ] **Step 3: Add the gate to claim.sh**

In `plugins/orchestration/scripts/orchestration/claim.sh`, replace:

```bash
source "$DIR/lib.sh"
load_config

BACKOFF="${CLAIM_BACKOFF_SECS:-3}"
```

with:

```bash
source "$DIR/lib.sh"
load_config
require_bot_actor || exit 1

BACKOFF="${CLAIM_BACKOFF_SECS:-3}"
```

- [ ] **Step 4: Run claim.bats to verify all pass (GREEN)**

Run: `bats tests/orchestration/claim.bats`
Expected: PASS (all 12).

- [ ] **Step 5: Lint**

Run: `shellcheck plugins/orchestration/scripts/orchestration/claim.sh`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add plugins/orchestration/scripts/orchestration/claim.sh tests/orchestration/claim.bats
git commit -m "feat(orch): gate claim.sh on bot identity

require_bot_actor runs after load_config, before the first mutating gh call,
so a wrong-actor run aborts before claiming. Refs the actor-identity spec."
```

---

### Task 3: Gate `heartbeat.sh`

**Files:**
- Modify: `tests/orchestration/heartbeat.bats` (setup + new test)
- Modify: `plugins/orchestration/scripts/orchestration/heartbeat.sh:8` (after `load_config`)

**Interfaces:**
- Consumes: `require_bot_actor` (Task 1).

- [ ] **Step 1: Pin the stub login and add a failing mismatch test**

In `tests/orchestration/heartbeat.bats`, add the stub login to `setup()`. Replace:

```bash
  SCRIPT="$BATS_TEST_DIRNAME/../../plugins/orchestration/scripts/orchestration/heartbeat.sh"
}
```

with:

```bash
  export GH_STUB_LOGIN=botx     # gh actor matches config.bot so the identity gate passes
  SCRIPT="$BATS_TEST_DIRNAME/../../plugins/orchestration/scripts/orchestration/heartbeat.sh"
}
```

Then append:

```bash
@test "actor mismatch → aborts before PATCH" {
  export GH_STUB_LOGIN=intruder
  export CLAIM_TOKEN_OVERRIDE='2026-02-01T00:00:00Z-botx-h-1'
  queue_response '{"comments":[{"id":555,"author":{"login":"botx"},"body":"claim: old-token"}]}'  # would be PATCHed without the gate
  run bash "$SCRIPT" 42
  [ "$status" -ne 0 ]
  ! grep -q 'api --method PATCH' "$GH_CALLS"
}
```

- [ ] **Step 2: Run heartbeat.bats to verify the new test fails (RED)**

Run: `bats tests/orchestration/heartbeat.bats`
Expected: existing 3 PASS; new test FAILS (PATCH recorded, no gate).

- [ ] **Step 3: Add the gate to heartbeat.sh**

In `plugins/orchestration/scripts/orchestration/heartbeat.sh`, replace:

```bash
source "$DIR/lib.sh"
load_config

issue="${1:?issue number required}"
```

with:

```bash
source "$DIR/lib.sh"
load_config
require_bot_actor || exit 1

issue="${1:?issue number required}"
```

- [ ] **Step 4: Run heartbeat.bats to verify all pass (GREEN)**

Run: `bats tests/orchestration/heartbeat.bats`
Expected: PASS (all 4).

- [ ] **Step 5: Lint**

Run: `shellcheck plugins/orchestration/scripts/orchestration/heartbeat.sh`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add plugins/orchestration/scripts/orchestration/heartbeat.sh tests/orchestration/heartbeat.bats
git commit -m "feat(orch): gate heartbeat.sh on bot identity

require_bot_actor runs after load_config, before the PATCH write, so a
wrong-actor heartbeat aborts instead of refreshing the claim comment."
```

---

### Task 4: Gate `reclaim.sh`

**Files:**
- Modify: `tests/orchestration/reclaim.bats` (setup + new test)
- Modify: `plugins/orchestration/scripts/orchestration/reclaim.sh:7` (after `load_config`)

**Interfaces:**
- Consumes: `require_bot_actor` (Task 1).

- [ ] **Step 1: Pin the stub login and add a failing mismatch test**

In `tests/orchestration/reclaim.bats`, add the stub login to `setup()`. Replace:

```bash
  SCRIPT="$BATS_TEST_DIRNAME/../../plugins/orchestration/scripts/orchestration/reclaim.sh"
}
```

with:

```bash
  export GH_STUB_LOGIN=botx     # gh actor matches config.bot so the identity gate passes
  SCRIPT="$BATS_TEST_DIRNAME/../../plugins/orchestration/scripts/orchestration/reclaim.sh"
}
```

Then append:

```bash
@test "actor mismatch → aborts before any write" {
  export GH_STUB_LOGIN=intruder
  queue_response '[{"number":6}]'                                                                # would be reclaimed without the gate
  queue_response '{"comments":[{"author":{"login":"botx"},"body":"claim: 2000-01-01T00:00:00Z-botx-h-1"}]}'
  queue_response '[]'
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  ! grep -q 'issue edit' "$GH_CALLS"
}
```

- [ ] **Step 2: Run reclaim.bats to verify the new test fails (RED)**

Run: `bats tests/orchestration/reclaim.bats`
Expected: existing tests PASS; new test FAILS (issue edit recorded, no gate).

- [ ] **Step 3: Add the gate to reclaim.sh**

In `plugins/orchestration/scripts/orchestration/reclaim.sh`, replace:

```bash
source "$DIR/lib.sh"
load_config

list=$(gh issue list --label status:in-progress --json number --limit 1000 --repo "$REPO") || exit 1
```

with:

```bash
source "$DIR/lib.sh"
load_config
require_bot_actor || exit 1

list=$(gh issue list --label status:in-progress --json number --limit 1000 --repo "$REPO") || exit 1
```

- [ ] **Step 4: Run reclaim.bats to verify all pass (GREEN)**

Run: `bats tests/orchestration/reclaim.bats`
Expected: PASS (all existing + new).

- [ ] **Step 5: Lint**

Run: `shellcheck plugins/orchestration/scripts/orchestration/reclaim.sh`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add plugins/orchestration/scripts/orchestration/reclaim.sh tests/orchestration/reclaim.bats
git commit -m "feat(orch): gate reclaim.sh on bot identity

require_bot_actor runs after load_config, before the in-progress sweep's
first write, so a wrong-actor reclaim aborts before reverting any lock."
```

---

### Task 5: Gate the four lane commands

The lane command markdown issues bot writes inline (not through the engine scripts), so each needs its own gate preamble. Lanes run from the **main repo root**, where `./.claude/orchestration.json` resolves, so a plain `load_config` works. This is markdown (AI instructions), verified by `grep`, not bats.

**Files:**
- Modify: `plugins/orchestration/commands/triage.md`
- Modify: `plugins/orchestration/commands/review-queue.md`
- Modify: `plugins/orchestration/commands/work-issue.md`
- Modify: `plugins/orchestration/commands/qa-check.md`

- [ ] **Step 1: Gate `triage.md`**

Replace:

```markdown
1. **Reclaim sweep.** Run `${CLAUDE_PLUGIN_ROOT}/scripts/orchestration/reclaim.sh` (reverts orphaned in-progress locks; skips unresolved-rework and open-PR cases).
```

with:

````markdown
0. **Identity gate (run first, from the main repo root, before any bot write):**
   ```bash
   source "${CLAUDE_PLUGIN_ROOT}/scripts/orchestration/lib.sh" && load_config && require_bot_actor || exit 1
   ```
   If this fails, **stop** — `gh` is not acting as the configured bot. Export the bot PAT (`export GH_TOKEN=github_pat_...`) and re-run.
1. **Reclaim sweep.** Run `${CLAUDE_PLUGIN_ROOT}/scripts/orchestration/reclaim.sh` (reverts orphaned in-progress locks; skips unresolved-rework and open-PR cases).
````

- [ ] **Step 2: Gate `review-queue.md`**

Replace:

```markdown
For each issue labelled `status:in-review` (find its PR via branch `issue-<n>` or the issue's PR link):
```

with:

````markdown
**Identity gate (run first, from the main repo root):**
```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/orchestration/lib.sh" && load_config && require_bot_actor || exit 1
```
If this fails, **stop** and export the bot PAT (`export GH_TOKEN=github_pat_...`).

For each issue labelled `status:in-review` (find its PR via branch `issue-<n>` or the issue's PR link):
````

- [ ] **Step 3: Gate `work-issue.md`**

Replace:

```markdown
Do exactly this, stopping at the first step that says to stop:
```

with:

````markdown
**Identity gate (run first, from the main repo root, before any `cd`):**
```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/orchestration/lib.sh" && load_config && require_bot_actor || exit 1
```
If this fails, **stop** and export the bot PAT (`export GH_TOKEN=github_pat_...`). (`claim.sh`/`heartbeat.sh` self-gate, but the resume path and the inline `gh pr create` write need this explicit check.)

Do exactly this, stopping at the first step that says to stop:
````

- [ ] **Step 4: Gate `qa-check.md`**

Replace:

```markdown
For each issue labelled `status:qa`:
```

with:

````markdown
**Identity gate (run first, from the main repo root, before any `cd`):**
```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/orchestration/lib.sh" && load_config && require_bot_actor || exit 1
```
If this fails, **stop** and export the bot PAT (`export GH_TOKEN=github_pat_...`). (Plain `load_config` is correct here: the gate runs from the main repo root before this lane steps into any worktree, so `./.claude/orchestration.json` resolves — same preamble as the other three lanes.)

For each issue labelled `status:qa`:
````

- [ ] **Step 5: Verify all four lanes contain the gate**

Run:
```bash
grep -l 'require_bot_actor || exit 1' plugins/orchestration/commands/triage.md plugins/orchestration/commands/review-queue.md plugins/orchestration/commands/work-issue.md plugins/orchestration/commands/qa-check.md | wc -l
```
Expected: `4`

- [ ] **Step 6: Commit**

```bash
git add plugins/orchestration/commands/triage.md plugins/orchestration/commands/review-queue.md plugins/orchestration/commands/work-issue.md plugins/orchestration/commands/qa-check.md
git commit -m "feat(orch): add require_bot_actor preamble to the four lanes

Lanes write to GitHub inline (not via engine scripts), so each gates its
own bot writes. bootstrap-labels.sh stays ungated per spec (setup-time)."
```

---

### Task 6: `/orch-setup` warning + docs

`/orch-setup` warns (does not block) since the PAT may not exist yet. README and the shipped `assets/CLAUDE.md` reframe the PAT as a runtime precondition. All markdown — verified by `grep`.

**Files:**
- Modify: `plugins/orchestration/commands/orch-setup.md` (step 1)
- Modify: `README.md` (post-setup checklist item 1)
- Modify: `plugins/orchestration/assets/CLAUDE.md` (Merge gate section)

- [ ] **Step 1: Update orch-setup.md — actor-print warning + reframe the PAT bullet**

First, add the actor-print warning to step 1. Replace:

```markdown
   command -v gh jq yq || { echo "missing prerequisite (need gh, jq, yq)"; exit 1; }
   gh auth status || { echo "gh not authenticated — run: GH_TOKEN=... or gh auth login"; exit 1; }
```

with:

```markdown
   command -v gh jq yq || { echo "missing prerequisite (need gh, jq, yq)"; exit 1; }
   gh auth status || { echo "gh not authenticated — run: GH_TOKEN=... or gh auth login"; exit 1; }
   actor=$(gh api user --jq .login 2>/dev/null)
   echo "ⓘ gh is currently acting as: ${actor:-<unknown>}"
   echo "  After creating the bot PAT, run lanes with:  export GH_TOKEN=github_pat_..."
   echo "  (must resolve to the bot account — NOT '${actor:-your personal login}')"
```

Then, in the **same file**, reframe the bot-PAT manual-steps bullet as a runtime precondition (spec §4.4 names both `README.md:80` **and** `orch-setup.md:44`). Replace:

```markdown
   - Create a **bot account + fine-grained PAT** scoped to the target repo: Contents RW, Pull requests RW, Issues RW, Projects RW; export `GH_TOKEN=github_pat_...` (HTTPS, not ssh).
```

with:

```markdown
   - Create a **bot account + fine-grained PAT** scoped to the target repo: Contents RW, Pull requests RW, Issues RW, Projects RW; export `GH_TOKEN=github_pat_...` (HTTPS, not ssh). **This is a runtime precondition, not a recommendation** — every lane verifies `gh` is acting as `config.bot` at startup and hard-stops on mismatch.
```

- [ ] **Step 2: Reframe the PAT as a runtime precondition in README.md**

Replace:

```markdown
1. **봇 계정 + Fine-grained PAT** — 대상 레포에만 Contents RW / Pull requests RW / Issues RW / Projects RW, 만료 90일. `GH_TOKEN=github_pat_...`로 export(HTTPS 사용; `--with-token` 금지).
```

with:

```markdown
1. **봇 계정 + Fine-grained PAT** — 대상 레포에만 Contents RW / Pull requests RW / Issues RW / Projects RW, 만료 90일. `GH_TOKEN=github_pat_...`로 export(HTTPS 사용; `--with-token` 금지). **이는 권장이 아니라 실행 전제조건입니다** — 레인은 시작 시 `gh` 행위 주체가 `config.bot`과 일치하는지 확인하고, 일치하지 않으면(예: `GH_TOKEN` 미설정 → 개인 계정으로 폴백) 즉시 중단합니다. (CI 등 봇 PAT가 곧 주체임이 확실한 경우에만 호출 단위로 `ORCH_SKIP_ACTOR_CHECK=1`을 쓸 수 있으며, 전역 export는 금지.)
```

- [ ] **Step 3: Document the gate in the shipped assets/CLAUDE.md**

Replace:

```markdown
## Merge gate
- Agents never approve or merge PRs. A human reviews and merges (branch protection enforces this).
```

with:

```markdown
## Merge gate
- Agents never approve or merge PRs. A human reviews and merges (branch protection enforces this).

## Bot identity
- Lanes verify `gh` is acting as `config.bot` before any write and **hard-stop** otherwise. Export the bot's fine-grained PAT first: `export GH_TOKEN=github_pat_...` (HTTPS). If a lane stops with "gh is acting as '<you>' but config.bot is '<bot>'", your `GH_TOKEN` is unset or wrong.
- `ORCH_SKIP_ACTOR_CHECK=1` bypasses the check — use it **per-invocation only** (e.g. CI where the bot PAT is the actor), never as a global export.
```

- [ ] **Step 4: Verify the doc edits landed**

Run:
```bash
grep -q 'gh is currently acting as' plugins/orchestration/commands/orch-setup.md \
  && grep -q 'runtime precondition, not a recommendation' plugins/orchestration/commands/orch-setup.md \
  && grep -q '실행 전제조건' README.md \
  && grep -q 'ORCH_SKIP_ACTOR_CHECK' plugins/orchestration/assets/CLAUDE.md \
  && echo OK
```
Expected: `OK`

- [ ] **Step 5: Validate manifests still parse (assets are not manifests, but run the repo's standard check)**

Run: `jq . .claude-plugin/marketplace.json plugins/orchestration/.claude-plugin/plugin.json > /dev/null && echo OK`
Expected: `OK`

- [ ] **Step 6: Commit**

```bash
git add plugins/orchestration/commands/orch-setup.md README.md plugins/orchestration/assets/CLAUDE.md
git commit -m "docs(orch): surface actor in /orch-setup, frame PAT as runtime precondition

/orch-setup prints the current gh actor as a warning. README + shipped
assets/CLAUDE.md document the runtime gate and the per-invocation escape hatch."
```

---

### Task 7: Full pre-merge verification

The repo's merge gate (`CLAUDE.md` + spec §7.1) requires the whole suite and shellcheck to be green before a human merges.

**Files:** none (verification only).

- [ ] **Step 1: Run the full test suite**

Run: `bats tests/orchestration/ tests/install.bats`
Expected: all tests PASS (including the 5 new lib.bats cases and the 3 engine mismatch tests).

- [ ] **Step 2: Shellcheck every engine script**

Run: `shellcheck plugins/orchestration/scripts/orchestration/*.sh`
Expected: no output (clean).

- [ ] **Step 3: Validate the plugin manifests**

Run: `jq . .claude-plugin/marketplace.json plugins/orchestration/.claude-plugin/plugin.json > /dev/null && echo OK`
Expected: `OK`

- [ ] **Step 4: Confirm `bootstrap-labels.sh` was left ungated (intentional)**

Run: `! grep -q require_bot_actor plugins/orchestration/scripts/orchestration/bootstrap-labels.sh && echo "ungated as intended"`
Expected: `ungated as intended`

This task adds no commit; it is the human-review checkpoint. A human reviews the branch and merges (agents never merge).

---

## Self-Review

**Spec coverage:**
- §4.1 helper → Task 1 (with empty-`$BOT`/empty-actor guards, escape hatch). ✓
- §4.2 engine call sites → Tasks 2–4; lane call sites → Task 5. ✓
- §4.2.1 `WORKER_ID` → no code change required (informational; gate prevents new mismatched tokens). ✓
- §4.3 `/orch-setup` warn + `bootstrap-labels.sh` ungated → Task 6 Step 1; Task 7 Step 4 asserts ungated. ✓
- §4.4 docs — `README.md:80` → Task 6 Step 2; `orch-setup.md:44` PAT-bullet reframe → Task 6 Step 1; `assets/CLAUDE.md` → Task 6 Step 3. ✓
- §6 testing: stub extension + lib.bats cases → Task 1; all three engine scripts gated+tested → Tasks 2–4. ✓
- §7/§7.1 escape hatch, casing (no normalization applied → no action), pre-merge gate → Task 7. ✓

**Placeholder scan:** No TBD/TODO; every code/markdown step shows the exact replacement text and exact commands with expected output.

**Type consistency:** `require_bot_actor` is named identically across lib.sh, all three engine scripts, the four lanes, and every test. The gate invocation is uniformly `require_bot_actor || exit 1`. Stub variable `GH_STUB_LOGIN` and call-log `GH_CALLS` match `helpers/common.bash`/`gh-stub.sh`.
