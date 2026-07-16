# QA owns the issue close — no auto-close on merge (#63)

- **Date:** 2026-06-27
- **Issue / PR:** #63 / PR (this PR)
- **Type:** fix (bug)

## What changed
Replaced the GitHub auto-closing keyword `Closes #<ISSUE>` with a **non-closing** `Refs #<ISSUE>` in every Coder-lane "merge-bound artifact" and the commit convention:
- PR bodies: `commands/work-issue.md`, `commands/work-issue-deep.md`.
- Commit footer: `commands/work-issue.md`, `references/lanes/work-issue.md` + its Codex copy.
- Commit convention: `assets/CLAUDE.md` (shipped), repo `CLAUDE.md` (both duplicated blocks), and `README.md`.
- Corrected the `qa-check` comments (command + reference + Codex copy) to state the new non-closing design.
- Regression test in `tests/codex-skills.bats` asserts the seven files carry no `Closes #` and the lane files use `Refs #`.

## Why
The intended lifecycle is **merge → Reviewer moves issue to `status:qa` → `qa-check` runs → QA closes on pass**. But the Coder lanes injected `Closes #n` in the PR body **and** commit footer, so merging to the default branch (`main`) **auto-closed the issue at merge**, before QA. Empirically #29/#58 were `CLOSED/COMPLETED` at merge and QA only ran afterward on already-closed issues. Worst case: a later **QA failure** sets `status:in-progress`+rework but can't reopen the already-closed-as-completed issue. `qa-check.md` already declared "QA owns the terminal close — don't rely on a PR's Closes keyword", so the lanes were contradicting the documented design.

## Auto-close vectors (analysis)
- A merged PR whose **body/title** has `Closes #n` auto-closes #n iff the PR targets the **default branch**.
- A commit message with `Closes #n` auto-closes when it lands on the default branch (clearest with squash-merge). Both vectors fire for the default/main-integration case (this repo). Non-closing `Refs #n` keeps the `#n` timeline autolink without closing.

## Key decisions
- **`Refs #n`** (non-closing) preserves issue↔PR/commit traceability (the autolink comes from the bare `#n`) while letting QA own the close.
- **Neutralize both vectors** (PR body + commit footer) — strategy-independent and safe even where only one would fire.
- **Change the repo's own `CLAUDE.md`/`README.md` too**, not just shipped `assets/CLAUDE.md` — ganpan dogfoods the same lanes, so its own issues must not auto-close either.
- **Don't change the QA lane's close-on-pass** (already correct) — only correct its now-accurate comment.

## Alternatives considered (not chosen)
- **Keep `Closes` and have QA reopen** on the close — fragile, races the merge, leaves a flicker of wrong state.
- **Fix only the PR body** — the commit footer still auto-closes on squash-merge.
- **A CI lint** instead of changing the lanes/convention — doesn't fix the deployed lane behavior.
- **Reopen the already-wrongly-closed issues (#29/#58/…)** — one-off manual data cleanup, out of scope; this fix prevents recurrence.
