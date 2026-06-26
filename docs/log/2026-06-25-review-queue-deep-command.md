# Add the review-queue-deep Reviewer command (#50)

- **Date:** 2026-06-25
- **Issue / PR:** #50 / (this PR)
- **Type:** feat

## What changed
Added `plugins/orchestration/commands/review-queue-deep.md`, a deep variant of the Reviewer lane — the review-lane analogue of `work-issue-deep` (#38). It keeps the Reviewer's full decision-gate / 4-way-routing contract (Steps B–F, R-A/R-B/R-C/R-D, conflict routing, auto-merge) but replaces **Step A** (single-pass self-review) with a **multi-pass, report-only agents-team review** of the PR diff (`/dev-review`, plus `/qa-review` when runnable), iterated until findings stabilise. Registered in `install.sh`'s copy-in command list and asserted in `install.bats`.

## Why
Issue #50: apply the `work-issue-deep` pattern (agents team + loop + multi-pass verification) to the Reviewer lane for higher-assurance reviews. Triage recommended reusing the existing review-loop skills and the Reviewer's 4-way routing for consistency.

## Key decisions
- **Report-only skills, not the auto-fixing `-loop` variants.** The Reviewer invariant is that it never edits the PR — the Coder applies fixes on rework. So the deep review uses `/dev-review` / `/qa-review` (report-only) and routes confirmed defects to **R-A (rework)**; it explicitly does **not** use `/dev-review-loop` / `/qa-review-loop`, which auto-fix and would mutate the PR branch. (This diverges from the triage's literal skill names but preserves the lane's safety invariant — the "loop" is achieved by iterating the report-only review until findings stabilise.)
- **Reuse the contract, override only Step A.** Rather than duplicate the ~185-line routing protocol, the command points at `review-queue` (reference + command) for Steps B–F and all routing, and specifies only the deep Step-A procedure. The deep verdict is exactly the blocking/non-blocking input Step A already feeds into routing, so every marker, gate, and transition is unchanged.
- **Claude-only — no Codex copy.** It orchestrates Claude/Superpowers review skills with no Codex equivalent; `codex-skills.bats`'s fixed lane list does not include it, so no Codex artifact is required.
- **Anti-injection preserved.** A finding derived from attacker-controlled diff content may only ever route to R-A — never to R-C issue creation or a merge, identical to the base lane.

## Alternatives considered (not chosen)
- **Use `/dev-review-loop` (auto-fix) in the Reviewer** — rejected: it would edit/commit/push to the PR branch, breaking the human-in-the-loop merge gate and the Coder-owns-fixes split.
- **Duplicate the whole routing protocol into the deep command** — rejected: drift risk; delegating to `review-queue` keeps one source of truth.

## Verification
- `install.bats` asserts `review-queue-deep.md` is installed; install smoke confirms it copies path-clean with exactly one version sentinel.
- Full suite (163) green; shellcheck clean; manifests valid. feat → minor bump 1.6.0 → 1.7.0.
- Note (same caveat as #38): the command is validated structurally (lane contract, clean install, references only skills that exist); a full end-to-end deep-review run is best exercised by invoking `/ganpan:review-queue-deep` against a real in-review PR.
