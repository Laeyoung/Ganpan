# README documents `reviewer.autoMerge` (#82)

- **Date:** 2026-08-13
- **Issue / PR:** #82 / #84
- **Type:** docs
- **Version:** 1.13.0 → 1.13.2 (docs fix → patch; 1.13.1 is claimed by #78/PR #83)

## What changed
`README.md` never mentioned `reviewer.autoMerge` (`grep -c autoMerge README.md`
→ 0) while asserting in five places that a human always merges, enforced by
branch protection. Those five sites now describe the **default** rather than an
invariant, and the config section gained a `reviewer` block plus a new
"머지 게이트와 `reviewer.autoMerge`" subsection covering the default (`false`),
the branch-protection precondition, the fail-closed probe, and the Free-plan
private-repo 403 workaround.

The five sites: the intro paragraph (line 5), the Reviewer row of the lane table,
the auto-mode safety note (§무인 운영), the merge-gate convention bullet
(§컨벤션), and the self-approval entry under §알려진 잔여 위험.

`tests/codex-skills.bats` gained a guard asserting the README documents the
opt-in (flag name, default, fail-closed) and no longer carries the four absolute
merge phrasings, while still carrying the approve invariant.

## Why
`plugins/orchestration/assets/CLAUDE.md` — shipped to every target repo alongside
the README — documents the option in detail, so the two deployed documents
contradicted each other. This repo itself runs with `autoMerge: true`, making the
README's description wrong for its own operation. A reader taking "머지는 항상
사람이" literally would conclude agent merges are structurally impossible and
mis-assess the trust model.

## Key decisions
- **Split the approve invariant from the merge default.** Agents never *approve*,
  regardless of configuration; only *merge* is configurable. The issue explicitly
  called this out, and collapsing the two would trade one inaccuracy for another.
  Every edited site now names approve separately and keeps it absolute.
- **Document the option where config lives, not inline at all five sites.** The
  five call sites get a one-clause default + pointer; the full semantics
  (precondition, fail-closed, Free-plan 403) live once in the config section,
  mirroring how `assets/CLAUDE.md` structures it.
- **Carry the Free-plan 403 caveat into the README.** It is the failure mode that
  silently strands PRs in `in-review`; a reader who opts in without it will hit a
  hang with no visible cause.
- **Version 1.13.2, not 1.13.1.** PR #83 (issue #78) is already in review with a
  1.13.1 bump from the same base. Taking 1.13.2 keeps both monotonic and avoids a
  conflicting downgrade whichever merges first. This PR sequences after #83.

## Alternatives considered (not chosen)
- **Delete the merge claims from the README and point at `assets/CLAUDE.md`.**
  Rejected: the README is the first thing an evaluator reads, and the merge gate
  is a trust-model property that belongs there.
- **Keep the absolute phrasing and instead document `autoMerge` as an advanced,
  discouraged escape hatch.** Rejected: the repo itself runs with it enabled, so
  the framing would still misdescribe real usage.
- **Update `README.md` only, no test guard.** Rejected: #82 is the same class of
  drift as #78 — a decision that never reached a documentation surface — and the
  guard is what stops it from silently reverting.
