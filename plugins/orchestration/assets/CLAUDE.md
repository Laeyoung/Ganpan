# Repo conventions

## Commits (Conventional Commits — required)
Format: `type(scope): subject`
- `type` ∈ feat, fix, docs, refactor, test, chore, perf, build, ci.
- Body explains **what changed and why** (not "수정했습니다").
- Footer references the issue with a non-closing reference: `Refs #<n>` (QA owns the terminal close — an auto-closing keyword would close the issue on merge and skip qa-check).

## Branches / worktrees
- One issue → branch `issue-<n>` → worktree `../wt-issue-<n>`.
- Never force-push or delete another worker's `wt-issue-*` branch.
- **Branch strategy** (`branchStrategy.integrationBranch`): the branch Coder-lane feature PRs target. Two policies:
  - **git-flow** (what the shipped config template selects): set `integrationBranch: "develop"` — `main` is your production line, day-to-day work integrates into `develop`. **Create the `develop` branch on the remote first**; the Coder lane stops with a clear error if it is missing.
  - **trunk / release-branch**: set `integrationBranch: "main"` (or omit `branchStrategy` entirely) — feature PRs target `main`. **Omitting the block defaults to `main`**, so do not delete the block or your integration branch silently reverts to `main`.
  - Release/tag/version automation for the production line is not built yet (tracked separately).

## Merge gate
- By default agents never approve or merge PRs — a human reviews and merges (branch protection enforces this). To let the Reviewer auto-merge passing PRs instead, opt in via `reviewer.autoMerge` (see "Reviewer lane — decision gate" → Auto-merge below).

## Bot identity
- Lanes verify `gh` is acting as `config.bot` before any write and **hard-stop** otherwise. Export the bot's fine-grained PAT first: `export GH_TOKEN=github_pat_...` (HTTPS). If a lane stops with "gh is acting as '<you>' but config.bot is '<bot>'", your `GH_TOKEN` is unset or wrong.
- `ORCH_SKIP_ACTOR_CHECK=1` bypasses the check — use it **per-invocation only** (e.g. CI where the bot PAT is the actor), never as a global export.

## Reviewer lane — decision gate
- The Reviewer reads **trusted** human PR/issue comments (write+ permission or reviewer allowlist) and routes each in-review PR to rework / a human-decision gate (`status:needs-decision`) / an out-of-scope follow-up issue / a human merge request.
- Only bot-authored markers (`decision-requested:`/`decision-resolved:`/`decision-clarify:`/`followup-created:`/`cap-exceeded:`/`merge-requested:`) change lane state. Human text never does.
- Trust/cap policy lives in `.ganpan/orchestration.json` under `reviewer` (`permissionThreshold`, `allowlist`, `followupIssueCapPerPR`).
- **Auto-merge** (`reviewer.autoMerge`, default `false`): when `true`, the Reviewer auto-merges a PR that passes review (verdict not rework/needs-decision/followup, PR `OPEN`+`MERGEABLE`+`CLEAN`) **only if you have removed branch protection on `main`** — the agent never bypasses an active gate. If the flag is on but `main` is still protected, it does not merge and the PR comment tells you to disable protection. Leave it off to keep human-merge-only.
- **Private repo on a Free plan?** The branch-protection API (`repos/:repo/branches/:base/protection`) is a paid feature: on a **private** repo under GitHub **Free**, it always returns `403 "Upgrade to GitHub Pro or make this repository public…"` regardless of whether protection exists. Auto-merge treats that as an inconclusive probe and fails **closed** (`protect-check-failed`), so `reviewer.autoMerge` never completes and the PR sits in `in-review` indefinitely. Fixes, cheapest first: (1) make the repo public, or (2) upgrade to GitHub Pro/Team so real protection becomes configurable, or (3) if you accept that a Free private repo *cannot* have branch protection, opt in with `reviewer.autoMergePrivatePlanWorkaround: true` — the Reviewer then treats **only** that exact 403 as "unprotected" and auto-merges. This is a deliberate, per-repo opt-in (default `false`); every other inconclusive probe (5xx, missing scope, any other 403) still fails closed, and a repo that actually supports protection never emits that message, so a real gate is never bypassed.
