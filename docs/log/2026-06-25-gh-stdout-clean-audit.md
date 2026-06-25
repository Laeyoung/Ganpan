# Audit engine scripts for gh-stdout leaks; codify keep-stdout-clean convention (#29)

- **Date:** 2026-06-25
- **Issue / PR:** #29 / (this PR)
- **Type:** fix + docs + test

## What changed
- Audited every `scripts/orchestration/` script that is (or could be) captured via `$(…)` for stdout leaks from mutating `gh` calls. Found the bug class already contained everywhere a script's stdout is actually a return value (`claim.sh`, `heartbeat.sh`, `followup-dedup.sh`, `trusted-answers.sh`, `decision-resolve.sh`).
- **`reclaim.sh`:** redirected its four mutating `gh issue edit/comment` writes to `>/dev/null`. They previously leaked the resource URL to stdout — cosmetic today (reclaim runs bare, not captured), but a latent corruption if a future caller wraps it in `$(…)`.
- **CLAUDE.md Gotchas:** codified the convention — "engine scripts keep stdout clean; redirect every mutating `gh` write to `>/dev/null`; diagnostics go through `log` (stderr)."
- **reclaim.bats:** added a `GH_EMIT_WRITE_URL=1` regression test asserting no leaked `STUB-URL` reaches reclaim's stdout while the writes still happen.

## Why
Follow-up from #4 / PR #28, which fixed `ISSUE=$(claim.sh)` capture corruption by redirecting `gh` write URLs. The Reviewer flagged that the same bug class is latent in every captured engine script, and the convention was never written down — so a new script (or a newly-captured existing one) could silently reintroduce it.

## Key decisions
- **Fix `reclaim.sh` even though it isn't captured today** — defends the convention so the contract can't rot, and keeps a sweep's stdout log-free. Low cost, removes a latent trap.
- **Document in the repo-root CLAUDE.md Gotchas** (not `assets/CLAUDE.md`, which ships to users) — this is a contributor convention for editing engine scripts, so it belongs in the dev contract doc.
- **Reuse the existing `GH_EMIT_WRITE_URL` gh-stub knob** for the regression test instead of inventing a new mechanism — consistent with the `claim.bats` stdout-clean test.

## Alternatives considered (not chosen)
- **Add a CI lint that greps for unredirected `gh … edit/comment/create`** — rejected for now: high false-positive rate (read calls, already-redirected calls, multi-line chains) for a bug class that is currently empty. The documented convention + per-script regression test is enough; revisit if a leak recurs.
- **Leave `reclaim.sh` as-is and only document** — rejected: leaves a real (if dormant) leak that contradicts the convention being codified in the same change.
