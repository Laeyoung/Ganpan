# README: auto-mode guide + new commands (#64)

- **Date:** 2026-06-29
- **Issue / PR:** #64 / (PR pending)
- **Type:** docs

## What changed

Updated `README.md`:
- Added the newer lane commands to the command table: `/ganpan:work-issue-deep`
  (deep Coder), `/ganpan:review-queue-deep` (deep Reviewer), `/ganpan:update`
  (advisory version check), with a note on the `-deep` variants and their
  Superpowers/`*-review-loop` requirement.
- Added a **"무인 운영 (auto mode)"** section: how to run lanes unattended under
  `/loop` — a `.claude/settings.json` `permissions.allow` allowlist for the bot
  writes (`gh`/`git`/orchestration scripts), edit auto-accept, and the safety
  gates that remain in force (agents never merge; the per-lane bot-actor check;
  `GH_TOKEN` requirement). Includes a note that external-system writes like
  `gh api --method DELETE` are gated harder by the safety classifier and need an
  explicit allow rule.
- Documented the #66 behavior: standard lanes dispatch each `/loop` tick's work
  to a disposable subagent so the main session's context stays small.

## Why

#64 asked for the README to be brought current: an auto-mode setup guide and the
new command content. The command table had drifted (missing the deep variants
and `update`), and there was no guidance for the unattended-operation that
`/loop` assumes — the most common real-world failure mode is permission prompts
stalling an unattended loop.

## Key decisions

- **Permission allowlist as the primary auto-mode mechanism** (over
  `--dangerously-skip-permissions`): narrower, safer, and matches how the lanes
  actually run. Called out that destructive external writes stay gated.
- **Colon-form permission patterns** (`Bash(gh issue:*)`): the documented
  Claude Code prefix-match wildcard. (A review pass flagged a space form; that
  was a false positive — the colon `:*` form is correct.)
- **No version bump:** the change is `README.md` at the repo root, not a shipped
  artifact under `plugins/`, so the SemVer/plugin-cache rule does not apply.

## Alternatives considered (not chosen)

- A separate `docs/AUTO_MODE.md` — kept it inline in the README so the
  unattended-operation guidance sits next to the lane-execution section where
  readers look first.
- Recommending `--dangerously-skip-permissions` — rejected; an allowlist is the
  safer default and preserves the classifier gate on destructive writes.

## Process note

The Coder lane could not claim #64 through the normal path: #64 was poisoned by
4 orphaned `claim:` comments (the pre-fix `claim.sh` could not delete a loser's
comment — fixed in #68/PR #70 but not yet deployed to the running cache). With
no remote `issue-64` branch or PR and no possible claim, this change was made
directly on a fresh `issue-64` branch at the user's direction, right-sizing the
deep ceremony for a low-risk docs update (implementation + one accuracy-review
pass + this log). The orphaned #64 claim comments still need a one-time cleanup
by a permitted actor before the standard lane can claim it.
