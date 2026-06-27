# QA Owns the Issue Close (no auto-close on merge) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop merges from auto-closing the issue by replacing the auto-closing `Closes #<ISSUE>` keyword with a non-closing `Refs #<ISSUE>` across the Coder-lane PR bodies, commit footers, and commit conventions — so the documented Reviewer→QA→close flow owns the terminal close.

**Architecture:** Pure instructions/convention change across six Coder-lane "merge-bound artifact" files + three QA-lane comment corrections, guarded by a grep content-invariant test. No engine script logic changes.

**Tech Stack:** Markdown lane instructions + conventions, `bats`, `shellcheck`, `jq`.

## Global Constraints
- Never rename engine internals; no engine script logic changes.
- Replace the auto-closing keyword with `Refs #` (non-closing); keep the issue number for traceability.
- The six "AC1" files must contain **no literal `Closes #`** after the fix (incl. any added note — paraphrase as "non-closing"/"auto-closing keyword"); the regression grep enforces this.
- The qa-check files keep `Closes #` only in explanatory prose and are **excluded** from the no-`Closes #` grep.
- `assets/CLAUDE.md` is shipped — its convention change ships to users.
- Bump `plugin.json` (fix → patch) from current `main` (baseline `1.10.1` → `1.10.2`; re-fetch before bumping).
- Work in worktree `wt-issue-63` on branch `issue-63`; tests from repo root.

---

### Task 1: Replace `Closes #` → `Refs #` in Coder lanes + conventions (test-guarded)

**Files:**
- Test: `tests/codex-skills.bats` (add one `@test`)
- Modify: `plugins/orchestration/commands/work-issue.md` (commit footer + PR body)
- Modify: `plugins/orchestration/commands/work-issue-deep.md` (PR body)
- Modify: `plugins/orchestration/references/lanes/work-issue.md` (commit footer)
- Modify: `plugins/ganpan-codex/skills/ganpan-work-issue/references/work-issue.md` (commit footer — Codex copy)
- Modify: `plugins/orchestration/assets/CLAUDE.md` (commit-footer convention)
- Modify: `CLAUDE.md` (both Repo-conventions blocks)
- Modify: `plugins/orchestration/commands/qa-check.md` (comment)
- Modify: `plugins/orchestration/references/lanes/qa-check.md` (comment)
- Modify: `plugins/ganpan-codex/skills/ganpan-qa-check/references/qa-check.md` (comment — Codex copy)

- [ ] **Step 1: Write the failing test**

In `tests/codex-skills.bats`, after the "work-issue-deep resume path…" test, add:

```bash
@test "issues referenced non-closing (Refs, not Closes) so QA owns the close (#63)" {
  # AC1: no auto-closing keyword in any Coder-lane merge-bound artifact.
  for rel in \
    plugins/orchestration/commands/work-issue.md \
    plugins/orchestration/commands/work-issue-deep.md \
    plugins/orchestration/references/lanes/work-issue.md \
    plugins/ganpan-codex/skills/ganpan-work-issue/references/work-issue.md \
    plugins/orchestration/assets/CLAUDE.md \
    CLAUDE.md ; do
    run grep -F 'Closes #' "$REPO_ROOT/$rel"
    [ "$status" -ne 0 ]   # grep finds nothing → exit nonzero
  done
  # the lane instruction files (+ canonical ref + Codex copy) use the non-closing Refs.
  for rel in \
    plugins/orchestration/commands/work-issue.md \
    plugins/orchestration/commands/work-issue-deep.md \
    plugins/orchestration/references/lanes/work-issue.md \
    plugins/ganpan-codex/skills/ganpan-work-issue/references/work-issue.md ; do
    run grep -F 'Refs #' "$REPO_ROOT/$rel"
    [ "$status" -eq 0 ]
  done
  # AC3: qa-check docs state the non-closing design (and drop the old inaccurate phrasing).
  for rel in \
    plugins/orchestration/commands/qa-check.md \
    plugins/orchestration/references/lanes/qa-check.md \
    plugins/ganpan-codex/skills/ganpan-qa-check/references/qa-check.md ; do
    run grep -F 'non-closing' "$REPO_ROOT/$rel"
    [ "$status" -eq 0 ]
    run grep -F 'often lack it' "$REPO_ROOT/$rel"
    [ "$status" -ne 0 ]
  done
}
```

> `$REPO_ROOT` is `$BATS_TEST_DIRNAME/..` per codex-skills.bats `setup()`.

- [ ] **Step 2: Run the test, expect FAIL**

Run: `bats tests/codex-skills.bats --filter "non-closing"`
Expected: FAIL — the AC1 files still contain `Closes #`.

- [ ] **Step 3: `work-issue.md` — footer + PR body**

In `plugins/orchestration/commands/work-issue.md`, replace the commit-footer text `footer \`Closes #$ISSUE\`` with `footer \`Refs #$ISSUE\` (non-closing — QA owns the terminal close on pass)`. Then replace the PR-body occurrence `Closes #$ISSUE` with `Refs #$ISSUE` (the `--body "...\n\nCloses #$ISSUE"` argument → `--body "...\n\nRefs #$ISSUE"`).

- [ ] **Step 4: `work-issue-deep.md` — PR body**

In `plugins/orchestration/commands/work-issue-deep.md`, replace the `gh pr create --body "...\n\nCloses #$ISSUE"` occurrence: `Closes #$ISSUE` → `Refs #$ISSUE`.

- [ ] **Step 5: canonical reference + Codex copy — commit footer**

In **both** `plugins/orchestration/references/lanes/work-issue.md` and `plugins/ganpan-codex/skills/ganpan-work-issue/references/work-issue.md`, replace the identical line:

`7. Commit with Conventional Commits and include \`Closes #<ISSUE>\`.`

with:

`7. Commit with Conventional Commits and include a non-closing \`Refs #<ISSUE>\` (QA owns the terminal close, so the issue must not auto-close on merge).`

- [ ] **Step 6: commit-footer convention — `assets/CLAUDE.md` + `CLAUDE.md` (both blocks)**

Replace every occurrence of:

`- Footer references the issue: \`Closes #<n>\`.`

with:

`- Footer references the issue with a non-closing reference: \`Refs #<n>\` (QA owns the terminal close — an auto-closing keyword would close the issue on merge and skip qa-check).`

in `plugins/orchestration/assets/CLAUDE.md` (one occurrence) and `CLAUDE.md` (two occurrences — use replace-all).

- [ ] **Step 7: qa-check comment corrections (3 files)**

In `plugins/orchestration/commands/qa-check.md`, replace:

`The merged PR bodies do not carry a \`Closes #<n>\` keyword, so GitHub never auto-closes on merge; relying on it leaves \`status:done\` issues open.`

with:

`The Coder lanes reference the issue with a non-closing \`Refs #<n>\` (not the auto-closing keyword), so merge never auto-closes and QA owns the terminal close.`

In **both** `plugins/orchestration/references/lanes/qa-check.md` and `plugins/ganpan-codex/skills/ganpan-qa-check/references/qa-check.md`, replace:

`QA owns the terminal close — do not rely on a PR's \`Closes #<n>\` keyword to auto-close, since merged PR bodies often lack it.`

with:

`QA owns the terminal close — the Coder lanes reference issues with a non-closing \`Refs #<n>\`, so merge never auto-closes.`

- [ ] **Step 8: Run the test (GREEN) + verify no stray vector**

Run: `bats tests/codex-skills.bats`  → all PASS.
Run: `grep -rn 'Closes #' plugins/orchestration/commands plugins/orchestration/references plugins/ganpan-codex plugins/orchestration/assets/CLAUDE.md CLAUDE.md` → only the qa-check files should remain (their prose) — confirm no Coder-lane artifact still has it.

- [ ] **Step 9: Commit**

```bash
git add tests/codex-skills.bats plugins/orchestration/commands/work-issue.md plugins/orchestration/commands/work-issue-deep.md plugins/orchestration/references/lanes/work-issue.md plugins/ganpan-codex/skills/ganpan-work-issue/references/work-issue.md plugins/orchestration/assets/CLAUDE.md CLAUDE.md plugins/orchestration/commands/qa-check.md plugins/orchestration/references/lanes/qa-check.md plugins/ganpan-codex/skills/ganpan-qa-check/references/qa-check.md
git commit -m "fix(orch): reference issues non-closing so QA owns the close

Coder lanes used Closes #n in the PR body + commit footer, auto-closing
the issue when the PR merged to main — before qa-check, and unrecoverable
on a QA fail. Switch to non-closing Refs #n across the lanes + commit
convention (repo + shipped CLAUDE.md); correct the qa-check comments.
Regression test guards the invariant. Refs #63"
```

---

### Task 2: Full gate, version bump, dev-log

**Files:**
- Modify: `plugins/orchestration/.claude-plugin/plugin.json`
- Create: `docs/log/2026-06-27-qa-owns-issue-close.md`

- [ ] **Step 1: Full gate**

Run: `bats tests/*.bats tests/orchestration/*.bats`  → all green.
Run: `shellcheck plugins/orchestration/scripts/orchestration/*.sh`  → exit 0 (no shell changed; sanity).
Run: `jq . plugins/orchestration/.claude-plugin/plugin.json .claude-plugin/marketplace.json`  → valid.

- [ ] **Step 2: Write the dev-log**

Create `docs/log/2026-06-27-qa-owns-issue-close.md` per `docs/log/README.md`, recording: the two auto-close vectors (PR body + commit footer) and the merge→default-branch rule; the `Refs #n` decision (non-closing, keeps the `#n` autolink); the full set of touched files incl. the Codex copies; that it restores the already-documented "QA owns the terminal close" intent; the QA-fail recovery benefit (issue stays open). Alternatives rejected: keep `Closes` and have QA reopen (fragile, races merge); only fix the PR body (commit footer still auto-closes on squash-merge); a CI lint instead of the convention change (doesn't fix the deployed lane behavior); reopening already-closed issues (manual data cleanup, out of scope).

- [ ] **Step 3: Commit the dev-log (before the bump)**

```bash
git add docs/log/2026-06-27-qa-owns-issue-close.md
git commit -m "docs(log): #63 QA owns the issue close (no auto-close on merge)"
```

- [ ] **Step 4: Bump the patch version**

Run `git fetch origin main && git show origin/main:plugins/orchestration/.claude-plugin/plugin.json | jq -r .version` for main's `M.m.p`. Set `version` to `M.m.(p+1)`. Validate JSON.

- [ ] **Step 5: Commit the bump**

```bash
NEW_VER=$(jq -r .version plugins/orchestration/.claude-plugin/plugin.json)
git add plugins/orchestration/.claude-plugin/plugin.json
git commit -m "chore(release): bump orchestration to ${NEW_VER} for #63 (fix -> patch)"
```

> **Cross-PR version note:** compute from `origin/main` at Step 4; flag in the PR body that a merge-time re-bump may be needed. The dev-log is a separate commit so a re-bump never drops it.

> **Dogfood note:** this PR's own commit footers and PR body should use `Refs #63` (not `Closes #63`) — practice what we ship, so #63 itself goes through QA rather than auto-closing on merge.
