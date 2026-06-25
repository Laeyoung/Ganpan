# Triager re-evaluates and unblocks stale blocks (#44)

- **Date:** 2026-06-25
- **Issue / PR:** #44 / (this PR)
- **Type:** feat

## What changed
The Triager lane now re-evaluates `status:blocked` issues and re-triages the actionable ones. New `scripts/orchestration/unblock-check.sh <issue#>` (read-only) decides per issue; a new triage step (command + shared reference + Codex copy) performs the label move.

## Why
Blocked issues could sit forever — notably #29 (`status:blocked` with zero comments: an actionable task blocked with no recorded reason). Issue #44 asked for logic to resolve blocks that have become actionable, and flagged three Spec decisions.

## Key decisions (the Spec questions from triage)
- **Unblock criterion.** An issue is re-triageable when EITHER (1) it has **no bot-authored comment** (stale/unexplained block) OR (2) a **trusted** human (write+ permission or reviewer allowlist) commented **after the latest bot comment** (the recorded blocker was answered). This reuses the Reviewer decision-gate trust model (`is_trusted`/`perm_rank`) for consistency. Untrusted commenters can never unblock.
- **Reason-less blocks are in scope.** The "no bot comment" branch deliberately covers #29 and follow-up issues created blocked — they get a fresh evaluation rather than sitting indefinitely.
- **Target state = `status:triage`, not `status:agent-ready`.** Unblocking only re-enters classification; the Triager's own classify step then decides agent-ready vs re-block (incorporating the human's answer / fresh read). The new step runs before the classify step so re-triaged issues are reclassified in the same run. For #29 this yields: no comment → re-triage → classify → agent-ready.
- **Boundary = latest bot comment.** ISO8601 lexicographic `max` of bot-comment timestamps; a trusted reply must be strictly after it, so a pre-existing answer followed by a newer bot question correctly stays blocked.
- **Read-only decision script.** Mirrors `followup-dedup.sh`/`decision-resolve.sh`: the script only prints a decision and the lane does the `gh issue edit`, so no actor gate is needed in the script.

## Alternatives considered (not chosen)
- **Introduce a structured `blocked:` marker** the Triager writes when blocking, and key unblock detection off it — rejected for now: it requires changing every block site and a migration; "latest bot comment as boundary" works with the existing free-text clarifying-question convention and the `reclaimed:` marker.
- **Unblock straight to `status:agent-ready`** — rejected: that would re-implement classification in the unblock path and risk shipping a still-ambiguous issue; routing through `status:triage` keeps one classifier.
- **Auto-unblock on any commenter** — rejected: an arbitrary GitHub user could force work; trust-gating matches the rest of the system.

## Verification
- `tests/orchestration/unblock-check.bats` — 7 cases (no-comment #29 case, no-bot-comment, bot-blocker-no-reply, trusted-reply, untrusted-reply, boundary-ordering, API failure).
- Full suite (163) green; shellcheck clean; manifests valid; install smoke copies `unblock-check.sh +x` for both targets.
