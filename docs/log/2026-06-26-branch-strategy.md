# Configurable branch strategy — foundation (#56)

- **Date:** 2026-06-26
- **Issue / PR:** #56 / PR #57
- **Type:** feat

> **Rework (2026-06-26):** PR #57 conflicted after `main` advanced to `1.7.1` (PR #46/#29 merged). Merged latest `main` (only conflict: `plugin.json` version) and re-bumped to **`1.8.0`** (feat → minor from `1.7.1`) per the reviewer. The INTEGRATION_BRANCH changes auto-merged cleanly with `main`'s concurrent edits to `lib.sh` and the lane references; canonical/Codex reference parity re-verified. Full suite green (179 tests).

## What changed
- **`load_config`** now reads an **optional** `branchStrategy.integrationBranch` and exports `INTEGRATION_BRANCH` — the branch Coder-lane feature PRs target. An absent block defaults to `main`.
- **Coder lane** (canonical `references/lanes/work-issue.md`, its Codex copy, `commands/work-issue.md`, `commands/work-issue-deep.md`) now opens the PR against `$INTEGRATION_BRANCH` instead of hardcoded `main`, and first **verifies the integration branch exists on the remote** (`gh api repos/$REPO/branches/$INTEGRATION_BRANCH`), halting with a clear error otherwise.
- **Shipped config template** (`assets/orchestration.json`) selects git-flow (`branchStrategy.integrationBranch: "develop"`); ganpan's own `.claude/orchestration.json` omits the block and stays on `main`.
- **Docs** (`assets/CLAUDE.md`, `docs/SETUP.md`) document the two policies, the `main` default when omitted, the create-`develop`-first prerequisite, and not to delete the block.
- Tests: `tests/orchestration/lib.bats` asserts the default (`main`) via the extended exports test and the configured value (`develop`).

## Scope split (subsystem A here; subsystem B deferred)
Issue #56 is two subsystems. **(A) Branch-strategy foundation — this PR.** **(B) Release automation — deferred to a follow-up issue.** B's full scope, enumerated so the original #56 vision survives:
- Production **version-bump automation** and a possible `/ganpan:release` command.
- **`gh release`** creation and a **`git tag`** scheme.
- **Release-notes / changelog** generation.
- **Doc updates** on release.
- **`staging`/beta** branch management.
- A **`branchStrategy.productionBranch`** config field + a matching `PRODUCTION_BRANCH` export in `load_config`.
- **Policy 1** (main-as-development, production-via-release-branch-or-tag) production-branch semantics — this PR's `integrationBranch` already lets a user run Policy 1 by setting it to `main`, but the production-side modeling lands with B.

## Key decisions
- **Absent block ⇒ `main`** (schema default) — zero behavior change for existing installs and for ganpan's own repo. Read with `jq -r '… // "main"'`, never `jq -er`, so a missing key defaults instead of failing `load_config`.
- **Shipped template ⇒ `develop`** — honors the issue's stated git-flow default for new setups, while the schema default keeps back-compat.
- **Runtime branch-existence guard** rather than docs-only mitigation — `gh pr create --base develop` against a missing `develop` would misroute or fail opaquely; the guard fails closed with an actionable message (and names the transient-error possibility).
- **Defer `productionBranch`** (YAGNI) but name the `load_config` integration point so B extends cleanly (one added line — the per-field reads are not the frozen runtime contract).
- **Nest under `branchStrategy`** rather than a flat top-level key, so future `productionBranch`/`staging` siblings have a home.

## Alternatives considered (not chosen)
- **Ship the template defaulting to `main`** (git-flow as a commented opt-in) — rejected: contradicts the issue's git-flow default. The branch-existence guard makes the `develop` template safe instead.
- **Add `productionBranch` now** — rejected: unused dead config in this PR (YAGNI); arrives with subsystem B.
- **Change `auto-merge.sh`** — rejected: it already reads the PR's actual `baseRefName` (`auto-merge.sh:46,50`) and checks protection on that branch, so it works against any integration branch unchanged.
- **A flat top-level `integrationBranch` key** — rejected: pollutes the config namespace; `branchStrategy.*` groups the future production/staging fields.
- **Docs-only footgun mitigation** — rejected: a first-run misroute before the user reads docs is too costly; the guard makes it deterministic.
