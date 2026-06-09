# GitHub-native Orchestration v1 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the lightweight GitHub-native orchestration toolkit defined in `docs/superpowers/specs/2026-06-09-github-orchestration-spec-design.md` — shared shell helpers + thin `.claude/commands` that run 4 Claude Code lanes (Triager/Coder/Reviewer/QA) over GitHub Issues/PRs/labels.

**Architecture:** Concurrency-sensitive logic (atomic claim, reclaim, WIP check, test-command detection, label bootstrap) lives in tested `scripts/orchestration/*.sh`; `.claude/commands/*.md` are thin prompts that call those scripts and transition labels. State lives entirely in GitHub (labels + comment markers). No service, no runtime beyond `bash`/`gh`.

**Tech Stack:** bash (`set -euo pipefail`), `gh` CLI, `jq`, `yq`, `git worktree`, `bats-core` (unit tests with a `gh` stub on `PATH`).

---

## Conventions locked for all tasks

These names/contracts are referenced by every task. Do not rename.

**Config → env (set by `load_config` in `lib.sh`):** `REPO`, `BOT`, `CANDIDATE_N`, `WIP_LIMIT`, `RECLAIM_TIMEOUT_MIN`, `HEARTBEAT_MIN`, `WORKTREE_BASE`, `PROJECT_NUMBER` (string `"null"` when unset), `PROJECT_STATUS_FIELD`, `WORKER_ID` (= `${BOT}-<host>-<pid>`, per-process unique — used in claim token), plus exported `SCRIPT_DIR`.

**`lib.sh` functions:** `log <LEVEL> <msg…>` (stderr), `load_config`, `claim_token` (prints `<ISO8601-UTC>-<WORKER_ID>`), `now_epoch`, `iso_to_epoch <iso>`, `gh_repo <args…>` (= `gh <args…> --repo "$REPO"`), `project_sync <issue#> <statusValue>`.

**Script exit codes:** `claim.sh` 0=claimed (prints issue#) / 1=no candidates / 2=lost race. `heartbeat.sh` 0=ok / 1=api-fail. `reclaim.sh` 0=swept / 1=api-fail. `wip-check.sh` 0=OK / 1=EXCEED / 2=api-fail. `detect-test-cmd.sh <test|build|lint>` 0 always (prints command or empty).

**Comment markers (bot-authored, prefix-grep):** `claim: <token>` (one per issue, edited in place by id), `rework-requested: <reason>` / `rework-resolved:` (new comments; unresolved = latest `rework-requested:` has no later `rework-resolved:`), `qa-fail-count: <N>`.

**Single-bot claim discriminator:** GitHub dedups assignees to one login, so two concurrent Coder processes both assign `$BOT` → assignee count stays 1. The race discriminator is therefore the number of distinct `claim:` **tokens** on the issue: if ≥2, the lexicographically-smallest token wins; losers delete their own claim comment and release. (Assignee is kept as a human-visible marker only.)

**Lane cwd convention:** lane sessions run from the **main repo root**. Orchestration scripts are invoked as `scripts/orchestration/<name>.sh`. `/work-issue` `cd`s into the worktree only for implement/test/commit, then returns.

## File structure

```
.claude/orchestration.json                  # runtime config (Task 1)
.claude/commands/{work-issue,triage,review-queue,qa-check}.md   # lanes (Tasks 9-12)
.claude/loop.md                             # optional /loop default (Task 13)
scripts/orchestration/lib.sh                # config+helpers (Task 2)
scripts/orchestration/bootstrap-labels.sh   # label bootstrap (Task 3)
scripts/orchestration/claim.sh              # atomic claim (Task 5)
scripts/orchestration/heartbeat.sh          # liveness (Task 6)
scripts/orchestration/reclaim.sh            # orphan sweeper (Task 7)
scripts/orchestration/wip-check.sh          # WIP gate (Task 8)
scripts/orchestration/detect-test-cmd.sh    # test cmd detect (Task 9 prep → its own Task 8.5)
tests/orchestration/helpers/{gh-stub.sh,common.bash}   # test infra (Task 4)
tests/orchestration/*.bats                  # unit tests (per script task)
.github/labels.yml                          # label source (Task 3)
.github/ISSUE_TEMPLATE/task.yml             # intake (Task 13)
CLAUDE.md                                    # commit convention (Task 13)
docs/SETUP.md                                # one-time setup (Task 13)
.gitignore                                   # ignore hb pid stragglers (Task 1)
```

---

## Task 1: Repo scaffolding + config

**Files:**
- Create: `.claude/orchestration.json`
- Create: `.gitignore`
- Create dirs: `scripts/orchestration/`, `tests/orchestration/helpers/`

- [ ] **Step 1: Create directories**

Run:
```bash
mkdir -p scripts/orchestration tests/orchestration/helpers .claude/commands .github/ISSUE_TEMPLATE
```

- [ ] **Step 2: Write `.claude/orchestration.json`**

```json
{
  "repo": "owner/repo",
  "bot": "bot-login",
  "candidateN": 5,
  "wipLimit": 5,
  "reclaim": { "timeoutMinutes": 120, "heartbeatMinutes": 15 },
  "commands": { "test": null, "build": null, "lint": null },
  "worktreeBaseDir": "../",
  "project": { "number": null, "statusField": "Status" }
}
```

- [ ] **Step 3: Write `.gitignore`**

```gitignore
# heartbeat pid files are written to $TMPDIR, but ignore strays just in case
hb-*.pid
```

- [ ] **Step 4: Verify jq can read the config**

Run: `jq -er '.repo, .reclaim.timeoutMinutes' .claude/orchestration.json`
Expected: prints `owner/repo` then `120` (exit 0).

- [ ] **Step 5: Commit**

```bash
git add .claude/orchestration.json .gitignore
git commit -m "chore(orch): scaffold config and directories"
```

---

## Task 2: `lib.sh` shared helpers (TDD)

**Files:**
- Create: `scripts/orchestration/lib.sh`
- Test: `tests/orchestration/lib.bats`

- [ ] **Step 1: Write the failing test**

`tests/orchestration/lib.bats`:
```bash
#!/usr/bin/env bats

setup() {
  LIB="$BATS_TEST_DIRNAME/../../scripts/orchestration/lib.sh"
  export ORCH_CONFIG="$BATS_TEST_TMPDIR/orchestration.json"
  cat > "$ORCH_CONFIG" <<'JSON'
{ "repo":"o/r","bot":"botx","candidateN":3,"wipLimit":4,
  "reclaim":{"timeoutMinutes":120,"heartbeatMinutes":15},
  "commands":{"test":null,"build":null,"lint":null},
  "worktreeBaseDir":"../","project":{"number":null,"statusField":"Status"} }
JSON
}

@test "load_config exports expected vars" {
  run bash -c 'source "$0"; load_config; echo "$REPO|$BOT|$CANDIDATE_N|$WIP_LIMIT|$RECLAIM_TIMEOUT_MIN|$HEARTBEAT_MIN|$PROJECT_NUMBER"' "$LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "o/r|botx|3|4|120|15|null" ]
}

@test "load_config fails clearly when config missing" {
  export ORCH_CONFIG="$BATS_TEST_TMPDIR/nope.json"
  run bash -c 'source "$0"; load_config' "$LIB"
  [ "$status" -ne 0 ]
  [[ "$output" == *"config not found"* ]]
}

@test "claim_token sorts by time then is unique per process" {
  run bash -c 'source "$0"; load_config; claim_token' "$LIB"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z-botx- ]]
}

@test "iso_to_epoch round-trips a known timestamp" {
  run bash -c 'source "$0"; iso_to_epoch 1970-01-01T00:00:00Z' "$LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/orchestration/lib.bats`
Expected: FAIL (lib.sh does not exist).

- [ ] **Step 3: Write `scripts/orchestration/lib.sh`**

```bash
#!/usr/bin/env bash
# lib.sh — shared config + helpers. Source this; do not execute directly.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPT_DIR

log() { printf '[%s] %s\n' "$1" "${*:2}" >&2; }

load_config() {
  local cfg="${ORCH_CONFIG:-$SCRIPT_DIR/../../.claude/orchestration.json}"
  if [ ! -f "$cfg" ]; then log ERROR "config not found: $cfg"; return 1; fi
  REPO=$(jq -er '.repo' "$cfg")                       || { log ERROR "config.repo missing"; return 1; }
  BOT=$(jq -er '.bot' "$cfg")                         || { log ERROR "config.bot missing"; return 1; }
  CANDIDATE_N=$(jq -er '.candidateN' "$cfg")          || { log ERROR "config.candidateN missing"; return 1; }
  WIP_LIMIT=$(jq -er '.wipLimit' "$cfg")              || { log ERROR "config.wipLimit missing"; return 1; }
  RECLAIM_TIMEOUT_MIN=$(jq -er '.reclaim.timeoutMinutes' "$cfg") || { log ERROR "reclaim.timeoutMinutes missing"; return 1; }
  HEARTBEAT_MIN=$(jq -er '.reclaim.heartbeatMinutes' "$cfg")     || { log ERROR "reclaim.heartbeatMinutes missing"; return 1; }
  WORKTREE_BASE=$(jq -er '.worktreeBaseDir' "$cfg")   || { log ERROR "worktreeBaseDir missing"; return 1; }
  PROJECT_NUMBER=$(jq -r '.project.number // "null"' "$cfg")
  PROJECT_STATUS_FIELD=$(jq -er '.project.statusField' "$cfg")
  WORKER_ID="${BOT}-$(hostname -s 2>/dev/null || echo host)-$$"
  export REPO BOT CANDIDATE_N WIP_LIMIT RECLAIM_TIMEOUT_MIN HEARTBEAT_MIN WORKTREE_BASE PROJECT_NUMBER PROJECT_STATUS_FIELD WORKER_ID
}

# Token sorts by time first (fixed-width ISO8601), then worker id → lexicographic-min == earliest.
claim_token() { printf '%sZ-%s' "$(date -u +%Y-%m-%dT%H:%M:%S)" "$WORKER_ID"; }

now_epoch() { date -u +%s; }

# GNU date first, BSD date fallback (macOS).
iso_to_epoch() {
  date -u -d "$1" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s
}

gh_repo() { gh "$@" --repo "$REPO"; }

# project_sync <issue#> <statusValue> — no-op when PROJECT_NUMBER == "null".
project_sync() {
  local issue="$1" status="$2"
  [ "$PROJECT_NUMBER" = "null" ] && return 0
  local owner="${REPO%%/*}"
  local proj_id field_id opt_id item_id fl
  proj_id=$(gh project view "$PROJECT_NUMBER" --owner "$owner" --format json | jq -er '.id')
  fl=$(gh project field-list "$PROJECT_NUMBER" --owner "$owner" --format json)
  field_id=$(echo "$fl" | jq -er --arg n "$PROJECT_STATUS_FIELD" '.fields[] | select(.name==$n) | .id')
  opt_id=$(echo "$fl" | jq -er --arg n "$PROJECT_STATUS_FIELD" --arg v "$status" \
    '.fields[] | select(.name==$n) | .options[] | select(.name==$v) | .id')
  item_id=$(gh project item-list "$PROJECT_NUMBER" --owner "$owner" --format json \
    | jq -er --argjson num "$issue" '.items[] | select(.content.number==$num) | .id')
  gh project item-edit --id "$item_id" --project-id "$proj_id" --field-id "$field_id" --single-select-option-id "$opt_id"
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bats tests/orchestration/lib.bats`
Expected: 4 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/orchestration/lib.sh tests/orchestration/lib.bats
git commit -m "feat(orch): add lib.sh config loader and helpers"
```

---

## Task 3: `.github/labels.yml` + `bootstrap-labels.sh` (TDD)

**Files:**
- Create: `.github/labels.yml`
- Create: `scripts/orchestration/bootstrap-labels.sh`
- Test: `tests/orchestration/bootstrap-labels.bats`

- [ ] **Step 1: Write `.github/labels.yml`**

```yaml
- name: "status:triage"
  color: "ededed"
  description: "분류 대기"
- name: "status:agent-ready"
  color: "0e8a16"
  description: "에이전트 작업 가능 큐"
- name: "status:in-progress"
  color: "fbca04"
  description: "워커 작업 중 (락)"
- name: "status:in-review"
  color: "1d76db"
  description: "PR 리뷰 대기"
- name: "status:qa"
  color: "5319e7"
  description: "머지됨, QA 검증 대기"
- name: "status:done"
  color: "0e8a16"
  description: "완료"
- name: "status:blocked"
  color: "b60205"
  description: "사람 개입 필요"
```

- [ ] **Step 2: Write the failing test**

`tests/orchestration/bootstrap-labels.bats`:
```bash
#!/usr/bin/env bats

setup() {
  load helpers/common
  setup_gh_stub
  export ORCH_CONFIG="$BATS_TEST_TMPDIR/orchestration.json"
  printf '{"repo":"o/r","bot":"b","candidateN":1,"wipLimit":1,"reclaim":{"timeoutMinutes":1,"heartbeatMinutes":1},"commands":{"test":null,"build":null,"lint":null},"worktreeBaseDir":"../","project":{"number":null,"statusField":"Status"}}' > "$ORCH_CONFIG"
  SCRIPT="$BATS_TEST_DIRNAME/../../scripts/orchestration/bootstrap-labels.sh"
  LABELS="$BATS_TEST_DIRNAME/../../.github/labels.yml"
}

@test "creates all 7 labels via gh label create" {
  run bash "$SCRIPT" "$LABELS"
  [ "$status" -eq 0 ]
  run grep -c '^label create' "$GH_CALLS"
  [ "$output" -eq 7 ]
}

@test "passes name color and description for each label" {
  bash "$SCRIPT" "$LABELS"
  grep -q 'label create status:in-progress --color fbca04 --description' "$GH_CALLS"
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `bats tests/orchestration/bootstrap-labels.bats`
Expected: FAIL (script + stub helper missing — Task 4 adds the helper; if running before Task 4, this fails on `load helpers/common`). Run after Task 4 if needed; for now expect FAIL.

> Note: this task depends on the `common.bash` helper from Task 4. If executing strictly in order, do Task 4 first, then return here. The plan lists labels first because Task 4's stub is generic test infra.

- [ ] **Step 4: Write `scripts/orchestration/bootstrap-labels.sh`**

```bash
#!/usr/bin/env bash
# bootstrap-labels.sh <labels.yml> — idempotently create status labels.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$DIR/lib.sh"
load_config

labels_file="${1:-$DIR/../../.github/labels.yml}"
count=$(yq -o=json '. | length' "$labels_file")
for i in $(seq 0 $((count - 1))); do
  name=$(yq -r ".[$i].name" "$labels_file")
  color=$(yq -r ".[$i].color" "$labels_file")
  desc=$(yq -r ".[$i].description" "$labels_file")
  # --force makes it idempotent: create or update.
  gh label create "$name" --color "$color" --description "$desc" --force --repo "$REPO"
  log INFO "label ensured: $name"
done
```

- [ ] **Step 5: Run to verify it passes**

Run: `bats tests/orchestration/bootstrap-labels.bats`
Expected: 2 tests PASS.

- [ ] **Step 6: Commit**

```bash
git add .github/labels.yml scripts/orchestration/bootstrap-labels.sh tests/orchestration/bootstrap-labels.bats
git commit -m "feat(orch): add label bootstrap from labels.yml"
```

---

## Task 4: Test infrastructure — `gh` stub + bats helper

**Files:**
- Create: `tests/orchestration/helpers/gh-stub.sh`
- Create: `tests/orchestration/helpers/common.bash`

- [ ] **Step 1: Write `tests/orchestration/helpers/gh-stub.sh`**

```bash
#!/usr/bin/env bash
# Fake `gh` for bats. Logs each call (subcommand-first) to $GH_CALLS.
# For stdout-producing read commands, emits the next queued response file
# $GH_RESPONSES/<n> in call order. Exit code overridable via $GH_EXIT.
echo "$*" >> "$GH_CALLS"
case "${1:-} ${2:-}" in
  "issue list"|"issue view"|"pr view"|"pr list"|"project view"|"project field-list"|"project item-list"|"api "*|"api")
    idx_file="$GH_RESPONSES/.idx"
    n=$(( $(cat "$idx_file" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$idx_file"
    [ -f "$GH_RESPONSES/$n" ] && cat "$GH_RESPONSES/$n" || true
    ;;
esac
exit "${GH_EXIT:-0}"
```

- [ ] **Step 2: Write `tests/orchestration/helpers/common.bash`**

```bash
#!/usr/bin/env bash
# Shared bats helpers.

setup_gh_stub() {
  export GH_BIN="$BATS_TEST_TMPDIR/bin"
  export GH_CALLS="$BATS_TEST_TMPDIR/gh-calls.log"
  export GH_RESPONSES="$BATS_TEST_TMPDIR/gh-responses"
  mkdir -p "$GH_BIN" "$GH_RESPONSES"
  : > "$GH_CALLS"
  cp "$BATS_TEST_DIRNAME/helpers/gh-stub.sh" "$GH_BIN/gh"
  chmod +x "$GH_BIN/gh"
  export PATH="$GH_BIN:$PATH"
}

# queue_response <json-or-text> — enqueue stdout for the next read-style gh call.
queue_response() {
  local n
  n=$(( $(ls "$GH_RESPONSES" 2>/dev/null | grep -c '^[0-9]') + 1 ))
  printf '%s' "$1" > "$GH_RESPONSES/$n"
}
```

> `bats` `load helpers/common` resolves `common.bash` relative to the test file's dir; `$BATS_TEST_DIRNAME` is `tests/orchestration`, so `helpers/gh-stub.sh` resolves correctly.

- [ ] **Step 3: Smoke-test the stub**

`tests/orchestration/stub.bats`:
```bash
#!/usr/bin/env bats
setup() { load helpers/common; setup_gh_stub; }

@test "stub logs calls and returns queued responses in order" {
  queue_response '[{"number":1}]'
  queue_response '[{"number":2}]'
  run gh issue list --label x
  [ "$output" = '[{"number":1}]' ]
  run gh issue list --label y
  [ "$output" = '[{"number":2}]' ]
  grep -q 'issue list --label x' "$GH_CALLS"
}

@test "write commands produce no stdout" {
  run gh issue edit 5 --add-label foo
  [ -z "$output" ]
  grep -q 'issue edit 5 --add-label foo' "$GH_CALLS"
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bats tests/orchestration/stub.bats`
Expected: 2 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add tests/orchestration/helpers/gh-stub.sh tests/orchestration/helpers/common.bash tests/orchestration/stub.bats
git commit -m "test(orch): add gh stub and bats helpers"
```

---

## Task 5: `claim.sh` atomic claim (TDD, adversarial)

**Files:**
- Create: `scripts/orchestration/claim.sh`
- Test: `tests/orchestration/claim.bats`

- [ ] **Step 1: Write the failing tests**

`tests/orchestration/claim.bats`:
```bash
#!/usr/bin/env bats

setup() {
  load helpers/common
  setup_gh_stub
  export ORCH_CONFIG="$BATS_TEST_TMPDIR/orchestration.json"
  printf '{"repo":"o/r","bot":"botx","candidateN":3,"wipLimit":5,"reclaim":{"timeoutMinutes":120,"heartbeatMinutes":15},"commands":{"test":null,"build":null,"lint":null},"worktreeBaseDir":"../","project":{"number":null,"statusField":"Status"}}' > "$ORCH_CONFIG"
  export CLAIM_BACKOFF_SECS=0   # make tests fast
  SCRIPT="$BATS_TEST_DIRNAME/../../scripts/orchestration/claim.sh"
}

@test "no candidates → exit 1" {
  queue_response '[]'                 # issue list
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "clean claim → exit 0, prints issue number, writes label+assignee+claim comment" {
  queue_response '[{"number":42,"createdAt":"2026-01-01T00:00:00Z"}]'   # list
  # re-read after claim: in-progress present, single bot assignee, one claim token.
  # Pin our token so the re-read visibility check matches on the first pass.
  export CLAIM_TOKEN_OVERRIDE='2026-02-01T00:00:00Z-botx-h-1'
  queue_response '{"labels":[{"name":"status:in-progress"}],"assignees":[{"login":"botx"}],"comments":[{"id":1,"author":{"login":"botx"},"body":"claim: 2026-02-01T00:00:00Z-botx-h-1"}]}'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "42" ]
  grep -q 'issue edit 42 --add-label status:in-progress --remove-label status:agent-ready' "$GH_CALLS"
  grep -q 'issue edit 42 --add-assignee botx' "$GH_CALLS"
  grep -q 'issue comment 42 --body claim: ' "$GH_CALLS"
}

@test "two distinct claim tokens → lexicographic-min wins; if ours is larger we lose (exit 2) and delete our comment" {
  queue_response '[{"number":7,"createdAt":"2026-01-01T00:00:00Z"}]'    # list
  # re-read shows TWO claim tokens; the smaller one belongs to another process
  queue_response '{"labels":[{"name":"status:in-progress"}],"assignees":[{"login":"botx"}],"comments":[
    {"id":10,"author":{"login":"botx"},"body":"claim: 2026-01-01T00:00:00Z-botx-h-999"},
    {"id":11,"author":{"login":"botx"},"body":"claim: 2030-01-01T00:00:00Z-botx-h-1000"}]}'
  # Force our token to be the LARGER one so we lose deterministically:
  export CLAIM_TOKEN_OVERRIDE='2030-01-01T00:00:00Z-botx-h-1000'
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
  grep -q 'api --method DELETE' "$GH_CALLS"     # deleted our own claim comment
}

@test "propagation lag: comment not yet visible → backoff retry then succeed" {
  queue_response '[{"number":9,"createdAt":"2026-01-01T00:00:00Z"}]'    # list
  queue_response '{"labels":[{"name":"status:in-progress"}],"assignees":[{"login":"botx"}],"comments":[]}'  # 1st re-read: empty
  queue_response '{"labels":[{"name":"status:in-progress"}],"assignees":[{"login":"botx"}],"comments":[{"id":1,"author":{"login":"botx"},"body":"claim: 2026-02-01T00:00:00Z-botx-h-1"}]}'  # 2nd re-read
  export CLAIM_TOKEN_OVERRIDE='2026-02-01T00:00:00Z-botx-h-1'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "9" ]
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/orchestration/claim.bats`
Expected: FAIL (claim.sh missing).

- [ ] **Step 3: Write `scripts/orchestration/claim.sh`**

```bash
#!/usr/bin/env bash
# claim.sh — atomically claim one status:agent-ready issue.
# exit 0 (prints issue#) | 1 no candidates | 2 lost race.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$DIR/lib.sh"
load_config

BACKOFF="${CLAIM_BACKOFF_SECS:-3}"
RETRIES="${CLAIM_RETRIES:-3}"

# 1. candidate selection: top-N by createdAt, random pick
candidates=$(gh issue list --label status:agent-ready --json number,createdAt --limit 1000 --repo "$REPO")
n=$(echo "$candidates" | jq 'length')
[ "$n" -eq 0 ] && { log INFO "no agent-ready candidates"; exit 1; }
top=$(echo "$candidates" | jq --argjson k "$CANDIDATE_N" 'sort_by(.createdAt)[:$k] | map(.number)')
topn=$(echo "$top" | jq 'length')
pick_idx=$(( RANDOM % topn ))
issue=$(echo "$top" | jq -r ".[$pick_idx]")

# 2. mark in-progress + assignee + claim comment
token="${CLAIM_TOKEN_OVERRIDE:-$(claim_token)}"
gh issue edit "$issue" --add-label status:in-progress --remove-label status:agent-ready --repo "$REPO"
gh issue edit "$issue" --add-assignee "$BOT" --repo "$REPO"
gh issue comment "$issue" --body "claim: $token" --repo "$REPO"

# 3. re-read with backoff until our claim comment is visible
view=""
for _ in $(seq 1 "$RETRIES"); do
  sleep "$BACKOFF"
  view=$(gh issue view "$issue" --json labels,assignees,comments --repo "$REPO")
  if echo "$view" | jq -e --arg t "$token" \
      '.comments[] | select(.body == ("claim: " + $t))' >/dev/null; then
    break
  fi
done

# ensure in-progress is present (re-add if transient race removed it)
if ! echo "$view" | jq -e '.labels[] | select(.name=="status:in-progress")' >/dev/null; then
  gh issue edit "$issue" --add-label status:in-progress --repo "$REPO"
fi

# 4. tie-break on distinct claim tokens (single bot ⇒ assignee can't discriminate)
tokens=$(echo "$view" | jq -r '.comments[] | select(.body|startswith("claim: ")) | .body | sub("^claim: ";"")' | sort -u)
ntok=$(echo "$tokens" | grep -c . || true)
if [ "$ntok" -ge 2 ]; then
  winner=$(echo "$tokens" | sort | head -n1)
  if [ "$winner" != "$token" ]; then
    # we lost: delete our own claim comment, release assignee, return 2
    cid=$(echo "$view" | jq -r --arg t "$token" '.comments[] | select(.body==("claim: "+$t)) | .id' | head -n1)
    [ -n "$cid" ] && gh api --method DELETE "/repos/$REPO/issues/comments/$cid" >/dev/null 2>&1 || true
    gh issue edit "$issue" --remove-assignee "$BOT" --repo "$REPO" || true
    log INFO "lost claim race on #$issue (winner=$winner)"
    exit 2
  fi
fi

echo "$issue"
```

- [ ] **Step 4: Run to verify it passes**

Run: `bats tests/orchestration/claim.bats`
Expected: 4 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/orchestration/claim.sh tests/orchestration/claim.bats
git commit -m "feat(orch): add atomic claim with token tie-break and backoff"
```

---

## Task 6: `heartbeat.sh` (TDD)

**Files:**
- Create: `scripts/orchestration/heartbeat.sh`
- Test: `tests/orchestration/heartbeat.bats`

- [ ] **Step 1: Write the failing test**

`tests/orchestration/heartbeat.bats`:
```bash
#!/usr/bin/env bats

setup() {
  load helpers/common
  setup_gh_stub
  export ORCH_CONFIG="$BATS_TEST_TMPDIR/orchestration.json"
  printf '{"repo":"o/r","bot":"botx","candidateN":1,"wipLimit":1,"reclaim":{"timeoutMinutes":1,"heartbeatMinutes":1},"commands":{"test":null,"build":null,"lint":null},"worktreeBaseDir":"../","project":{"number":null,"statusField":"Status"}}' > "$ORCH_CONFIG"
  SCRIPT="$BATS_TEST_DIRNAME/../../scripts/orchestration/heartbeat.sh"
}

@test "edits the existing claim comment by id (PATCH), not --edit-last" {
  queue_response '{"comments":[{"id":555,"author":{"login":"botx"},"body":"claim: old-token"},{"id":556,"author":{"login":"botx"},"body":"PR: https://x"}]}'
  run bash "$SCRIPT" 42
  [ "$status" -eq 0 ]
  grep -q 'api --method PATCH /repos/o/r/issues/comments/555' "$GH_CALLS"
  ! grep -q -- '--edit-last' "$GH_CALLS"
}

@test "no claim comment → exit 1" {
  queue_response '{"comments":[{"id":1,"author":{"login":"botx"},"body":"PR: x"}]}'
  run bash "$SCRIPT" 42
  [ "$status" -eq 1 ]
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/orchestration/heartbeat.bats`
Expected: FAIL.

- [ ] **Step 3: Write `scripts/orchestration/heartbeat.sh`**

```bash
#!/usr/bin/env bash
# heartbeat.sh <issue#> — refresh the claim: comment's timestamp in place.
# exit 0 ok | 1 api fail / no claim comment.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$DIR/lib.sh"
load_config

issue="${1:?issue number required}"
view=$(gh issue view "$issue" --json comments --repo "$REPO") || { log ERROR "view failed"; exit 1; }
cid=$(echo "$view" | jq -r --arg b "$BOT" \
  'first(.comments[] | select(.author.login==$b and (.body|startswith("claim: "))) | .id) // empty')
[ -z "$cid" ] && { log ERROR "no claim comment on #$issue"; exit 1; }
token="${CLAIM_TOKEN_OVERRIDE:-$(claim_token)}"
gh api --method PATCH "/repos/$REPO/issues/comments/$cid" -f body="claim: $token" >/dev/null \
  || { log ERROR "patch failed"; exit 1; }
log INFO "heartbeat #$issue"
```

- [ ] **Step 4: Run to verify it passes**

Run: `bats tests/orchestration/heartbeat.bats`
Expected: 2 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/orchestration/heartbeat.sh tests/orchestration/heartbeat.bats
git commit -m "feat(orch): add heartbeat editing claim comment by id"
```

---

## Task 7: `reclaim.sh` (TDD)

**Files:**
- Create: `scripts/orchestration/reclaim.sh`
- Test: `tests/orchestration/reclaim.bats`

- [ ] **Step 1: Write the failing tests**

`tests/orchestration/reclaim.bats`:
```bash
#!/usr/bin/env bats

setup() {
  load helpers/common
  setup_gh_stub
  export ORCH_CONFIG="$BATS_TEST_TMPDIR/orchestration.json"
  printf '{"repo":"o/r","bot":"botx","candidateN":1,"wipLimit":1,"reclaim":{"timeoutMinutes":120,"heartbeatMinutes":15},"commands":{"test":null,"build":null,"lint":null},"worktreeBaseDir":"../","project":{"number":null,"statusField":"Status"}}' > "$ORCH_CONFIG"
  SCRIPT="$BATS_TEST_DIRNAME/../../scripts/orchestration/reclaim.sh"
}

@test "fresh heartbeat → not reclaimed" {
  queue_response '[{"number":3}]'                                   # in-progress list
  recent=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  queue_response "{\"comments\":[{\"author\":{\"login\":\"botx\"},\"body\":\"claim: ${recent}-botx-h-1\"}]}"  # view #3
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  ! grep -q 'issue edit 3 --add-label status:agent-ready' "$GH_CALLS"
}

@test "unresolved rework → skipped regardless of age" {
  queue_response '[{"number":4}]'
  queue_response '{"comments":[{"author":{"login":"botx"},"body":"claim: 2000-01-01T00:00:00Z-botx-h-1"},{"author":{"login":"botx"},"body":"rework-requested: fix tests"}]}'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  ! grep -q 'issue edit 4' "$GH_CALLS"
}

@test "timed-out with open PR → blocked (not agent-ready)" {
  queue_response '[{"number":5}]'
  queue_response '{"comments":[{"author":{"login":"botx"},"body":"claim: 2000-01-01T00:00:00Z-botx-h-1"}]}'  # view comments
  queue_response '[{"number":99,"state":"OPEN"}]'                   # pr list --head issue-5
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q 'issue edit 5 --add-label status:blocked' "$GH_CALLS"
  ! grep -q 'issue edit 5 --add-label status:agent-ready' "$GH_CALLS"
}

@test "timed-out with no PR → reset to agent-ready, assignee removed" {
  queue_response '[{"number":6}]'
  queue_response '{"comments":[{"author":{"login":"botx"},"body":"claim: 2000-01-01T00:00:00Z-botx-h-1"}]}'
  queue_response '[]'                                              # pr list empty
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q 'issue edit 6 --add-label status:agent-ready --remove-label status:in-progress' "$GH_CALLS"
  grep -q 'issue edit 6 --remove-assignee botx' "$GH_CALLS"
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/orchestration/reclaim.bats`
Expected: FAIL.

- [ ] **Step 3: Write `scripts/orchestration/reclaim.sh`**

```bash
#!/usr/bin/env bash
# reclaim.sh — revert orphaned status:in-progress issues. exit 0 swept | 1 api fail.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$DIR/lib.sh"
load_config

list=$(gh issue list --label status:in-progress --json number --limit 1000 --repo "$REPO") || exit 1
now=$(now_epoch)
timeout_secs=$(( RECLAIM_TIMEOUT_MIN * 60 ))

echo "$list" | jq -r '.[].number' | while read -r issue; do
  [ -z "$issue" ] && continue
  view=$(gh issue view "$issue" --json comments --repo "$REPO") || { log WARN "view #$issue failed"; continue; }

  # unresolved rework? (latest rework-requested with no later rework-resolved) → skip
  unresolved=$(echo "$view" | jq -r '
    [.comments[] | select(.body|startswith("rework-requested:") or startswith("rework-resolved:"))] as $m
    | ($m | length) as $len
    | if $len==0 then "no" else (if ($m[($len-1)].body|startswith("rework-requested:")) then "yes" else "no" end) end')
  if [ "$unresolved" = "yes" ]; then log INFO "#$issue unresolved rework, skip"; continue; fi

  token=$(echo "$view" | jq -r 'first(.comments[] | select(.body|startswith("claim: ")) | .body) // empty' | sed 's/^claim: //')
  [ -z "$token" ] && { log WARN "#$issue no claim token, skip"; continue; }
  iso="${token%%Z-*}Z"
  tepoch=$(iso_to_epoch "$iso" 2>/dev/null || echo 0)
  [ $(( now - tepoch )) -le "$timeout_secs" ] && continue   # still alive

  # timed out: check for open PR on branch issue-<n>
  prs=$(gh pr list --head "issue-$issue" --state open --json number --repo "$REPO" || echo '[]')
  if [ "$(echo "$prs" | jq 'length')" -gt 0 ]; then
    pr=$(echo "$prs" | jq -r '.[0].number')
    gh issue edit "$issue" --add-label status:blocked --remove-label status:in-progress --repo "$REPO"
    gh issue comment "$issue" --body "reclaimed: orphan lock, PR #$pr 존재 — 사람 확인 필요" --repo "$REPO"
    log INFO "#$issue → blocked (open PR #$pr)"
  else
    gh issue edit "$issue" --add-label status:agent-ready --remove-label status:in-progress --repo "$REPO"
    gh issue edit "$issue" --remove-assignee "$BOT" --repo "$REPO"
    gh issue comment "$issue" --body "reclaimed: orphan lock" --repo "$REPO"
    log INFO "#$issue → agent-ready"
  fi
done
```

- [ ] **Step 4: Run to verify it passes**

Run: `bats tests/orchestration/reclaim.bats`
Expected: 4 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/orchestration/reclaim.sh tests/orchestration/reclaim.bats
git commit -m "feat(orch): add orphan-lock reclaim with rework-skip and PR guard"
```

---

## Task 8: `wip-check.sh` (TDD)

**Files:**
- Create: `scripts/orchestration/wip-check.sh`
- Test: `tests/orchestration/wip-check.bats`

- [ ] **Step 1: Write the failing tests**

`tests/orchestration/wip-check.bats`:
```bash
#!/usr/bin/env bats

setup() {
  load helpers/common
  setup_gh_stub
  export ORCH_CONFIG="$BATS_TEST_TMPDIR/orchestration.json"
  printf '{"repo":"o/r","bot":"botx","candidateN":1,"wipLimit":5,"reclaim":{"timeoutMinutes":1,"heartbeatMinutes":1},"commands":{"test":null,"build":null,"lint":null},"worktreeBaseDir":"../","project":{"number":null,"statusField":"Status"}}' > "$ORCH_CONFIG"
  SCRIPT="$BATS_TEST_DIRNAME/../../scripts/orchestration/wip-check.sh"
}

@test "below limit → OK exit 0" {
  queue_response '[{"number":1},{"number":2}]'   # in-review = 2
  queue_response '[{"number":3}]'                # qa = 1  (total 3 < 5)
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "at limit → EXCEED exit 1" {
  queue_response '[{"number":1},{"number":2},{"number":3}]'  # 3
  queue_response '[{"number":4},{"number":5}]'               # 2 (total 5 == limit)
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [ "$output" = "EXCEED" ]
}

@test "uses --limit 1000 to avoid default-30 undercount" {
  queue_response '[]'; queue_response '[]'
  bash "$SCRIPT" || true
  grep -q 'issue list --label status:in-review --limit 1000' "$GH_CALLS"
  grep -q 'issue list --label status:qa --limit 1000' "$GH_CALLS"
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/orchestration/wip-check.bats`
Expected: FAIL.

- [ ] **Step 3: Write `scripts/orchestration/wip-check.sh`**

```bash
#!/usr/bin/env bash
# wip-check.sh — sum of in-review + qa vs WIP_LIMIT.
# stdout OK|EXCEED. exit 0 OK | 1 EXCEED | 2 api fail.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$DIR/lib.sh"
load_config

count() {
  gh issue list --label "$1" --limit 1000 --json number --repo "$REPO" | jq 'length'
}
ir=$(count status:in-review) || exit 2
qa=$(count status:qa) || exit 2
total=$(( ir + qa ))
if [ "$total" -ge "$WIP_LIMIT" ]; then echo EXCEED; exit 1; fi
echo OK; exit 0
```

- [ ] **Step 4: Run to verify it passes**

Run: `bats tests/orchestration/wip-check.bats`
Expected: 3 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/orchestration/wip-check.sh tests/orchestration/wip-check.bats
git commit -m "feat(orch): add WIP gate over in-review+qa"
```

---

## Task 9: `detect-test-cmd.sh` (TDD)

**Files:**
- Create: `scripts/orchestration/detect-test-cmd.sh`
- Test: `tests/orchestration/detect-test-cmd.bats`

- [ ] **Step 1: Write the failing tests**

`tests/orchestration/detect-test-cmd.bats`:
```bash
#!/usr/bin/env bats

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../scripts/orchestration/detect-test-cmd.sh"
  WORK="$BATS_TEST_TMPDIR/proj"; mkdir -p "$WORK"
  export ORCH_CONFIG="$WORK/.claude/orchestration.json"; mkdir -p "$WORK/.claude"
}

cfg() { printf '%s' "$1" > "$ORCH_CONFIG"; }

@test "config override wins" {
  cfg '{"repo":"o/r","bot":"b","candidateN":1,"wipLimit":1,"reclaim":{"timeoutMinutes":1,"heartbeatMinutes":1},"commands":{"test":"make check","build":null,"lint":null},"worktreeBaseDir":"../","project":{"number":null,"statusField":"S"}}'
  run bash -c "cd '$WORK' && '$SCRIPT' test"
  [ "$output" = "make check" ]
}

@test "auto-detect package.json test script" {
  cfg '{"repo":"o/r","bot":"b","candidateN":1,"wipLimit":1,"reclaim":{"timeoutMinutes":1,"heartbeatMinutes":1},"commands":{"test":null,"build":null,"lint":null},"worktreeBaseDir":"../","project":{"number":null,"statusField":"S"}}'
  printf '{"scripts":{"test":"jest"}}' > "$WORK/package.json"
  run bash -c "cd '$WORK' && '$SCRIPT' test"
  [ "$output" = "npm test" ]
}

@test "auto-detect Makefile target" {
  cfg '{"repo":"o/r","bot":"b","candidateN":1,"wipLimit":1,"reclaim":{"timeoutMinutes":1,"heartbeatMinutes":1},"commands":{"test":null,"build":null,"lint":null},"worktreeBaseDir":"../","project":{"number":null,"statusField":"S"}}'
  printf 'test:\n\techo hi\n' > "$WORK/Makefile"
  run bash -c "cd '$WORK' && '$SCRIPT' test"
  [ "$output" = "make test" ]
}

@test "nothing detected → empty output, exit 0" {
  cfg '{"repo":"o/r","bot":"b","candidateN":1,"wipLimit":1,"reclaim":{"timeoutMinutes":1,"heartbeatMinutes":1},"commands":{"test":null,"build":null,"lint":null},"worktreeBaseDir":"../","project":{"number":null,"statusField":"S"}}'
  run bash -c "cd '$WORK' && '$SCRIPT' test"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/orchestration/detect-test-cmd.bats`
Expected: FAIL.

- [ ] **Step 3: Write `scripts/orchestration/detect-test-cmd.sh`**

```bash
#!/usr/bin/env bash
# detect-test-cmd.sh <test|build|lint> — print the command (config override or auto-detect).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$DIR/lib.sh"
load_config

kind="${1:?kind required: test|build|lint}"
cfg="${ORCH_CONFIG:-$SCRIPT_DIR/../../.claude/orchestration.json}"

# 1. config override
override=$(jq -r --arg k "$kind" '.commands[$k] // empty' "$cfg")
[ -n "$override" ] && { echo "$override"; exit 0; }

# 2. package.json scripts.<kind>
if [ -f package.json ] && jq -e --arg k "$kind" '.scripts[$k] // empty' package.json >/dev/null 2>&1; then
  echo "npm $kind"; exit 0
fi
# 3. Makefile <kind>: target
if [ -f Makefile ] && grep -qE "^${kind}:" Makefile; then
  echo "make $kind"; exit 0
fi
# 4. python: pytest for test
if [ "$kind" = "test" ] && { [ -f pyproject.toml ] || [ -f pytest.ini ] || [ -f tox.ini ]; }; then
  echo "pytest"; exit 0
fi

log WARN "no $kind command detected"
echo ""   # empty → caller (QA) treats as blocked reason
exit 0
```

- [ ] **Step 4: Run to verify it passes**

Run: `bats tests/orchestration/detect-test-cmd.bats`
Expected: 4 tests PASS.

- [ ] **Step 5: Run the full suite + commit**

Run: `bats tests/orchestration/`
Expected: all PASS.
```bash
git add scripts/orchestration/detect-test-cmd.sh tests/orchestration/detect-test-cmd.bats
git commit -m "feat(orch): add test/build/lint command detection"
```

---

## Task 10: `/work-issue` command (walking skeleton)

**Files:**
- Create: `.claude/commands/work-issue.md`

> Command files are prompts, not unit-testable. Verification = the manual integration checklist (Task 14) and a shellcheck pass on embedded snippets.

- [ ] **Step 1: Write `.claude/commands/work-issue.md`**

````markdown
---
description: Coder lane — claim an agent-ready issue, implement, open a PR, move to in-review.
---

You are the **Coder** lane. Run from the **main repo root**. All orchestration scripts live at `scripts/orchestration/`. Config: `.claude/orchestration.json`.

Do exactly this, stopping at the first step that says to stop:

1. **Resume check.** Find an unresolved-rework issue assigned to the bot:
   ```bash
   gh issue list --label status:in-progress --assignee "$(jq -r .bot .claude/orchestration.json)" \
     --json number --repo "$(jq -r .repo .claude/orchestration.json)"
   ```
   For each, read its comments; an issue is **unresolved rework** if its latest `rework-requested:`/`rework-resolved:` marker is a `rework-requested:`. If one exists, set `ISSUE` to it, reuse its `wt-issue-<ISSUE>` worktree, and **skip to step 4** (after work, add a new `rework-resolved:` comment).
2. **WIP gate.** Run `scripts/orchestration/wip-check.sh`. If it prints `EXCEED` (exit 1), **stop this turn** (do nothing; the next /loop tick re-checks).
3. **Claim.** Run `ISSUE=$(scripts/orchestration/claim.sh)`. Exit 1 → queue empty, **stop**. Exit 2 → lost race, **stop** (next tick retries). Exit 0 → `ISSUE` holds the number; `git worktree add "$(jq -r .worktreeBaseDir .claude/orchestration.json)/wt-issue-$ISSUE" -b "issue-$ISSUE"`.
4. **Heartbeat.** Before any step that may exceed the heartbeat interval (large test/build), start a background heartbeat and stop it after:
   ```bash
   HB_MIN=$(jq -r .reclaim.heartbeatMinutes .claude/orchestration.json)
   ( while sleep "$((HB_MIN*60))"; do scripts/orchestration/heartbeat.sh "$ISSUE"; done ) &
   echo $! > "${TMPDIR:-/tmp}/hb-$ISSUE.pid"
   # ... run the long command ...
   kill "$(cat "${TMPDIR:-/tmp}/hb-$ISSUE.pid")" 2>/dev/null || true
   ```
   For short steps, just call `scripts/orchestration/heartbeat.sh "$ISSUE"` between them.
5. **Implement** inside `wt-issue-$ISSUE`: read the issue, make the change. Get test/build commands via `scripts/orchestration/detect-test-cmd.sh test` and `... build`; run them and surface results.
6. **Commit** with Conventional Commits (see `CLAUDE.md`): `type(scope): subject`, body explains *what & why*, footer `Closes #$ISSUE`.
7. **PR.** `gh pr create --head "issue-$ISSUE" --base main --title "..." --body "...\n\nCloses #$ISSUE"`. Add a comment to the issue linking the PR. (On resume, push to the existing PR instead.)
8. **Project sync.** `source scripts/orchestration/lib.sh && load_config && project_sync "$ISSUE" "In Review"`.
9. **Transition.** `gh issue edit "$ISSUE" --add-label status:in-review --remove-label status:in-progress`. Stop any background heartbeat. If this was a resume, add `gh issue comment "$ISSUE" --body "rework-resolved:"`.

Never merge or approve a PR yourself — that is a human action (see SETUP §branch protection).
````

- [ ] **Step 2: Shellcheck the embedded snippets (sanity)**

Run: `awk '/```bash/{f=1;next}/```/{f=0}f' .claude/commands/work-issue.md > "$TMPDIR/wi.sh" && shellcheck -S warning "$TMPDIR/wi.sh" || true`
Expected: no fatal syntax errors (warnings about undefined `$ISSUE` across blocks are acceptable — blocks are illustrative).

- [ ] **Step 3: Commit**

```bash
git add .claude/commands/work-issue.md
git commit -m "feat(orch): add /work-issue Coder lane command"
```

---

## Task 11: `/triage` command

**Files:**
- Create: `.claude/commands/triage.md`

- [ ] **Step 1: Write `.claude/commands/triage.md`**

````markdown
---
description: Triager lane — sweep orphan locks, then classify triage issues.
---

You are the **Triager** lane. Run from the main repo root.

1. **Reclaim sweep.** Run `scripts/orchestration/reclaim.sh` (reverts orphaned in-progress locks; skips unresolved-rework and open-PR cases).
2. **Read triage queue.** `gh issue list --label status:triage --repo "$(jq -r .repo .claude/orchestration.json)"`.
3. For each issue: read it, add area/priority labels as appropriate.
4. If actionable: `gh issue edit <n> --add-label status:agent-ready --remove-label status:triage`. If ambiguous: post a clarifying question comment and `gh issue edit <n> --add-label status:blocked --remove-label status:triage`.
````

- [ ] **Step 2: Commit**

```bash
git add .claude/commands/triage.md
git commit -m "feat(orch): add /triage Triager lane command"
```

---

## Task 12: `/review-queue` command

**Files:**
- Create: `.claude/commands/review-queue.md`

- [ ] **Step 1: Write `.claude/commands/review-queue.md`**

````markdown
---
description: Reviewer lane — review in-review PRs; request human merge or send back for rework.
---

You are the **Reviewer** lane. Run from the main repo root. You **never** merge or approve PRs (human-in-the-loop, enforced by branch protection).

For each issue labelled `status:in-review` (find its PR via branch `issue-<n>` or the issue's PR link):

1. Read the PR diff; leave inline review comments.
2. **If it meets the bar:** comment requesting a human reviewer approve & merge. Do not approve. Then poll merge state:
   ```bash
   gh pr view <pr> --json state,mergedAt --repo "$REPO"
   ```
   When `mergedAt` is set: `gh issue edit <n> --add-label status:qa --remove-label status:in-review`; `project_sync <n> "QA"` (source lib.sh first); `git worktree remove "$WORKTREE_BASE/wt-issue-<n>"`.
3. **If changes are needed:** post `gh issue comment <n> --body "rework-requested: <reasons>"`, then `gh issue edit <n> --add-label status:in-progress --remove-label status:in-review`. **Keep the bot assignee and do NOT remove the worktree** — the Coder's resume path (work-issue step 1) picks it up. `project_sync <n> "In Progress"`.
````

- [ ] **Step 2: Commit**

```bash
git add .claude/commands/review-queue.md
git commit -m "feat(orch): add /review-queue Reviewer lane command"
```

---

## Task 13: `/qa-check` command

**Files:**
- Create: `.claude/commands/qa-check.md`

- [ ] **Step 1: Write `.claude/commands/qa-check.md`**

````markdown
---
description: QA lane — verify merged work; pass→done, fail→rework or block.
---

You are the **QA** lane, intended to run under `/goal`. Run from the main repo root.

For each issue labelled `status:qa`:

1. Get commands via `scripts/orchestration/detect-test-cmd.sh test` (and a regression run if applicable). **Run them and surface the full results in your output** — the /goal evaluator only sees what you write, not tool calls.
2. **Pass:** `gh issue edit <n> --add-label status:done --remove-label status:qa`; `project_sync <n> "Done"` (source lib.sh first); clean up the worktree if present.
3. **Fail — rework routing.** Read the current max `qa-fail-count: <N>` from comments; let `M = N + 1`; post `gh issue comment <n> --body "qa-fail-count: $M"`.
   - **M == 1:** create a regression issue (`gh issue create ... ` then label it `status:triage`); on the original post `gh issue comment <n> --body "rework-requested: QA 실패 — <summary>"` and `gh issue edit <n> --add-label status:in-progress --remove-label status:qa`.
   - **M >= 2:** `gh issue edit <n> --add-label status:blocked --remove-label status:qa` (route to a human).

Recommended `/goal` wrapper (measurable end-state + turn cap), following PRD §3.4:
> `/goal status:qa 큐가 빌 때까지 각 이슈를 검증한다. 완료 조건: \`gh issue list --label status:qa\` 가 빈 배열. 각 이슈는 위 규칙대로 done/in-progress/blocked로 전이하고 테스트 결과를 출력에 포함한다. 30턴 후에도 미완이면 남은 이슈를 보고하고 멈춘다.`
````

- [ ] **Step 2: Commit**

```bash
git add .claude/commands/qa-check.md
git commit -m "feat(orch): add /qa-check QA lane command"
```

---

## Task 14: Setup docs, issue template, CLAUDE.md, loop.md

**Files:**
- Create: `.github/ISSUE_TEMPLATE/task.yml`
- Create: `CLAUDE.md`
- Create: `docs/SETUP.md`
- Create: `.claude/loop.md`

- [ ] **Step 1: Write `.github/ISSUE_TEMPLATE/task.yml`**

```yaml
name: Task
description: A unit of work for the agent orchestration pipeline
labels: ["status:triage"]
body:
  - type: textarea
    id: what
    attributes:
      label: What needs doing
      description: Describe the task and the desired outcome.
    validations:
      required: true
  - type: textarea
    id: context
    attributes:
      label: Context / acceptance criteria
      description: Links, constraints, how we'll know it's done.
```

- [ ] **Step 2: Write `CLAUDE.md`**

```markdown
# Repo conventions

## Commits (Conventional Commits — required)
Format: `type(scope): subject`
- `type` ∈ feat, fix, docs, refactor, test, chore, perf, build, ci.
- Body explains **what changed and why** (not "수정했습니다").
- Footer references the issue: `Closes #<n>`.

## Branches / worktrees
- One issue → branch `issue-<n>` → worktree `../wt-issue-<n>`.
- Never force-push or delete another worker's `wt-issue-*` branch.

## Merge gate
- Agents never approve or merge PRs. A human reviews and merges (branch protection enforces this).
```

- [ ] **Step 3: Write `docs/SETUP.md`**

```markdown
# Orchestration v1 — one-time setup

## Prerequisites
`gh`, `git`, `jq`, `yq`, `bats` (for tests). Verify: `command -v gh jq yq git bats`.

## Steps
1. **Bot account + Fine-grained PAT.** Permissions on the target repo only: Contents RW, Pull requests RW, Issues RW, Projects RW. Expiry 90d. Export `GH_TOKEN=github_pat_...` (do not use `--with-token`). Use HTTPS (`gh auth` over ssh breaks fine-grained tokens).
2. **Add the bot as a collaborator** on the target repo.
3. **Edit `.claude/orchestration.json`**: set `repo`, `bot`, and (optionally) `project.number`.
4. **Bootstrap labels:** `scripts/orchestration/bootstrap-labels.sh .github/labels.yml`.
5. **(Optional) GitHub Project:** create it, set `project.number`; otherwise leave `null` (sync becomes a no-op).
6. **Branch protection on `main`:** require 1 human review (or CODEOWNERS), no force-push, no direct push, **include administrators**, restrict review dismissal. Bot token must **not** be admin.
7. **Issue template** is already at `.github/ISSUE_TEMPLATE/task.yml` (auto-labels new issues `status:triage`).

## Run the lanes (separate terminals)
- Triager: `/loop 10m /triage`
- Coder:   `/loop /work-issue`
- Reviewer:`/loop 5m /review-queue`
- QA:      `/goal` wrapping `/qa-check` (see `.claude/commands/qa-check.md`)

## Integration smoke test (manual)
1. Open an issue (gets `status:triage`).
2. Run `/triage` once → issue becomes `status:agent-ready`.
3. Run `/work-issue` once → issue `status:in-progress` then `status:in-review` with a PR.
4. Approve & merge the PR as a human → run `/review-queue` → issue `status:qa`.
5. Run `/qa-check` → issue `status:done` (or rework/blocked on failure).

## Known residual risks
- Bot token retains Projects:write (broader blast radius) — accepted trade-off for live board sync.
- Single bot identity → self-approval is blocked only by branch protection, not token separation.
- A bot with Contents:write can force-push/delete non-`main` branches.
```

- [ ] **Step 4: Write `.claude/loop.md`**

```markdown
Default `/loop` behavior for this repo is unset; always pass an explicit command
(e.g. `/loop /work-issue`). This file exists so an argument-less `/loop` does nothing surprising.
```

- [ ] **Step 5: Run the full test suite**

Run: `bats tests/orchestration/`
Expected: all tests PASS.

- [ ] **Step 6: Commit**

```bash
git add .github/ISSUE_TEMPLATE/task.yml CLAUDE.md docs/SETUP.md .claude/loop.md
git commit -m "docs(orch): add setup, issue template, commit conventions, loop default"
```

---

## Final verification

- [ ] **Run everything:** `bats tests/orchestration/` → all green.
- [ ] **Shellcheck the scripts:** `shellcheck scripts/orchestration/*.sh` → no errors (warnings acceptable).
- [ ] **Confirm spec coverage:** every spec §5 script, §6 command, §7 setup item, and §8 intake exists. The 11 spec decisions are realized in config + scripts + docs.
