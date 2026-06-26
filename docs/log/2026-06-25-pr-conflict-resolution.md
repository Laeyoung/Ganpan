# Conservative PR conflict resolution for work-issue PRs (#48)

- **Date:** 2026-06-25
- **Issue / PR:** #48 / (this PR)
- **Type:** feat

## What changed
A work-issue PR that starts conflicting because `main` advanced is now brought up to date by the workflow:
- New `scripts/orchestration/conflict-resolve.sh [<base>]` (run inside the PR branch worktree): fetches base, and if the branch is behind, attempts `git merge`. A **clean 3-way auto-merge** is committed (`resolved`); an **already-current** branch is a no-op (`up-to-date`); **any real conflict** is `git merge --abort`ed and reported (`conflict`) — never hand-resolved.
- **Coder (work-issue) resume path** runs it: `resolved`/`up-to-date` → re-run tests/build and push; `conflict` → post a PR escalation comment and **stay `status:in-progress`** (no `rework-resolved:`) so it parks on a human instead of bouncing back to review.
- **Reviewer R-D** routes a `CONFLICTING` in-review PR back to the Coder as rework (guarded against re-routing mid-cycle), so the resume path fires. The Reviewer never resolves conflicts itself.

## Why
Issue #48: work-issue PRs sometimes conflict with `main` after creation, and nothing resolved them. The triage required a **conservative** design (no risky auto-merges), human escalation for ambiguous cases, re-test after resolution, and preservation of the human-merge gate.

## Key decisions
- **Only git's own 3-way merge auto-resolves.** We never write or hand-edit conflict markers — a clean merge (non-overlapping hunks) is committed; any overlap is aborted and escalated. This is exactly the triage's "safely resolvable → auto, ambiguous → escalate", with the safe set defined by git itself (lowest bad-merge risk).
- **Re-test after resolution.** On `resolved`, the resume path's existing test/build re-run validates the merged tree before pushing.
- **Merge gate intact.** The script only updates the branch; merging the PR is still a human (or the opt-in auto-merge once mergeable). No merge happens in conflict resolution.
- **Loop-safety.** Reviewer routes a conflict to rework only when no rework cycle is pending; the Coder leaves a *genuinely* unresolvable conflict `status:in-progress` (no `rework-resolved:`), so it does not return to `status:in-review` and get re-routed forever. A cleanly-`resolved` conflict pushes + posts `rework-resolved:` → back to review → now mergeable.
- **Pure-git, fixture-tested.** `conflict-resolve.sh` uses no `gh`, so its bats build a real bare-remote + diverged-branch repo and assert the working tree is clean (no markers, no in-progress merge) after an abort.

## Alternatives considered (not chosen)
- **Attempt to resolve textual conflicts (markers / `-X ours`/`theirs`)** — rejected: high bad-merge risk; the triage explicitly wants ambiguous cases escalated, not guessed.
- **Reviewer resolves the conflict in-place** — rejected: keeps conflict-handling in one lane (the Coder, which owns the branch/worktree) and avoids cross-lane git writes.
- **Rebase instead of merge** — merge chosen: it never rewrites already-pushed history (safer for an open PR branch) and its conflict/abort semantics are simple to reason about.

## Verification
- `tests/orchestration/conflict-resolve.bats` — 4 cases on a real git fixture (up-to-date, clean auto-merge `resolved`, overlapping `conflict` + aborted clean tree, fetch failure → exit 2).
- Full suite (167) green; shellcheck clean; manifests valid; install smoke copies `conflict-resolve.sh +x`. Codex reference copies byte-identical. feat → minor bump 1.6.0 → 1.7.0.
