# Spec: Don't auto-close issues on merge — QA owns the terminal close

- **Issue:** #63
- **Date:** 2026-06-27
- **Type:** fix (bug)

## Problem

The intended lifecycle is: Coder opens a PR → issue `status:in-review` → **on merge** the Reviewer lane moves the issue `status:in-review → status:qa` (`references/lanes/review-queue.md:121`) → the QA lane (`qa-check`) runs tests and, **on pass**, sets `status:done` and **closes** the issue (`qa-check.md:22`). `qa-check.md` even states *"QA owns the terminal close … do not rely on a PR's `Closes #<n>` keyword."*

But the Coder lanes contradict that: they inject the GitHub auto-closing keyword **`Closes #<ISSUE>`** in two places — the **PR body** (`work-issue.md:71`, `work-issue-deep.md:56`) and the **commit footer** (the convention in `CLAUDE.md` + shipped `assets/CLAUDE.md`, and `work-issue.md:70` / `references/lanes/work-issue.md:22`). When such a PR merges to the **default branch** (`main` — the default and this repo's integration branch), GitHub **auto-closes the issue at merge**, before the Reviewer→QA→close flow runs.

**Observed (#63):** the issue closes the moment the PR merges, looking like it ended without `qa-check`. Empirically #29 and #58 are `CLOSED/COMPLETED` with `status:done` — they auto-closed at merge and QA only ran afterward on an already-closed issue.

**Why it bites:** if `qa-check` later **fails** (regression), it sets `status:in-progress` + `rework-requested:` — but the issue is already `CLOSED` as `COMPLETED` and is never reopened, leaving a closed-completed issue carrying a rework label. QA can't own the terminal close if merge already closed it.

## Goal

Make merge **not** auto-close the issue, so the documented Reviewer→QA→close flow is the only path that closes it. Replace the auto-closing `Closes #<ISSUE>` with a **non-closing reference** (`Refs #<ISSUE>`) everywhere the Coder lanes/conventions reference the issue in a merge-bound artifact (PR body + commit footer). QA's existing explicit `gh issue close` (already implemented) becomes the sole close.

## Background: GitHub auto-close rules
- A merged PR whose **body/title** contains `Closes #n` auto-closes #n **iff the PR targets the default branch**.
- A commit whose message contains `Closes #n` auto-closes #n when it lands on the **default branch** (e.g. a merge commit bringing feature commits onto `main`).
So both the PR body and the commit footer are auto-close vectors on merge-to-`main`. Non-closing words (`Refs`, `Re`, a bare `#n`) do not auto-close.

## Constraints
- **Never rename engine internals.** This is a copy/convention change to lane instructions + docs; no engine script logic changes.
- Preserve issue↔PR/commit **traceability** — keep referencing the issue number, just with a non-closing keyword (`Refs #<ISSUE>`).
- Keep the change consistent across **all** Coder-lane auto-close vectors so no single leftover `Closes` re-introduces the premature close.
- `assets/CLAUDE.md` is shipped to users — the convention change must ship (it drives users' commit footers too).
- The repo's own `CLAUDE.md` has the commit convention in **two** duplicated "Repo conventions" blocks — update both.
- Do not change the QA lane's close behavior (it already closes on pass) — only update its now-accurate explanatory comment.
- `plugins/` artifacts change → bump `plugin.json` (fix → patch) from current `main`.

## Acceptance criteria
1. No Coder-lane merge-bound artifact uses the auto-closing keyword for the issue ref. Specifically, these contain **no** `Closes #` and use `Refs #` instead:
   - `plugins/orchestration/commands/work-issue.md` (commit footer + PR body),
   - `plugins/orchestration/commands/work-issue-deep.md` (PR body),
   - `plugins/orchestration/references/lanes/work-issue.md` (commit footer),
   - `plugins/orchestration/assets/CLAUDE.md` (commit footer convention),
   - `CLAUDE.md` (both Repo-conventions blocks' commit footer line).
2. The non-closing intent is stated where the convention is defined (`CLAUDE.md` + `assets/CLAUDE.md`): a one-line note that the footer is a **non-closing** reference because **QA owns the terminal close** (the issue auto-closing on merge would skip `qa-check`).
3. `qa-check.md` and `references/lanes/qa-check.md` comments are corrected: the Coder lanes reference issues with a **non-closing** keyword by design (not "PR bodies often lack it"), so merge never auto-closes and QA owns the close.
4. A regression test (`tests/codex-skills.bats`, alongside the existing lane-content invariants) asserts each file in AC1 contains no `Closes #` and that the two lane command files + the canonical reference contain `Refs #`. (Fails before the fix.)
5. Full suite green (`bats tests/*.bats tests/orchestration/*.bats`); `shellcheck` clean; JSON manifests valid.
6. `plugin.json` bumped (fix → patch) from current `main`.
7. A `docs/log/` entry records the auto-close-vectors analysis, the `Refs` decision, and rejected alternatives.

## Non-goals
- Changing the QA lane's pass/fail logic or the Reviewer's merge→`status:qa` transition (both already correct).
- Reopening already-wrongly-closed issues (a one-off data cleanup, not a code change) — out of scope; the fix prevents recurrence.
- Engine script changes; this is instructions + conventions + a content-invariant test.
- Per-branch-strategy nuance (auto-close only fires for PRs to the default branch): the `Refs` change is correct for all strategies and removes the footgun uniformly, so no branch-strategy-specific handling is added.
