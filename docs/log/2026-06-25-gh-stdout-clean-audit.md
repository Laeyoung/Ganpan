# Audit engine scripts for gh-stdout leaks; codify keep-stdout-clean convention (#29)

- **Date:** 2026-06-25
- **Issue / PR:** #29 / PR #46 (supersedes the earlier partial attempt on the same branch)
- **Type:** fix + docs + test

## What changed
- **Audited** every `scripts/orchestration/` script that is captured via `$(…)` for stdout leaks from mutating `gh` calls. Conclusion: **every currently-captured script is already clean** — `claim.sh` (fixed in PR #28), `auto-merge.sh` (isolates `gh pr merge` via `merge_out=$(… 2>&1)`), and the read/compute-only ones (`unblock-check.sh`, `trusted-answers.sh`, `decision-resolve.sh`, `followup-dedup.sh`) make no mutating `gh` call and so have no leak vector.
- **`reclaim.sh`:** redirected its mutating `gh issue edit/comment` writes to `>/dev/null` (both the open-PR → `blocked` and no-PR → `agent-ready` branches). They previously leaked the resource URL to stdout — cosmetic today (reclaim runs bare, not captured), but a latent corruption if a future caller wraps it in `$(…)`.
- **`lib.sh` `project_sync`:** redirected its trailing `gh project item-edit` write to `>/dev/null` for the same future-proofing reason (called bare by lanes today, never captured).
- **CLAUDE.md Gotchas:** codified the convention — engine scripts whose stdout is a captured return value keep mutating `gh` write output off stdout (`>/dev/null` or captured into a local), diagnostics go through `log` (stderr), with the explicit `bootstrap-labels.sh` human-facing-output exception.
- **Tests:** extended the `GH_EMIT_WRITE_URL` regression pattern to the scripts that actually exercise the convention. `gh-stub.sh` now also emits a write URL for `pr merge`; `auto-merge.bats` gained a guard asserting its captured stdout stays exactly `merged` (proven to bite by temporarily dropping the `2>&1` isolation); `reclaim.bats` gained two tests asserting empty, `STUB-URL`-free stdout on both reclaim branches.
- **Version:** `plugins/orchestration/.claude-plugin/plugin.json` bumped to `1.7.1` (fix → patch). Originally `1.6.0 → 1.6.1`, recomputed to `1.7.1` after rebasing onto `main` (which a sibling PR had advanced to `1.7.0`), per the reviewer's rework request.

## Why
Follow-up from #4 / PR #28, which fixed `ISSUE=$(claim.sh)` capture corruption by redirecting `gh` write URLs. The Reviewer flagged that the same bug class is latent in every captured engine script, and the convention was never written down — so a new script (or a newly-captured existing one) could silently reintroduce it.

## Process
Built via the deep workflow: spec (`docs/superpowers/specs/2026-06-25-gh-stdout-leak-audit.md`) → document-review-loop → plan (`docs/superpowers/plans/2026-06-25-gh-stdout-leak-audit.md`) → document-review-loop → TDD implementation → dev-review. The spec review caught that the `gh-stub` did not cover `pr merge`, which would have made the `auto-merge` guard test pass trivially — hence the stub extension.

## Key decisions
- **Fix `reclaim.sh` and `project_sync` even though they aren't captured today** — defends the convention so the contract can't rot, and keeps a sweep's stdout log-free. Low cost, removes a latent trap.
- **Document in the repo-root CLAUDE.md Gotchas** (not `assets/CLAUDE.md`, which ships to users) — this is a contributor convention for editing engine scripts, so it belongs in the dev contract doc.
- **Reuse the existing `GH_EMIT_WRITE_URL` gh-stub knob** for the regression tests instead of inventing a new mechanism — consistent with the `claim.bats` stdout-clean test. Extending it to `pr merge` was the minimal change needed to make the `auto-merge` guard meaningful.
- **Test only the mutating-`gh` captured scripts** (`auto-merge`, `reclaim`) — the read-only captured scripts have no leak vector, so a `GH_EMIT_WRITE_URL` test on them would be a trivial no-op; the audit is their verification.

## Alternatives considered (not chosen)
- **Add a CI lint that greps for unredirected `gh … edit/comment/create`** — rejected for now: high false-positive rate (read calls, already-redirected calls, multi-line chains) for a bug class that is currently empty. The documented convention + per-script regression tests are enough; revisit if a leak recurs.
- **Leave `reclaim.sh`/`project_sync` as-is and only document** — rejected: leaves real (if dormant) leaks that contradict the convention being codified in the same change.
- **Fix `bootstrap-labels.sh` too** — rejected: its stdout is intentional human-facing setup progress, not a captured return value. Documented as the explicit exception.
- **Add `GH_EMIT_WRITE_URL` tests to the read-only captured scripts** — rejected: no mutating-`gh` leak vector, so the test would be trivially green and carry no regression value.
