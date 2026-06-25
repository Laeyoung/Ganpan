# gh-stdout Leak Audit & Convention Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the `gh`-stdout leak bug class (PR #28): future-proof the two latent leaks (`reclaim.sh`, `lib.sh` `project_sync`), codify the keep-stdout-clean convention in `CLAUDE.md`, and extend the `GH_EMIT_WRITE_URL` regression pattern to the mutating-`gh` captured scripts.

**Architecture:** Pure stdout-hygiene change. Mutating `gh` writes whose success URL must not pollute a captured return value get `>/dev/null` (stdout only; stderr stays open for `|| log WARN`). The bats `gh` stub gains `pr merge` to its `GH_EMIT_WRITE_URL` case so the regression tests actually exercise a leak. No runtime contract (exit codes, return tokens) changes.

**Tech Stack:** Bash, `bats` (test runner ≥1.5.0), `shellcheck`, `jq`, `gh` (faked in tests).

## Global Constraints

- Never rename engine internals (`scripts/orchestration/`, `orchestration.json`, the `ganpan-orchestration` sentinel) — deployed runtime contract.
- Preserve every script's exit code and stdout return token exactly; only suppress incidental success output of mutating `gh` writes.
- Redirect form is `>/dev/null` (stdout only), **not** `>/dev/null 2>&1`, on calls whose failure must still surface via `|| log WARN`/`||`-chains. Place the redirect on each individual `gh` call.
- The existing `gh api --method DELETE … >/dev/null 2>&1 || true` best-effort cleanups in `claim.sh` are already correct — do not touch.
- All work happens in worktree `wt-issue-29` on branch `issue-29`. Tests run from the repo root.
- After changing anything under `plugins/`, bump `plugins/orchestration/.claude-plugin/plugin.json` (fix → patch).

---

### Task 1: Extend the `gh` stub to emit a write URL for `pr merge`

**Files:**
- Modify: `tests/orchestration/helpers/gh-stub.sh` (the `GH_EMIT_WRITE_URL` case block near the end)

**Interfaces:**
- Consumes: nothing.
- Produces: under `GH_EMIT_WRITE_URL=1`, a `gh pr merge …` call now prints `https://github.com/o/r/issues/STUB-URL` to stdout (mimicking real `gh pr merge`, which prints a confirmation line on success). This is the leak that Task 2's test guards against.

- [ ] **Step 1: Read the current case block**

Open `tests/orchestration/helpers/gh-stub.sh` and find:

```bash
if [ -n "${GH_EMIT_WRITE_URL:-}" ]; then
  case "${1:-} ${2:-}" in
    "issue edit"|"issue comment"|"issue create"|"pr create")
      echo "https://github.com/o/r/issues/STUB-URL" ;;
  esac
fi
```

- [ ] **Step 2: Add `pr merge` to the case**

Replace the `case` pattern line so it reads:

```bash
    "issue edit"|"issue comment"|"issue create"|"pr create"|"pr merge")
      echo "https://github.com/o/r/issues/STUB-URL" ;;
```

- [ ] **Step 3: Update the explanatory comment above the block**

The comment lists the mimicked writes as "(issue edit/comment/create, pr create)". Change it to "(issue edit/comment/create, pr create/merge)" so the stub's documented behavior stays accurate.

- [ ] **Step 4: Verify the whole suite still passes (no test asserts `pr merge` stays silent)**

Run: `bats tests/orchestration/auto-merge.bats`
Expected: PASS — existing `merged` test uses plain `run` and asserts `output = "merged"`; it does **not** set `GH_EMIT_WRITE_URL`, so the new case does not fire for it.

- [ ] **Step 5: Commit**

```bash
git add tests/orchestration/helpers/gh-stub.sh
git commit -m "test(orch): stub emits write URL for 'pr merge' under GH_EMIT_WRITE_URL

So auto-merge's regression test (next commit) actually exercises a
pr-merge stdout leak instead of passing trivially. Refs #29"
```

---

### Task 2: Regression-guard `auto-merge.sh` captured stdout

`auto-merge.sh` is already correct (it isolates `gh pr merge` via `merge_out=$(… 2>&1)`). This task is a **guard test**: it locks that isolation in so a future edit that drops the `2>&1` capture is caught.

**Files:**
- Test: `tests/orchestration/auto-merge.bats` (add one `@test`)

**Interfaces:**
- Consumes: Task 1's stub change (the `pr merge` URL emission).
- Produces: nothing (test-only).

- [ ] **Step 1: Add the failing-by-construction guard test**

Append to `tests/orchestration/auto-merge.bats` (model it on the existing "genuine 404 … prints 'merged'" test):

```bash
@test "captured stdout stays exactly 'merged' even when gh pr merge leaks a URL" {
  # Regression guard for the ISSUE=$(claim.sh)-class bug applied to AM=$(auto-merge.sh):
  # real `gh pr merge` prints a confirmation line on success. With GH_EMIT_WRITE_URL the
  # stub mimics that. auto-merge.sh isolates the merge via merge_out=$(… 2>&1), so its OWN
  # stdout must remain the bare token — this asserts that and would fail if the 2>&1
  # capture were ever dropped.
  export GH_EMIT_WRITE_URL=1
  write_config true
  export GH_API_404_MATCH='branches/main/protection'   # genuine 404 ⇒ not protected
  queue_response '{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","baseRefName":"main"}'   # gh pr view
  run bash "$SCRIPT" 7
  [ "$status" -eq 0 ]
  [ "$output" = "merged" ]               # exactly the token — no leaked URL line
  [[ "$output" != *"STUB-URL"* ]]        # the pr-merge URL never reached auto-merge's stdout
  grep -q 'pr merge 7' "$GH_CALLS"
}
```

- [ ] **Step 2: Run the test, expect PASS**

Run: `bats tests/orchestration/auto-merge.bats`
Expected: PASS — `auto-merge.sh` already keeps the merge output off its stdout.

> Sanity check (optional, do NOT commit the change): temporarily edit `auto-merge.sh` line ~74 to `if gh pr merge "$PR" "$METHOD" --repo "$REPO"; then` (dropping `merge_out=$(… 2>&1)`) and re-run — the new test should FAIL with `STUB-URL` in output, proving the guard bites. Revert immediately.

- [ ] **Step 3: Commit**

```bash
git add tests/orchestration/auto-merge.bats
git commit -m "test(orch): guard auto-merge captured stdout against pr-merge URL leak

Refs #29"
```

---

### Task 3: Fix `reclaim.sh` stdout leak (TDD) and cover both branches

**Files:**
- Test: `tests/orchestration/reclaim.bats` (add `bats_require_minimum_version` + two `@test`s)
- Modify: `plugins/orchestration/scripts/orchestration/reclaim.sh:49-56`

**Interfaces:**
- Consumes: Task 1's stub change.
- Produces: `reclaim.sh`'s mutating `gh issue edit`/`gh issue comment` calls no longer print to stdout. `reclaim.sh` has no stdout return token (returns via exit code; logs via `log` to stderr), so its stdout must be empty.

- [ ] **Step 1: Add the bats version directive (if absent)**

Check first: `grep -q 'bats_require_minimum_version' tests/orchestration/reclaim.bats` — if it prints nothing (absent, which is the current state), add, immediately after the `#!/usr/bin/env bats` shebang line (the new tests use `run --separate-stderr` to isolate stdout from `log` stderr):

```bash
bats_require_minimum_version 1.5.0
```

- [ ] **Step 2: Write the two failing tests**

Append to `tests/orchestration/reclaim.bats` (model the queue setup on the existing `#5`/`#6` tests). The three `queue_response` calls map to `reclaim.sh`'s read sequence in order: (1) `gh issue list --label status:in-progress` (the in-progress list), (2) `gh issue view <n> --json comments` (per-issue claim-token read), (3) `gh pr list --head issue-<n>` (open-PR check). The mutating `gh issue edit`/`gh issue comment` writes do **not** consume queue slots (the stub only emits queued responses for read subcommands), so the queue is exactly these three reads — same shape as the existing `#5`/`#6` tests:

```bash
@test "open-PR reclaim leaks no write URL to stdout (GH_EMIT_WRITE_URL)" {
  export GH_EMIT_WRITE_URL=1
  queue_response '[{"number":5}]'
  queue_response '{"comments":[{"author":{"login":"botx"},"body":"claim: 2000-01-01T00:00:00Z-botx-h-1"}]}'  # view
  queue_response '[{"number":99,"state":"OPEN"}]'                  # pr list --head issue-5
  run --separate-stderr bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q 'issue edit 5 --add-label status:blocked' "$GH_CALLS"   # the → blocked path ran
  [[ "$output" != *"STUB-URL"* ]]                                 # no leaked write URL on stdout
  [ -z "$output" ]                                                # reclaim returns via exit code; stdout is empty
}

@test "no-PR reclaim leaks no write URL to stdout (GH_EMIT_WRITE_URL)" {
  export GH_EMIT_WRITE_URL=1
  queue_response '[{"number":6}]'
  queue_response '{"comments":[{"author":{"login":"botx"},"body":"claim: 2000-01-01T00:00:00Z-botx-h-1"}]}'  # view
  queue_response '[]'                                             # pr list empty
  run --separate-stderr bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q 'issue edit 6 --add-label status:agent-ready' "$GH_CALLS"  # the → agent-ready path ran
  [[ "$output" != *"STUB-URL"* ]]
  [ -z "$output" ]
}
```

- [ ] **Step 3: Run the tests, expect FAIL**

Run: `bats tests/orchestration/reclaim.bats`
Expected: the two new tests FAIL — `reclaim.sh` currently lets `gh issue edit`/`gh issue comment` print `STUB-URL` to stdout, so `$output` contains it and is non-empty.

- [ ] **Step 4: Fix `reclaim.sh` — redirect each mutating `gh` call**

In `plugins/orchestration/scripts/orchestration/reclaim.sh`, change lines 49-56. Current:

```bash
    { gh issue edit "$issue" --add-label status:blocked --remove-label status:in-progress --repo "$REPO" \
      && gh issue comment "$issue" --body "reclaimed: orphan lock, PR #$pr 존재 — 사람 확인 필요" --repo "$REPO"; } \
      || { log WARN "#$issue reclaim→blocked failed, skip"; continue; }
    log INFO "#$issue → blocked (open PR #$pr)"
  else
    { gh issue edit "$issue" --add-label status:agent-ready --remove-label status:in-progress --repo "$REPO" \
      && gh issue edit "$issue" --remove-assignee "$BOT" --repo "$REPO" \
      && gh issue comment "$issue" --body "reclaimed: orphan lock" --repo "$REPO"; } \
      || { log WARN "#$issue reclaim→agent-ready failed, skip"; continue; }
```

New (add `>/dev/null` to each `gh` call; everything else identical):

```bash
    { gh issue edit "$issue" --add-label status:blocked --remove-label status:in-progress --repo "$REPO" >/dev/null \
      && gh issue comment "$issue" --body "reclaimed: orphan lock, PR #$pr 존재 — 사람 확인 필요" --repo "$REPO" >/dev/null; } \
      || { log WARN "#$issue reclaim→blocked failed, skip"; continue; }
    log INFO "#$issue → blocked (open PR #$pr)"
  else
    { gh issue edit "$issue" --add-label status:agent-ready --remove-label status:in-progress --repo "$REPO" >/dev/null \
      && gh issue edit "$issue" --remove-assignee "$BOT" --repo "$REPO" >/dev/null \
      && gh issue comment "$issue" --body "reclaimed: orphan lock" --repo "$REPO" >/dev/null; } \
      || { log WARN "#$issue reclaim→agent-ready failed, skip"; continue; }
```

- [ ] **Step 5: Run the tests, expect PASS; confirm no regression of existing reclaim tests**

Run: `bats tests/orchestration/reclaim.bats`
Expected: all tests PASS (the two new ones now find empty stdout; the existing `#5`/`#6` tests that grep `$GH_CALLS` are unaffected since the stub still logs the call).

- [ ] **Step 6: shellcheck**

Run: `shellcheck plugins/orchestration/scripts/orchestration/reclaim.sh`
Expected: exit 0, no findings.

- [ ] **Step 7: Commit**

```bash
git add plugins/orchestration/scripts/orchestration/reclaim.sh tests/orchestration/reclaim.bats
git commit -m "fix(orch): keep reclaim.sh stdout clean of gh write URLs

reclaim.sh's mutating gh issue edit/comment calls printed the resource
URL to stdout on success. It runs for its exit code today (output
ignored), but the leak is the claim.sh/PR #28 bug class and would
corrupt any future \$()-capture. Redirect each write to /dev/null;
stderr stays open for the || log WARN branches. Refs #29"
```

---

### Task 4: Fix `lib.sh` `project_sync` stdout leak

**Files:**
- Modify: `plugins/orchestration/scripts/orchestration/lib.sh:121` (the final `gh project item-edit` in `project_sync`)

**Interfaces:**
- Consumes: nothing.
- Produces: `project_sync`'s `gh project item-edit` no longer prints to stdout. All 6 lane call sites invoke `project_sync` bare (not in `$()`), so no caller is affected; this is future-proofing per the convention.

- [ ] **Step 1: Redirect the `item-edit` write**

In `plugins/orchestration/scripts/orchestration/lib.sh`, the last line of `project_sync` is:

```bash
  gh project item-edit --id "$item_id" --project-id "$proj_id" --field-id "$field_id" --single-select-option-id "$opt_id"
```

Append `>/dev/null` (stdout only — keep stderr for genuine errors):

```bash
  gh project item-edit --id "$item_id" --project-id "$proj_id" --field-id "$field_id" --single-select-option-id "$opt_id" >/dev/null
```

> Note: the read calls in `project_sync` (`gh project view`, `field-list`, `item-list`) are already captured into `$()` locals, so they do not leak. Only the trailing write needs redirecting. The `gh project item-edit` call is the function's last statement, so its exit status remains `project_sync`'s return status — unchanged.

- [ ] **Step 2: shellcheck + existing lib tests**

Run: `shellcheck plugins/orchestration/scripts/orchestration/lib.sh && bats tests/orchestration/lib.bats`
Expected: shellcheck exit 0; lib.bats PASS (project_sync tests assert `$GH_CALLS` contents / return value, not stdout, so they are unaffected).

- [ ] **Step 3: Commit**

```bash
git add plugins/orchestration/scripts/orchestration/lib.sh
git commit -m "fix(orch): keep project_sync stdout clean of gh write output

gh project item-edit printed to stdout on success. project_sync is
called bare (never \$()-captured) today, but redirecting to /dev/null
holds the keep-stdout-clean convention uniformly. Refs #29"
```

---

### Task 5: Codify the keep-stdout-clean convention in `CLAUDE.md`

**Files:**
- Modify: root `CLAUDE.md` (the `## Gotchas` section under the Ganpan heading)

**Interfaces:**
- Consumes: nothing.
- Produces: a documented rule future contributors follow.

- [ ] **Step 1: Add a Gotchas bullet**

In root `CLAUDE.md`, under `## Gotchas` (the bullet list that already covers "Never rename engine internals", config discovery, worktree config), add a new bullet:

```markdown
- **Keep engine-script stdout clean for the return value.** Any script whose stdout is captured via `$(…)` (e.g. `ISSUE=$(claim.sh)`, `AM=$(auto-merge.sh)`, `case "$(unblock-check.sh)"`) must emit **only** its return token on stdout. Mutating `gh` writes (`gh issue edit|comment|create`, `gh pr create|merge`, `gh label create`, `gh project item-edit`, `gh api --method POST|PUT|PATCH|DELETE`) print the resource URL/confirmation to stdout on success even non-interactively — send that to `/dev/null` (`>/dev/null`, keeping stderr open for `|| log WARN`) or capture it into a local (`out=$(gh … 2>&1)`). A leaked URL corrupts the captured value (the PR #28 / #29 bug class). Exception: `bootstrap-labels.sh` deliberately prints per-label progress to stdout — it is human-facing setup output, not a captured return value. Regression-guard new captured+mutating scripts with the `GH_EMIT_WRITE_URL` stub pattern (`tests/orchestration/helpers/gh-stub.sh`).
```

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: codify keep-stdout-clean convention for engine scripts

Document the PR #28/#29 bug class: $()-captured engine scripts must keep
mutating gh write output off stdout (>/dev/null or captured), with the
bootstrap-labels.sh human-output exception. Refs #29"
```

---

### Task 6: Version bump

**Files:**
- Modify: `plugins/orchestration/.claude-plugin/plugin.json` (`version`)

- [ ] **Step 1: Read current version**

Run: `jq -r .version plugins/orchestration/.claude-plugin/plugin.json`

- [ ] **Step 2: Bump the patch component**

This is a fix (stdout hygiene) → patch bump. Edit `version` from `x.y.Z` to `x.y.(Z+1)`.

- [ ] **Step 3: Validate JSON + commit**

```bash
jq . plugins/orchestration/.claude-plugin/plugin.json >/dev/null
NEW_VER=$(jq -r .version plugins/orchestration/.claude-plugin/plugin.json)
git add plugins/orchestration/.claude-plugin/plugin.json
git commit -m "chore(release): bump orchestration to ${NEW_VER} for #29"
```

(Current version is `1.6.0` → bump to `1.6.1`.)

---

### Task 7: Full suite + shellcheck gate, then the log entry

**Files:**
- Create: `docs/log/2026-06-25-gh-stdout-leak-audit.md`

- [ ] **Step 1: Run the full test suite**

Run: `bats tests/*.bats tests/orchestration/*.bats`
Expected: all green.

- [ ] **Step 2: Run shellcheck across all engine scripts**

Run: `shellcheck plugins/orchestration/scripts/orchestration/*.sh`
Expected: exit 0.

- [ ] **Step 3: Write the dev-log entry**

Create `docs/log/2026-06-25-gh-stdout-leak-audit.md` using the template in `docs/log/README.md` (title, Date, Issue/PR, Type, What changed, Why, Key decisions, Alternatives considered/not chosen). Record:
- Audit outcome: every currently-`$()`-captured script is already clean (claim.sh fixed in PR #28; auto-merge.sh isolates via `merge_out=$(… 2>&1)`; the rest are read/compute-only).
- The two latent fixes (`reclaim.sh`, `lib.sh project_sync`) and why they were fixed despite not being captured today.
- The stub `pr merge` extension and why the auto-merge test needed it.
- Alternatives rejected: (a) fixing `bootstrap-labels.sh` too — rejected, its stdout is intentional human-facing setup output; (b) adding `GH_EMIT_WRITE_URL` tests to the read-only captured scripts — rejected, no mutating-gh leak vector so the test would be a trivial no-op; (c) leaving `reclaim.sh`/`project_sync` alone since they aren't captured — rejected, uniform convention enforcement prevents a future `$()`-capture from silently reintroducing the bug.

- [ ] **Step 4: Commit**

```bash
git add docs/log/2026-06-25-gh-stdout-leak-audit.md
git commit -m "docs(log): #29 gh-stdout leak audit, fixes, and convention"
```
