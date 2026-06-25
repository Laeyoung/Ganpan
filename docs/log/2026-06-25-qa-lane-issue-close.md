# QA lane explicitly closes the issue on pass

- **Date:** 2026-06-25
- **Issue / PR:** no tracking issue (direct fix from a user report) / PR #43
- **Type:** fix

## What changed
The QA lane's pass path now runs `gh issue close <n> --reason completed` in
addition to applying `status:done`, syncing the project board to `Done`, and
cleaning the worktree. Updated in the canonical lane reference
(`references/lanes/qa-check.md`), the byte-identical Codex copy, the Claude
command (`commands/qa-check.md`), and spec §6.4. Added a `codex-skills.bats`
guard asserting both the command and the reference contain `gh issue close`.
Version bumped 1.5.1 → 1.5.2.

## Why
Issues verified by QA were left **open** with only the `status:done` label
(observed on this repo: #4, #12, #13, #14, #15). Two compounding causes:

1. The orchestration never closed issues itself — `status:done` was a
   label/project-board state, not the GitHub `closed` state.
2. The intended fallback — GitHub auto-close via a PR's `Closes #<n>` keyword —
   never fired: the merged PRs (#7–#10) had empty `closingIssuesReferences` and
   no `Closes #<n>` in their **body**. Closing keywords lived only in commit
   footers, and GitHub does not reliably auto-close from commit-message keywords
   that arrive via a merge-commit PR — it honors the PR description's linked
   issues.

So nothing ever transitioned the issue to `closed`.

## Key decisions
- **QA lane owns the terminal close**, not the PR's `Closes #<n>` keyword —
  PR merge (human) and QA pass (bot) are separate events; depending on a body
  keyword the Coder lane may omit (it did) leaves issues silently open. Making
  the close part of the QA pass transition ties it to the event that actually
  proves the work is done.
- Use `--reason completed` so the timeline reflects a successful completion
  rather than a "not planned" close.
- Closing an already-closed issue is a harmless no-op, so this is safe even if a
  future PR body does carry `Closes #<n>`.

## Alternatives considered (not chosen)
- **Fix only the Coder lane to put `Closes #<n>` in the PR body.** Rejected as
  the sole fix: it re-couples issue closure to human PR-merge timing and to the
  Coder lane remembering the keyword (the exact step that was already silently
  skipped). Keeping the explicit QA close makes closure deterministic; a PR-body
  keyword would only be a redundant secondary path.
- **Add a dedicated close script under `scripts/orchestration/`.** Overkill for a
  single idempotent `gh` call; the lanes already issue inline `gh issue edit`
  writes after the actor gate, so an inline `gh issue close` fits the pattern.
