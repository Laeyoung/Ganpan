# Spec: Configurable branch strategy (production / development separation) — foundation

- **Issue:** #56
- **Date:** 2026-06-26
- **Type:** feat

## Problem

ganpan hard-codes every Coder-lane PR to target `main` (`references/lanes/work-issue.md:23`, `commands/work-issue.md:57`, `commands/work-issue-deep.md:56`). Projects that adopt ganpan want to separate a stable **production** line from an active **development/integration** line, and to pick between two common policies:

1. **Trunk / release-branch:** `main` *is* the development line; production is cut from `main` as a release branch or tag.
2. **git-flow (the issue's stated default):** `main` is the production line; day-to-day development lands on a `develop` branch.

Today neither is possible — there is no config knob for the branch a feature PR targets, and no release automation.

## Scope decision (important)

Issue #56 spans **two independent subsystems**:

- **(A) Branch-strategy foundation** — let the user pick which branch feature PRs integrate into (this spec).
- **(B) Release automation** — when a feature is done, automate version bump, git tag, GitHub release, release notes, and doc updates, possibly via a new `/ganpan:release` command (the issue's second half).

Per the writing-plans Scope Check, (B) is a large, separable subsystem with its own design surface (versioning policy, changelog format, tag scheme, who triggers it, which lane). **This spec covers only (A)** — the prerequisite that (B) builds on (a release flow needs to know which branch is production and which is integration). (B) is **deferred to a follow-up issue** recommended in the PR body; this spec stores no config it does not use (no `productionBranch` field yet — YAGNI; it arrives with (B)).

## Goals (this PR)

1. Add an **optional** `branchStrategy.integrationBranch` config key naming the branch feature PRs target.
2. Expose it from `load_config` as `INTEGRATION_BRANCH`, **defaulting to `main` when the block is absent** — existing installs and ganpan's own repo keep targeting `main` with zero behavior change.
3. Make the Coder lane (both `work-issue` and `work-issue-deep`, the canonical reference, and the Codex skill copy) create the PR against `$INTEGRATION_BRANCH` instead of literal `main`.
4. Ship the config template and user-facing docs so a new project can choose git-flow (the recommended default for new setups: `integrationBranch: "develop"`) or trunk (`integrationBranch: "main"`).
5. Keep Codex parity and the install/sentinel path intact.

## Non-goals

- **Release automation** (version bump, `gh release`, `git tag`, release notes, doc generation) — deferred to the follow-up issue (subsystem B).
- **`staging`/beta branch management** — part of B; not modeled here.
- A `productionBranch` config field — not used by anything in this PR; added with B to avoid shipping dead config.
- Changing `auto-merge.sh` — it already reads the PR's *actual* `baseRefName` (`auto-merge.sh:46,50`) and checks protection on that branch, so it works against any integration branch unchanged.
- Forcing git-flow on existing repos — the schema default stays `main` for backward compatibility; git-flow is opt-in via config.

## Constraints

- **Never rename engine internals** (`scripts/orchestration/`, `orchestration.json`, the `ganpan-orchestration` sentinel) — deployed runtime contract.
- `branchStrategy` is **optional**; a config without it must load and behave exactly as today (`INTEGRATION_BRANCH=main`). Use `jq -r '… // "main"'` (not `jq -er`) so a missing key defaults instead of failing `load_config`.
- The single source of truth is `plugins/orchestration/`; the Codex skill reference (`plugins/ganpan-codex/skills/ganpan-work-issue/references/work-issue.md`) is a copy of `references/lanes/work-issue.md` and must be edited to match.
- `assets/CLAUDE.md` is shipped to users — editing it changes deploy output (intended here: document the branch policy).
- Tests use `bats`. Extend `tests/orchestration/lib.bats` for the new export.
- Shipped artifacts under `plugins/` change → bump `plugins/orchestration/.claude-plugin/plugin.json` (feat → minor).

## Acceptance criteria

1. `load_config` exports `INTEGRATION_BRANCH`: equal to `branchStrategy.integrationBranch` when present, and `main` when the `branchStrategy` block is absent. A config **without** `branchStrategy` still loads with no error and every existing exported var unchanged.
2. `references/lanes/work-issue.md`, `commands/work-issue.md`, `commands/work-issue-deep.md`, and the Codex copy `plugins/ganpan-codex/skills/ganpan-work-issue/references/work-issue.md` instruct creating the PR against the configured integration branch (`$INTEGRATION_BRANCH` / "the configured integration branch"), not literal `main`.
3. `assets/orchestration.json` gains a `branchStrategy` block set to the git-flow default (`{"integrationBranch": "develop"}`), and the in-repo `.claude/orchestration.json` is **left without** the block (so ganpan's own lanes keep targeting `main`).
4. `assets/CLAUDE.md` and `docs/SETUP.md` document the two policies, how to choose via `branchStrategy.integrationBranch`, the `main` default when omitted, and the prerequisite that the chosen integration branch must exist on the remote.
5. `tests/orchestration/lib.bats` has tests asserting (a) `INTEGRATION_BRANCH` defaults to `main` when `branchStrategy` is absent and (b) it reflects a configured value when present.
6. Full suite green: `bats tests/*.bats tests/orchestration/*.bats`; `shellcheck plugins/orchestration/scripts/orchestration/*.sh` clean; `jq .` validates `assets/orchestration.json` and `plugin.json`.
7. `plugin.json` bumped (minor — feat).
8. A `docs/log/` entry records the scope split, the back-compat default decision, and rejected alternatives.
9. The PR body recommends a follow-up issue for subsystem (B), release automation.
