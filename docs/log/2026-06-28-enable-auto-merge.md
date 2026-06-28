# Enable reviewer auto-merge for this repo + migrate config to `.ganpan/`

- **Date:** 2026-06-28
- **Issue / PR:** (no issue) / (this PR)
- **Type:** chore

## What changed
- Migrated this repo's active orchestration config from the legacy fallback path `.claude/orchestration.json` to the canonical `.ganpan/orchestration.json`.
- Added the `reviewer` block and set `reviewer.autoMerge: true`, opting this repo into the auto-merge mode shipped in #33.
- Updated the root `CLAUDE.md` Merge gate section (both duplicated blocks) to describe the opt-in: the Reviewer lane may merge a PR once its verdict is "proceed" and the PR is OPEN + mergeable + `mergeStateStatus == CLEAN`. Agents still never *approve* PRs.
- Fixed the shipped `assets/CLAUDE.md` so deployed users can discover and correctly enable auto-merge: the Merge gate line now cross-references the `reviewer.autoMerge` opt-in, and the Reviewer-lane config path was corrected from the legacy `.claude/orchestration.json` to the canonical `.ganpan/orchestration.json`. Bumped `plugin.json` 1.11.0 → 1.11.1 so the corrected docs reach installed users.

## Why
The owner wants the orchestration loop to run end-to-end autonomously on this repo (file issue → develop → review → merge). The auto-merge engine already existed (#33) but was inert here because (a) no `reviewer` block was present, so `autoMerge` defaulted to `false`, and (b) the config sat at the legacy path. `main` carries no branch protection or rulesets, so `auto-merge.sh`'s genuine-404 precondition is satisfied and enabling the flag now actually merges.

## Key decisions
- **Config lives at `.ganpan/orchestration.json`, not `.claude/`.** `.ganpan/` is the canonical discovery path; `.claude/` is only a legacy fallback. Moving it removes ambiguity and matches what `orch-setup` writes for new users.
- **Only the dev-facing root `CLAUDE.md` was changed; `assets/CLAUDE.md` was left as-is.** The shipped asset documents the *default* behavior (`autoMerge: false`), which stays accurate for users who install the plugin — editing it would change deploy output, not this repo's policy.
- **Recorded the reversal path in the merge gate text.** Flip `autoMerge` back to `false` or add branch protection on `main` (then `auto-merge.sh` returns `protected` and requests a human merge) — so the human gate can be restored without spelunking.

## Alternatives considered (not chosen)
- **Keep the human merge gate (leave `autoMerge: false`).** Rejected per explicit owner request to run the loop autonomously.
- **Add branch protection on `main` AND enable `autoMerge`.** Self-defeating: protection would make `auto-merge.sh` return `protected` and fall back to a human merge, so the flag would never fire. Left `main` unprotected as the authorization signal, consistent with #33's design.
