# Opt-in reviewer auto-merge (#33)

- **Date:** 2026-06-24
- **Issue / PR:** #33 / (this PR)
- **Type:** feat

## What changed
Added an opt-in `reviewer.autoMerge` mode (default `false`). When enabled, the Reviewer lane auto-merges a PR that passes review instead of only requesting a human merge. New pieces:
- `reviewer.autoMerge` config key (`lib.sh` exports `REVIEWER_AUTO_MERGE`; `assets/orchestration.json` ships it as `false`).
- `scripts/orchestration/auto-merge.sh <PR>` — the gated merge engine.
- Reviewer R-D (command + shared reference + Codex copy) calls `auto-merge.sh` on the proceed verdict; on `merged` it skips the human-merge request and lets the existing `mergedAt`-set transition move the issue to QA.
- `assets/CLAUDE.md` documents the flag and its branch-protection precondition.
- `tests/orchestration/auto-merge.bats` (6 cases).

## Why
Owner request (#33): with auto mode on, a user files issues and the system develops, reviews, and merges autonomously. This collides with the repo's hard "agents never merge" invariant, so the owner decided the conditions in triage (recorded on the issue).

## Key decisions
- **Merge only when branch protection on `main` is OFF.** `auto-merge.sh` probes `gh api repos/$REPO/branches/main/protection`; a 200 (protected) → emit `protected` and do **not** merge (R-D posts a one-time PR advisory telling the human to disable protection). Only a 404 (human removed the gate) lets it merge. This keeps the "agent never bypasses an active gate" invariant intact — the human's explicit removal of protection is the authorization.
- **Conservative readiness gate: `OPEN` + `MERGEABLE` + `mergeStateStatus == CLEAN`.** CLEAN already means no conflicts, not behind base, and no failing/pending checks; `UNSTABLE`/`DIRTY`/`BEHIND`/`UNKNOWN` all fall to `not-ready` (no merge, retry next tick). This satisfies the owner's "CI 통과 + ambiguous → don't merge" without re-implementing per-check inspection.
- **Reviewer-verdict gate is upstream.** `auto-merge.sh` is only invoked from R-D (the proceed path), so rework/needs-decision/followup verdicts never reach it. The script self-gates on the mechanical conditions (flag, protection, readiness) and `require_bot_actor` (a real merge is a write).
- **`merged` reuses the existing `mergedAt`-set transition** (→ `status:qa`), so auto-merged PRs still flow through QA — no separate done path.

## Alternatives considered (not chosen)
- **Flip branch protection settings for the bot when the flag is on** — rejected: repo-admin territory and exactly the kind of gate-bypass the invariant forbids. Requiring the human to disable protection keeps authorization explicit.
- **Inspect `statusCheckRollup` per check instead of `mergeStateStatus`** — rejected: `CLEAN` already encodes "no failing/pending checks + mergeable + not behind" conservatively, with far less surface area.
- **`--squash` as the merge method** — left as `--merge` default, overridable via `AUTO_MERGE_METHOD`; no owner preference stated.

## Follow-up fixes (code review, 2026-06-24)
A workflow code review of the feature surfaced several defects, fixed in the same branch:
- **Fail-open protection gate → fail-closed.** The probe branched on `gh api …/protection`'s exit code alone, so a 403 (a non-admin bot PAT lacking `Administration: read` — the repo's own recommended setup), a 5xx, a rate-limit, or a network blip all looked like the 404 "unprotected" case and let the agent merge past an **active** gate. Now only a confirmed 404 ("Branch not protected") proceeds; any other non-zero exit emits a new `protect-check-failed` token (exit 2) and merges nothing. Decision: an inconclusive probe must fail closed — guessing "unprotected" is the one error this feature exists to prevent.
- **Probe the PR's real base, not a hardcoded `main`.** `auto-merge.sh` now reads `baseRefName` and checks protection on the branch the PR actually targets, so a PR against a protected non-`main` base can't slip through an unprotected `main` probe. (Latent today — the Coder always opens `--base main` — but the engine script is standalone.)
- **Surface merge/operational failures instead of swallowing them.** `gh pr merge` / `gh pr view` failures (e.g. `--merge` on a squash-only repo) now log the reason; the reviewer lane routes `error`/`merge-failed`/`protect-check-failed` to a one-time `automerge-error:` note and waits, rather than collapsing them into a benign `merge-requested:` (which masked the failure and told the human to merge as if nothing were wrong).
- **`not-ready:` no longer requests a manual merge.** A PR with checks still pending was being told "merge manually (자동 머지 아님)" even though auto-merge would complete it next tick; the lane now just waits on `not-ready*`.
