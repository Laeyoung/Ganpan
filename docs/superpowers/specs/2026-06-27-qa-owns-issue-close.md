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
- A commit whose message contains `Closes #n` auto-closes #n when that message lands on the **default branch** — clearest with **squash-merge** (the squash commit carries the footer onto `main`); with a plain merge-commit the dominant vector is the PR body.
So the PR body is the primary auto-close vector on merge-to-`main`, and the commit footer is an additional one (squash-merge). Neutralizing **both** is the safe, strategy-independent fix. Non-closing references (`Refs #n`, or a bare `#n`) still create the issue↔PR/commit cross-link in the timeline (the autolink comes from `#n`) but do **not** auto-close.

## Constraints
- **Never rename engine internals.** This is a copy/convention change to lane instructions + docs; no engine script logic changes.
- Preserve issue↔PR/commit **traceability** — keep referencing the issue number, just with a non-closing keyword (`Refs #<ISSUE>`).
- Keep the change consistent across **all** Coder-lane auto-close vectors so no single leftover `Closes` re-introduces the premature close.
- `assets/CLAUDE.md` is shipped to users — the convention change must ship (it drives users' commit footers too).
- The repo's own `CLAUDE.md` has the commit convention in **two** duplicated "Repo conventions" blocks — update both.
- Do not change the QA lane's close behavior (it already closes on pass) — only update its now-accurate explanatory comment.
- `plugins/` artifacts change → bump `plugin.json` (fix → patch) from current `main`.

## Acceptance criteria
1. No Coder-lane merge-bound artifact uses the auto-closing keyword for the issue ref. Specifically, each of these contains **no** literal `Closes #` (anywhere, incl. any explanatory note) and uses `Refs #` for the issue reference:
   - `plugins/orchestration/commands/work-issue.md` (commit-footer instruction + the `gh pr create --body "...\n\nCloses #$ISSUE"` argument),
   - `plugins/orchestration/commands/work-issue-deep.md` (the `gh pr create --body "...\n\nCloses #$ISSUE"` argument at step 7),
   - `plugins/orchestration/references/lanes/work-issue.md` (commit-footer line; it has no PR-body `Closes` — confirmed),
   - `plugins/ganpan-codex/skills/ganpan-work-issue/references/work-issue.md` (Codex copy of the canonical reference — same commit-footer `Closes #<ISSUE>` line),
   - `plugins/orchestration/assets/CLAUDE.md` (commit-footer convention),
   - `CLAUDE.md` (both duplicated Repo-conventions blocks' commit-footer line).
2. The non-closing intent is stated where the convention is defined (`CLAUDE.md` + `assets/CLAUDE.md`): a one-line note that the footer is a **non-closing** reference because **QA owns the terminal close** (an issue auto-closing on merge would skip `qa-check`). **The note must paraphrase** (e.g. "non-closing reference — not the auto-closing keyword") and must **not** contain the literal string `Closes #`, since AC4 greps these files for that string.
3. `qa-check.md` and its Codex copy `plugins/ganpan-codex/skills/ganpan-qa-check/references/qa-check.md`, plus `references/lanes/qa-check.md`, have their comments corrected to state the Coder lanes reference issues with a **non-closing** keyword by design (so merge never auto-closes; QA owns the close). Verifiable: each must contain the string `non-closing` and must **not** contain the old inaccurate phrasing (`often lack it` / `do not carry`). These qa-check files legitimately still contain `Closes #` in explanatory prose and are therefore **excluded** from AC4's no-`Closes #` grep.
4. A regression test (`tests/codex-skills.bats`, alongside the existing lane-content invariants) asserts: each of the **six AC1 files** contains no literal `Closes #`; and the two lane command files + the canonical reference + its Codex copy contain `Refs #`. The grep set is **exactly** the AC1 files — it must **not** include `qa-check.md`/its references (which keep `Closes #` in prose). (Fails before the fix.)
5. Full suite green (`bats tests/*.bats tests/orchestration/*.bats`); `shellcheck` clean; JSON manifests valid.
6. `plugin.json` bumped (fix → patch) from current `main` (baseline `1.10.1` → `1.10.2`; re-fetch `main` immediately before bumping, since concurrent PRs move it — compute from main's then-current version).
7. A `docs/log/` entry records the auto-close-vectors analysis, the `Refs` decision, and rejected alternatives.

## Non-goals
- Changing the QA lane's pass/fail logic or the Reviewer's merge→`status:qa` transition (both already correct).
- Reopening already-wrongly-closed issues (a one-off data cleanup, not a code change) — out of scope; the fix prevents recurrence.
- Engine script changes; this is instructions + conventions + a content-invariant test.
- Per-branch-strategy nuance (auto-close only fires for PRs to the default branch): the `Refs` change is correct for all strategies and removes the footgun uniformly, so no branch-strategy-specific handling is added.
