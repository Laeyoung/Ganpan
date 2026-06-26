# work-issue-deep: base-conflict resolution parity (#58)

- **Date:** 2026-06-26
- **Issue / PR:** #58 / PR #61
- **Type:** fix (bug)

> **Rework (2026-06-26):** rebased onto `main` (advanced to `1.10.0` via PR #54); only `plugin.json` conflicted → re-bumped to **`1.10.1`** (fix → patch) per the reviewer. The conflict-resolution edits merged cleanly with main. Full suite green (187 tests).

## What changed
- `commands/work-issue-deep.md`'s rework-resume path (5g) now runs `conflict-resolve.sh main` before the 5f re-verify and handles its three outcomes (`up-to-date` / `resolved` / `conflict`), mirroring `work-issue.md` step 5.
- Step 9 gains the "**Skip this whole step** if 5g escalated an unresolved `conflict`" clause (still stops the heartbeat), mirroring `work-issue.md` step 9.
- Regression test in `tests/codex-skills.bats` asserts the invariant (5 greps: the invocation, all three outcomes, and the step-9 skip).

## Why
The deep lane called `conflict-resolve.sh` **zero** times. When the Reviewer routed a `CONFLICTING` PR to the deep lane (`rework-requested: base 충돌 해소 필요`), the lane never even attempted a clean 3-way auto-merge — the conflict persisted and the next Reviewer tick re-routed it to rework: an **infinite loop**. This hit #49/PR #53 (human had to intervene) and recurred in this session's #29/#56 reworks, which I resolved by *manual* `git merge` inside the lane rather than via the lane's own protocol — exactly the gap this fixes.

## Key decisions
- **Mirror `work-issue.md` verbatim** (adapted to 5g/step-9 numbering) so the two lanes stay in lockstep — a divergent copy would drift.
- **On a genuine `conflict`: keep `status:in-progress` + skip the step-9 transition** (don't post `rework-resolved:`, don't move to `status:in-review`). Parking the issue *outside* the Reviewer's `status:in-review` input domain is what breaks the loop; moving it back to in-review would just re-trigger rework.
- **Run conflict-resolve BEFORE the 5f re-verify** so tests validate the merged tree, not stale pre-merge code.
- **Keep base = `main`** for parity with `work-issue.md` (generalizing both lanes to `$INTEGRATION_BRANCH` is a separate follow-up).
- **Test via grep content-invariant** — `work-issue-deep.md` is LLM instructions, not executable; the 5-grep test (incl. `merged in cleanly` for the `resolved` branch and `Skip this whole step` for the loop-prevention skip) guards every required behavior.

## Alternatives considered (not chosen)
- **Inline raw `git merge`** instead of `conflict-resolve.sh` — rejected: duplicates the conservative-merge logic and risks hand-resolving conflict markers.
- **Move a conflicted resume back to `status:in-review`** — rejected: re-triggers the rework loop.
- **Generalize base to `$INTEGRATION_BRANCH` now** — rejected: out of scope; do it for both lanes together later.
- **Mirror into a Codex deep skill** — N/A: no `ganpan-work-issue-deep` skill or shared reference exists (work-issue-deep is Claude-command-only).
