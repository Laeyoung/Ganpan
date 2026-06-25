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
3. Make the Coder lane create the PR against `$INTEGRATION_BRANCH` instead of literal `main`, in all touch-points: the canonical `references/lanes/work-issue.md`, its Codex copy `plugins/ganpan-codex/skills/ganpan-work-issue/references/work-issue.md`, `commands/work-issue.md`, and `commands/work-issue-deep.md`. (`work-issue-deep` is Claude-only — there is **no** `ganpan-work-issue-deep` Codex skill — so the only Codex touch-point is `ganpan-work-issue`.)
4. **Guard against a missing integration branch.** Before `gh pr create`, the lane verifies the configured integration branch exists on the remote (`gh api repos/$REPO/branches/$INTEGRATION_BRANCH`) and **halts with a clear, actionable error** if it does not — so a git-flow setup whose `develop` branch has not been created fails loudly instead of letting `gh pr create` misroute to the repo default branch or fail opaquely.
5. Ship the config template and user-facing docs so a new project can choose git-flow (the issue's stated default — shipped template uses `integrationBranch: "develop"`) or trunk (`integrationBranch: "main"`).
6. Keep Codex parity and the install/sentinel path intact.

## Non-goals (all deferred to subsystem B — enumerated so the full #56 vision is preserved)

- **Release automation** — version bump, `gh release`, `git tag`/tag scheme, release-notes/changelog generation, doc updates, and any new `/ganpan:release` command.
- **`staging`/beta branch management.**
- **A `productionBranch` config field** and **Policy 1's production-branch/tag modeling** (the "main-as-dev, production-via-release-branch-or-tag" half). Not used by anything in this PR. When B lands it will add `branchStrategy.productionBranch` and a matching `PRODUCTION_BRANCH` export in `load_config` (one added line — the per-field `jq` reads in `load_config` are not the frozen runtime contract, so this extends cleanly); B implementors should read it there.
- Changing `auto-merge.sh` — it already reads the PR's *actual* `baseRefName` (`auto-merge.sh:46,50`) and checks protection on that branch, so it works against any integration branch unchanged.
- **No changes to the reviewer or QA lane commands** — they operate on PR/issue state from GitHub regardless of the PR's base branch.
- Forcing git-flow on existing repos — the **schema** default stays `main` for backward compatibility (an absent block ⇒ `main`); git-flow is what the shipped **template** selects for new setups.

## Constraints

- **Never rename engine internals** (`scripts/orchestration/`, `orchestration.json`, the `ganpan-orchestration` sentinel) — deployed runtime contract.
- `branchStrategy` is **optional**; a config without it must load and behave exactly as today (`INTEGRATION_BRANCH=main`). Use `jq -r '… // "main"'` (not `jq -er`) so a missing key defaults instead of failing `load_config`.
- The single source of truth is `plugins/orchestration/`; the Codex skill reference (`plugins/ganpan-codex/skills/ganpan-work-issue/references/work-issue.md`) is a copy of `references/lanes/work-issue.md`. After this change, the PR-step sentence in the Codex copy must be **textually identical** to the canonical one (both replace "to `main`" with "to the configured integration branch (`$INTEGRATION_BRANCH`, default `main`)"), so a `diff`-style assertion can verify parity.
- `assets/CLAUDE.md` is shipped to users — editing it changes deploy output (intended here: document the branch policy).
- Tests use `bats`. Extend `tests/orchestration/lib.bats` for the new export.
- Shipped artifacts under `plugins/` change → bump `plugins/orchestration/.claude-plugin/plugin.json` (feat → minor).

## Acceptance criteria

1. `load_config` exports `INTEGRATION_BRANCH`: equal to `branchStrategy.integrationBranch` when present, and `main` when the `branchStrategy` block is absent. A config **without** `branchStrategy` still loads with exit 0; `load_config` exports exactly one new variable (`INTEGRATION_BRANCH`) and leaves every previously-exported variable unchanged (verified against the existing `lib.bats` "load_config exports expected vars" assertion).
2. The PR step in all four touch-points — `references/lanes/work-issue.md`, its Codex copy `plugins/ganpan-codex/skills/ganpan-work-issue/references/work-issue.md`, `commands/work-issue.md`, `commands/work-issue-deep.md` — targets the configured integration branch (`--base "$INTEGRATION_BRANCH"` in the command files; "to the configured integration branch (`$INTEGRATION_BRANCH`, default `main`)" in the two reference files, textually identical between canonical and Codex copy), and no longer says literal `main`.
3. The PR step also guards branch existence: each touch-point instructs verifying `gh api repos/$REPO/branches/$INTEGRATION_BRANCH` succeeds before `gh pr create`, halting with a clear error otherwise.
4. `assets/orchestration.json` gains a `branchStrategy` block set to the git-flow default (`{"integrationBranch": "develop"}`); the in-repo `.claude/orchestration.json` is **left without** the block (so ganpan's own lanes keep targeting `main`).
5. `assets/CLAUDE.md` and `docs/SETUP.md` document: the two policies; how to choose via `branchStrategy.integrationBranch`; that **omitting** the block defaults to `main` (backward compat) while the **shipped template** selects `develop` (so a fresh `orch-setup` install is git-flow by default); the prerequisite that the chosen integration branch must exist on the remote (and not to remove the block once set, or the branch silently reverts to `main`).
6. `tests/orchestration/lib.bats` has tests asserting (a) `INTEGRATION_BRANCH` defaults to `main` when `branchStrategy` is absent and (b) it reflects a configured value when present.
7. Full suite green: `bats tests/*.bats tests/orchestration/*.bats`; `shellcheck plugins/orchestration/scripts/orchestration/*.sh` clean; `jq .` validates `assets/orchestration.json` and `plugin.json`.
8. `plugin.json` bumped (minor — feat).
9. A `docs/log/` entry records the scope split AND enumerates the deferred subsystem-B scope items (version bump, `gh release`, `git tag`, release notes, doc generation, `staging`/beta, `productionBranch` field, Policy 1 production-branch semantics) so the full #56 vision survives independent of the PR body; plus the back-compat-default and template-default decisions and rejected alternatives.
10. The PR body recommends a follow-up issue for subsystem (B) and lists its scope.

> **`orch-setup` note:** `orch-setup` copies `assets/orchestration.json` verbatim, so new installs receive the git-flow template with no code change to `orch-setup` — intentional, and the branch-existence guard plus setup docs cover the "create `develop` first" step.
