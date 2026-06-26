# work-issue-deep Conflict-Resolution Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give `work-issue-deep.md`'s rework-resume path the same `conflict-resolve.sh` base-conflict handling (incl. loop-prevention) that `work-issue.md` already has.

**Architecture:** Pure command-markdown change mirroring `work-issue.md` step 5 + step 9 into `work-issue-deep.md` 5g + step 9, guarded by a grep-based content-invariant regression test. No shell/engine code changes.

**Tech Stack:** Markdown (LLM lane instructions), `bats`, `shellcheck`, `jq`.

## Global Constraints

- Never rename engine internals; do NOT modify `conflict-resolve.sh` or `work-issue.md`.
- Mirror `work-issue.md`'s wording, adapted to the deep lane's numbering (5g resume path; step 9 transition referencing **5g**).
- Conflict base branch stays `main` (parity with `work-issue.md`; generalizing to `$INTEGRATION_BRANCH` is out of scope).
- Claude-command-only: no `plugins/ganpan-codex/` or `references/lanes/` change (no `ganpan-work-issue-deep` skill / reference exists).
- Bump `plugin.json` (fix → patch) from current `main` (baseline `1.9.0`; re-check before bumping).
- Work in worktree `wt-issue-58` on branch `issue-58`; tests from repo root.

---

### Task 1: Add the conflict-resolution block to `work-issue-deep.md` (test-guarded)

**Files:**
- Test: `tests/codex-skills.bats` (add one `@test`)
- Modify: `plugins/orchestration/commands/work-issue-deep.md` (5g, line 53; step 9, line 58)

**Interfaces:**
- Consumes: `conflict-resolve.sh` (returns `up-to-date`/`resolved`/`conflict`).

- [ ] **Step 1: Write the failing regression test**

In `tests/codex-skills.bats`, after the "work-issue reference preserves rework resume safety steps" test (ends ~line 91), add:

```bash
@test "work-issue-deep resume path runs conflict-resolve with loop-prevention skip" {
  cmd="$REPO_ROOT/plugins/orchestration/commands/work-issue-deep.md"
  run grep -q 'conflict-resolve.sh main' "$cmd"   # the invocation
  [ "$status" -eq 0 ]
  run grep -q 'up-to-date' "$cmd"                  # the up-to-date outcome branch
  [ "$status" -eq 0 ]
  run grep -q 'merged in cleanly' "$cmd"           # the resolved outcome branch (distinct from 'rework-resolved:')
  [ "$status" -eq 0 ]
  run grep -q '자동 해소 불가' "$cmd"               # the conflict-escalation gh pr comment body
  [ "$status" -eq 0 ]
  run grep -q 'Skip this whole step' "$cmd"        # the step-9 loop-prevention skip (core safety property)
  [ "$status" -eq 0 ]
}
```

> `$REPO_ROOT` is set by `setup()` in codex-skills.bats (`REPO_ROOT="$BATS_TEST_DIRNAME/.."`). Verify by reading the top of the file.

- [ ] **Step 2: Run the test, expect FAIL**

Run: `bats tests/codex-skills.bats --filter "work-issue-deep resume path"`
Expected: FAIL — none of those four strings are in `work-issue-deep.md` yet (the first grep, `conflict-resolve.sh main`, already fails).

- [ ] **Step 3: Add the conflict-resolution block to 5g**

In `plugins/orchestration/commands/work-issue-deep.md`, the 5g bullet currently ends with `…make the requested changes, then run 5f to re-verify.` Replace that trailing sentence:

`make the requested changes, then run 5f to re-verify.`

with:

```
make the requested changes. **Conflict resolution (resume only).** Before re-verifying, bring the branch up to date with `main` — the PR may have started conflicting because `main` advanced. From inside `wt-issue-$ISSUE`, run `RES=$(${CLAUDE_PLUGIN_ROOT}/scripts/orchestration/conflict-resolve.sh main)`: `up-to-date` → nothing to merge, continue; `resolved` → `main` was merged in cleanly (git 3-way, committed), continue (the 5f re-verify below validates the merged tree and step 7 pushes the merge with the rest); `conflict` → the branch **genuinely** conflicts with `main` and must **not** be auto-resolved (never hand-edit conflict markers — that risks a bad merge), so escalate to a human — `gh pr comment "$PR" --body "⚠️ base(\`main\`)와 충돌 — 자동 해소 불가, 사람이 수동 해소 필요"` — then **stop without completing step 9's transition**: leave the issue `status:in-progress`, do **not** post `rework-resolved:` (an in-review PR that still conflicts would just be re-routed to rework next Reviewer tick → loop), and still stop the background heartbeat. Otherwise run 5f to re-verify.
```

- [ ] **Step 4: Add the skip clause to step 9**

In `work-issue-deep.md`, step 9 currently reads (note the `**` bold markers around "Stop the background heartbeat" — the Edit `old_string` must include them to match):

```
9. **Transition.** `gh issue edit "$ISSUE" --add-label status:in-review --remove-label status:in-progress`. **Stop the background heartbeat** (`kill "$(cat "${TMPDIR:-/tmp}/hb-$ISSUE.pid")" 2>/dev/null || true`). If this was a resume, add `gh issue comment "$ISSUE" --body "rework-resolved:"`.
```

Append the skip clause (mirroring `work-issue.md` step 9, referencing 5g):

```
9. **Transition.** `gh issue edit "$ISSUE" --add-label status:in-review --remove-label status:in-progress`. **Stop the background heartbeat** (`kill "$(cat "${TMPDIR:-/tmp}/hb-$ISSUE.pid")" 2>/dev/null || true`). If this was a resume, add `gh issue comment "$ISSUE" --body "rework-resolved:"`. **Skip this whole step** if 5g escalated an unresolved `conflict` — that issue stays `status:in-progress` (no `rework-resolved:`) pending human conflict resolution; still stop the background heartbeat.
```

- [ ] **Step 5: Run the test, expect PASS; run the full suite**

Run: `bats tests/codex-skills.bats`  → all PASS (new test green).
Run: `bats tests/*.bats tests/orchestration/*.bats`  → all green.
Run: `shellcheck plugins/orchestration/scripts/orchestration/*.sh`  → exit 0 (no shell changed; sanity).

- [ ] **Step 6: Commit**

```bash
git add plugins/orchestration/commands/work-issue-deep.md tests/codex-skills.bats
git commit -m "fix(orch): work-issue-deep resume resolves base conflicts

Mirror work-issue.md's conflict-resolve.sh step into the deep lane's
rework-resume path (5g) + the step-9 loop-prevention skip, so a
CONFLICTING PR routed to the deep lane is auto-merged when clean and
escalated (not infinitely re-routed) when it genuinely conflicts.
Regression test guards the invariant. Refs #58"
```

---

### Task 2: Version bump + dev-log + final gate

**Files:**
- Modify: `plugins/orchestration/.claude-plugin/plugin.json`
- Create: `docs/log/2026-06-26-work-issue-deep-conflict-resolve.md`

- [ ] **Step 1: Write the dev-log**

Create `docs/log/2026-06-26-work-issue-deep-conflict-resolve.md` per `docs/log/README.md`, recording:
- What changed: work-issue-deep 5g gains the `conflict-resolve.sh main` step + three-outcome handling; step 9 gains the loop-prevention skip; regression test added.
- Why: the deep lane never ran conflict-resolve → CONFLICTING PRs routed to it were never auto-resolved → infinite rework loop (hit #49/PR #53; worked around manually in #29/#56).
- Key decisions: mirror work-issue.md verbatim (lockstep, no drift); on genuine `conflict` keep `status:in-progress` + skip the transition (parking outside the Reviewer's `status:in-review` input domain is what breaks the loop); run conflict-resolve BEFORE 5f so tests validate the merged tree; keep base=`main` for parity.
- Alternatives rejected: handling the merge inline with raw `git merge` (duplicates conflict-resolve.sh, risks hand-resolving markers); moving a conflicted resume back to `status:in-review` (re-triggers the loop); generalizing base to `$INTEGRATION_BRANCH` now (separate follow-up); mirroring into Codex (no deep skill exists).

- [ ] **Step 2: Commit the dev-log (before the bump, so it survives a merge-time re-bump)**

```bash
git add docs/log/2026-06-26-work-issue-deep-conflict-resolve.md
git commit -m "docs(log): #58 work-issue-deep conflict-resolution parity"
```

- [ ] **Step 3: Bump the patch version**

Run `git fetch origin main && git show origin/main:plugins/orchestration/.claude-plugin/plugin.json | jq -r .version` to read main's current `M.m.p`. Set `plugins/orchestration/.claude-plugin/plugin.json` `version` to `M.m.(p+1)`. Validate: `jq . plugins/orchestration/.claude-plugin/plugin.json .claude-plugin/marketplace.json`.

- [ ] **Step 4: Commit the bump**

```bash
NEW_VER=$(jq -r .version plugins/orchestration/.claude-plugin/plugin.json)
git add plugins/orchestration/.claude-plugin/plugin.json
git commit -m "chore(release): bump orchestration to ${NEW_VER} for #58 (fix -> patch)"
```

> **Cross-PR version note:** `main` moves as concurrent PRs merge; compute the bump from `origin/main` here and flag in the PR body that a merge-time re-bump may be needed. The dev-log is a separate commit so a re-bump never drops it.
