# Add the work-issue-deep Coder command (#38)

- **Date:** 2026-06-24
- **Issue / PR:** #38 / (this PR)
- **Type:** feat

## What changed
Added `plugins/orchestration/commands/work-issue-deep.md`, a heavyweight variant of the Coder lane. It keeps the same claim / WIP-gate / heartbeat / label-transition contract as `work-issue`, but replaces the single "implement" step with a spec-first, plan-driven, review-looped workflow: `/superpowers:writing-plans` (spec) → `/document-review-loop` → `/superpowers:writing-plans` (plan) → `/document-review-loop` → `/superpowers:executing-plans` → `/dev-review-loop`, committing after every phase. Registered it in `install.sh`'s copy-in command list and added an `install.bats` assertion that it is installed.

## Why
Larger or higher-risk issues benefit from an explicit spec → plan → review pipeline rather than a single implement pass. Issue #38 specified that exact workflow and asked for it as a separate command so the standard `work-issue` stays lightweight.

## Key decisions
- **Claude-only command, no Codex skill copy.** The workflow orchestrates Claude/Superpowers-only skills (`/superpowers:*`, `/document-review-loop`, `/dev-review-loop`) that do not exist on the Codex surface. The `codex-skills.bats` fixed lane list does not include it, so no Codex artifact is required or added.
- **Reused the `work-issue` worktree + mandatory background heartbeat.** The deep flow is long-running; the heartbeat must wrap the entire workflow (steps 4–9) so `reclaim.sh` does not steal the claim mid-run. Commit-after-every-phase keeps intermediate work on the branch and reclaim-safe.
- **Stored spec/plan/log under `docs/superpowers/{specs,plans}` and `docs/log/`** per the CLAUDE.md "Development workflow & history" convention (#35), so the deep command dogfoods the repo's own history convention.
- **Added it to `install.sh`'s explicit command list** (not a glob) so copy-in installs get it; the existing path-drift guard already covers the new file.

## Alternatives considered (not chosen)
- **Extend `work-issue` with a `--deep` flag / mode** — rejected: a slash command takes no args cleanly, and a single file mixing both flows would bloat the lightweight path. A separate command keeps each focused.
- **Ship a Codex `ganpan-work-issue-deep` skill too** — rejected: the orchestrated review/plan skills are Claude-only, so a Codex copy could not run the workflow.
- **Use `/superpowers:brainstorming` for the spec step** — deferred to the issue's explicit instruction to use `/superpowers:writing-plans` for both the spec and the plan documents.
