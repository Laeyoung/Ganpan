# Collect PR inline review comments + review summaries in trusted-answers.sh (#47)

- **Date:** 2026-06-25
- **Issue / PR:** #47 / (this PR)
- **Type:** feat

## What changed
`trusted-answers.sh` now collects two additional sources beyond the issue-thread and PR-conversation comments it already read:
- `pulls/<pr>/comments` — code-line **inline review comments** (`source: pr-review-comment`)
- `pulls/<pr>/reviews` — **review summaries** (`source: pr-review`, `body` only)

They flow through the same bot-exclusion, issue-thread cutoff, and per-author trust gate, so a trusted reviewer answering via "Submit review" or a code-line comment now reaches the decision-gate / rework path.

## Why
#15 follow-up: a trusted user's answer left as a GitHub review or inline code comment was never collected, so the decision gate / rework path could not be unblocked by it. (#15 item #2; originally #6.)

## Key decisions
- **Review summaries use `submitted_at`, not `created_at`,** and expose no `updated_at` — so `pr-review` items are timestamped on `submitted_at` and always `edited:false`. An **empty-body review** (a bare APPROVE/REQUEST_CHANGES with no text) is not an answer and is dropped.
- **Cutoff stays issue-thread-scoped.** Gate-lifecycle markers (`rework-requested:`/`decision-*`) live on the issue thread; a PR-side marker must not shift the window. The new sources are filtered by that same cutoff.
- **Memoization came for free.** The existing trust filter already resolves each *distinct* author exactly once (`unique` before the `is_trusted` loop). Routing inline/review items through the same candidate pool means a reviewer who leaves many code-line comments triggers exactly one permission lookup — verified by a new test asserting `grep -c collaborators/<user>/permission == 1`.
- **Normalized all sources to one shape before filtering** so bot/cutoff/trust logic is uniform across the four inputs.

## Alternatives considered (not chosen)
- **Compute `edited` for reviews** — the reviews endpoint exposes no `updated_at`, so edit detection isn't available; defaulting `edited:false` is honest and reviews are rarely edited.
- **Include empty-body approvals as "proceed" answers** — rejected: a bare approval carries no classifiable text; the Reviewer's own judgment + explicit text answers drive routing.

## Verification
- `tests/orchestration/trusted-answers.bats` — expanded to **24 cases**: every prior test updated for the new gh-call ordering (two extra reads), plus new cases for inline collection, review-summary collection (submitted_at/edited), empty-body drop, cutoff+bot honoring on the new sources, untrusted inline reviewer, two new API-failure paths, and the single-lookup memoization assertion.
- Full suite (171) green; shellcheck clean; manifests valid. feat → minor bump 1.6.0 → 1.7.0.
