# Spec: work-issue-deep — add base-conflict resolution to the rework-resume path

- **Issue:** #58
- **Date:** 2026-06-26
- **Type:** fix (bug)

## Problem

The deep Coder lane (`commands/work-issue-deep.md`) is missing the base-conflict auto-resolution step that plain `work-issue.md` has. `work-issue.md` calls `conflict-resolve.sh` once (step 5, "Conflict resolution (resume only)"); `work-issue-deep.md` calls it **zero** times — its rework-resume path (5g) only reads the reviewer narrative, makes the requested change, and re-verifies (5f).

**Symptom (infinite-loop risk):** when the Reviewer routes a `CONFLICTING` PR to the deep lane with `rework-requested: base 충돌 해소 필요`, the deep lane never runs `conflict-resolve.sh` — so even a clean 3-way auto-merge is never attempted, the conflict persists, and the next Reviewer tick re-routes it to rework again. This bit #49 / PR #53, where the conflict had to be resolved by a human (and recurred across this session's #29/#56 reworks, which were resolved by manual `git merge` inside the lane rather than by the lane's own protocol).

## Goal

Bring `work-issue-deep.md`'s rework-resume path to parity with `work-issue.md`'s conflict handling: on a resume (`$PR` set), run `conflict-resolve.sh main` and branch on its three outcomes exactly as `work-issue.md` does, including the loop-prevention behavior on a genuine `conflict` (escalate to a human, keep `status:in-progress`, do **not** post `rework-resolved:`).

## Constraints

- **Never rename engine internals.** Reuse `conflict-resolve.sh` as-is (do not modify it — it already returns `up-to-date` / `resolved` / `conflict`, exit 0, or `error`/exit 2 on fetch failure).
- **Mirror `work-issue.md`'s wording** for the three outcomes so the two lanes stay in lockstip (a divergent copy would risk drift) — adapted to the deep lane's step numbering (5g resume path; step 9 transition).
- The base branch passed to `conflict-resolve.sh` is `main` — matching `work-issue.md` (the conflict step predates `branchStrategy`; keeping `main` here is in-scope parity, not a regression. Generalizing both lanes to `$INTEGRATION_BRANCH` is a separate concern, out of scope).
- This change is **Claude-command-only**: there is **no** `ganpan-work-issue-deep` Codex skill and `work-issue-deep` has no shared lane reference of its own, so nothing in `plugins/ganpan-codex/` or `references/lanes/` needs mirroring. (The shared `references/lanes/work-issue.md` already carries the conflict step for the non-deep lane.)
- `work-issue-deep.md` is a shipped artifact under `plugins/` → bump `plugin.json` (fix → patch) against `main` at implementation time.
- CLAUDE.md workflow: Spec → Plan → implement; `docs/log/` entry.

## Acceptance criteria

1. `work-issue-deep.md`'s rework-resume path (5g) instructs, when `$PR` is set, running `RES=$(${CLAUDE_PLUGIN_ROOT}/scripts/orchestration/conflict-resolve.sh main)` **before** the 5f re-verify, and branches:
   - `up-to-date` → nothing to merge; continue.
   - `resolved` → `main` merged cleanly; the 5f re-verify validates the merged tree; push the merge with the rest in step 7.
   - `conflict` → escalate to a human via `gh pr comment "$PR"`, keep the issue `status:in-progress`, do **not** post `rework-resolved:`, and **skip the step 9 transition** (loop prevention) — still stop the heartbeat.
2. `work-issue-deep.md` step 9 gains the "skip this whole step if 5g escalated an unresolved `conflict`" clause (mirroring `work-issue.md` step 9), so a conflicted resume parks on the human instead of returning to `status:in-review`.
3. A regression test asserts `work-issue-deep.md`'s resume path contains the `conflict-resolve.sh` invocation and the three-outcome handling (guards against the step being dropped again). It lives alongside the existing lane-content invariants (`tests/codex-skills.bats`, the "work-issue reference preserves rework resume safety steps" test).
4. No change to `conflict-resolve.sh`, `references/lanes/`, or `plugins/ganpan-codex/` (documented as N/A above).
5. Full suite green: `bats tests/*.bats tests/orchestration/*.bats`; `shellcheck` clean (no shell files changed, but run it); JSON manifests valid.
6. `plugin.json` bumped (fix → patch) against `main` at implementation time.
7. A `docs/log/` entry records the parity fix, the loop-prevention rationale, and rejected alternatives.

## Non-goals

- Modifying `conflict-resolve.sh` or `work-issue.md` (the source of truth being mirrored).
- Generalizing the conflict base branch from `main` to `$INTEGRATION_BRANCH` in either lane (separate follow-up).
- Adding a Codex deep-lane skill (none exists).
