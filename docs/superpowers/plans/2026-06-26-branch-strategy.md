# Configurable Branch Strategy (Foundation) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a project pick which branch Coder-lane feature PRs integrate into — via an optional `branchStrategy.integrationBranch` config key (default `main`), with a branch-existence guard — laying the foundation for later release automation.

**Architecture:** `load_config` gains one exported var `INTEGRATION_BRANCH` (defaults to `main` when the optional `branchStrategy` block is absent). The four Coder-lane touch-points create the PR against `$INTEGRATION_BRANCH` after verifying that branch exists on the remote. The shipped config template selects git-flow (`develop`); ganpan's own config omits the block and stays on `main`. No runtime contract is renamed.

**Tech Stack:** Bash, `jq`, `gh`, `bats` (≥1.5.0 already used in suite), `shellcheck`.

## Global Constraints

- Never rename engine internals (`scripts/orchestration/`, `orchestration.json`, the `ganpan-orchestration` sentinel).
- `branchStrategy` is OPTIONAL — a config without it loads with exit 0, `INTEGRATION_BRANCH=main`, every other exported var unchanged. Read it with `jq -r '… // "main"'` (not `jq -er`).
- The Codex copy `plugins/ganpan-codex/skills/ganpan-work-issue/references/work-issue.md` must carry the **textually identical** PR-step sentence as the canonical `references/lanes/work-issue.md`.
- `work-issue-deep` is Claude-only (no Codex deep skill).
- Do NOT touch `auto-merge.sh` (reads the PR's actual base already), the reviewer/QA lanes, or add a `productionBranch` field (deferred to subsystem B).
- After changing `plugins/`, bump `plugins/orchestration/.claude-plugin/plugin.json` (feat → minor).
- All work in worktree `wt-issue-56` on branch `issue-56`; tests run from repo root.

---

### Task 1: Add `INTEGRATION_BRANCH` to `load_config` (TDD)

**Files:**
- Modify: `plugins/orchestration/scripts/orchestration/lib.sh` (the `load_config` function, ~lines 30-52)
- Test: `tests/orchestration/lib.bats`

**Interfaces:**
- Produces: exported env var `INTEGRATION_BRANCH` (string). Equals `branchStrategy.integrationBranch` if present, else `main`.

- [ ] **Step 1a: Extend the existing "exports expected vars" test to cover the default + export-presence**

This is the back-compat assertion (AC1): the fixture config in `setup()` has **no** `branchStrategy` block, so appending `$INTEGRATION_BRANCH` to this exact-match test proves (a) the var is exported, (b) it defaults to `main`, and (c) no existing var was dropped (the whole pipe-joined string is asserted verbatim). In `tests/orchestration/lib.bats`, find the existing test (≈lines 16-23):

```bash
  run bash -c 'source "$0"; load_config; echo "$REPO|$BOT|$CANDIDATE_N|$WIP_LIMIT|$RECLAIM_TIMEOUT_MIN|$HEARTBEAT_MIN|$PROJECT_NUMBER|$ORCH_CONFIG_PATH"' "$LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "o/r|botx|3|4|120|15|null|$ORCH_CONFIG" ]
```

Append `|$INTEGRATION_BRANCH` to the echoed list and `|main` to the expected output:

```bash
  run bash -c 'source "$0"; load_config; echo "$REPO|$BOT|$CANDIDATE_N|$WIP_LIMIT|$RECLAIM_TIMEOUT_MIN|$HEARTBEAT_MIN|$PROJECT_NUMBER|$ORCH_CONFIG_PATH|$INTEGRATION_BRANCH"' "$LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "o/r|botx|3|4|120|15|null|$ORCH_CONFIG|main" ]
```

- [ ] **Step 1b: Add a test for the configured value**

Append to `tests/orchestration/lib.bats` (write a fresh config file — do NOT rewrite `$ORCH_CONFIG` in place):

```bash
@test "load_config reads INTEGRATION_BRANCH from branchStrategy.integrationBranch when present" {
  jq '. + {branchStrategy:{integrationBranch:"develop"}}' "$ORCH_CONFIG" > "$BATS_TEST_TMPDIR/cfg2.json"
  run bash -c 'ORCH_CONFIG="$1" bash -c '\''source "$2"; load_config; echo "$INTEGRATION_BRANCH"'\'' _ "$3"' _ "$BATS_TEST_TMPDIR/cfg2.json" "$LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "develop" ]
}
```

> Note: `$LIB`, `$ORCH_CONFIG`, and `$BATS_TEST_TMPDIR` are available from the existing `setup()`/bats. Verify by reading the top of `tests/orchestration/lib.bats` before running. If the nested-quote invocation is awkward, an equivalent is to point `resolve_config_path` at `cfg2.json` by exporting `ORCH_CONFIG` for the subshell — the key requirement is the configured file (not the fixture) is the one loaded.

- [ ] **Step 2: Run the tests, expect FAIL**

Run: `bats tests/orchestration/lib.bats`
Expected: the extended "exports expected vars" test FAILS (output ends `…|$ORCH_CONFIG|`, missing `main`, since the var isn't exported yet) and the new configured-value test FAILS (`$INTEGRATION_BRANCH` empty ≠ `develop`).

- [ ] **Step 3: Add the read + export in `load_config`**

In `plugins/orchestration/scripts/orchestration/lib.sh`, find the line:

```bash
  REVIEWER_AUTO_MERGE=$(jq -r '.reviewer.autoMerge // false' "$cfg")
```

Add immediately after it:

```bash
  # Optional branch strategy. Absent block ⇒ "main" (backward compatible: feature PRs
  # target main, the legacy single-branch behavior). branchStrategy.integrationBranch
  # is the branch Coder-lane feature PRs integrate into (e.g. "develop" for git-flow).
  INTEGRATION_BRANCH=$(jq -r '.branchStrategy.integrationBranch // "main"' "$cfg")
```

Then add `INTEGRATION_BRANCH` to the `export` line at the end of `load_config`:

```bash
  export ORCH_CONFIG_PATH REPO BOT CANDIDATE_N WIP_LIMIT RECLAIM_TIMEOUT_MIN HEARTBEAT_MIN WORKTREE_BASE PROJECT_NUMBER PROJECT_STATUS_FIELD WORKER_ID REVIEWER_PERM_THRESHOLD REVIEWER_ALLOWLIST FOLLOWUP_CAP REVIEWER_AUTO_MERGE INTEGRATION_BRANCH
```

- [ ] **Step 4: Run the tests, expect PASS; confirm no regression**

Run: `bats tests/orchestration/lib.bats`
Expected: all PASS. The "exports expected vars" test now asserts `…|main` (so it actively verifies `INTEGRATION_BRANCH` is exported and defaults to `main`, and that no other var changed), and the configured-value test asserts `develop`.

- [ ] **Step 5: shellcheck**

Run: `shellcheck plugins/orchestration/scripts/orchestration/lib.sh`
Expected: exit 0.

- [ ] **Step 6: Commit**

```bash
git add plugins/orchestration/scripts/orchestration/lib.sh tests/orchestration/lib.bats
git commit -m "feat(orch): load_config exports INTEGRATION_BRANCH (default main)

Optional branchStrategy.integrationBranch names the branch Coder-lane
feature PRs integrate into; absent block defaults to main (backward
compatible). Refs #56"
```

---

### Task 2: Point the Coder lane at `$INTEGRATION_BRANCH` with a branch-existence guard

**Files:**
- Modify: `plugins/orchestration/references/lanes/work-issue.md` (step 8, line 23)
- Modify: `plugins/ganpan-codex/skills/ganpan-work-issue/references/work-issue.md` (step 8, line 23 — keep identical)
- Modify: `plugins/orchestration/commands/work-issue.md` (step 7, line 57)
- Modify: `plugins/orchestration/commands/work-issue-deep.md` (step 7, line 56)

**Interfaces:**
- Consumes: `INTEGRATION_BRANCH` from Task 1 (`load_config`).

> **Testability note:** these four files are Markdown *instructions to the LLM lane agent*, not executable shell scripts, so there is no bats unit test for the base-branch change or the guard — verification is the grep assertions in Step 6 plus the diff in Step 3. The guard **intentionally fails closed**: any non-zero `gh api` exit (a genuine 404 *or* a transient 403/5xx) blocks PR creation rather than risk misrouting to the repo default branch. The work is already committed on the branch, so a transient block is recovered by the next lane tick / human; the error message names both causes so the operator can tell them apart.

- [ ] **Step 1: Edit the canonical reference**

In `plugins/orchestration/references/lanes/work-issue.md`, replace the step-8 sentence:

```
8. Re-run the actor gate (`require_bot_actor`) before this write — the lane-start gate may have run long ago, and an expired `GH_TOKEN` would otherwise create the PR as the wrong actor — then create or update a PR from `issue-<ISSUE>` to `main`.
```

with:

```
8. Re-run the actor gate (`require_bot_actor`) before this write — the lane-start gate may have run long ago, and an expired `GH_TOKEN` would otherwise create the PR as the wrong actor. The PR targets the configured integration branch (`$INTEGRATION_BRANCH` from `load_config`, default `main`); first confirm it exists on the remote (`gh api "repos/$REPO/branches/$INTEGRATION_BRANCH"`) and stop with a clear error if it does not, then create or update the PR from `issue-<ISSUE>` to `$INTEGRATION_BRANCH`.
```

- [ ] **Step 2: Copy the identical sentence into the Codex reference**

Apply the exact same replacement at step 8 of `plugins/ganpan-codex/skills/ganpan-work-issue/references/work-issue.md`.

- [ ] **Step 3: Verify the two reference files' step 8 are identical**

Run: `diff <(grep -n '^8\.' plugins/orchestration/references/lanes/work-issue.md) <(grep -n '^8\.' plugins/ganpan-codex/skills/ganpan-work-issue/references/work-issue.md)`
Expected: only the leading line-number differs (or no diff); the sentence text is identical. If the bodies differ, fix the copy.

- [ ] **Step 4: Edit `commands/work-issue.md` step 7**

In `plugins/orchestration/commands/work-issue.md`, replace the substring:

```
Then `gh pr create --head "issue-$ISSUE" --base main --title "..." --body "...\n\nCloses #$ISSUE"`.
```

with:

```
Then confirm the integration branch exists — `gh api "repos/$REPO/branches/$INTEGRATION_BRANCH" >/dev/null 2>&1 || { echo "integration branch '$INTEGRATION_BRANCH' not found on $REPO (missing branch, or a transient API error) — create it or set branchStrategy.integrationBranch"; exit 1; }` — and `gh pr create --head "issue-$ISSUE" --base "$INTEGRATION_BRANCH" --title "..." --body "...\n\nCloses #$ISSUE"` (`$INTEGRATION_BRANCH` comes from `load_config`, default `main`).
```

- [ ] **Step 5: Edit `commands/work-issue-deep.md` step 7**

In `plugins/orchestration/commands/work-issue-deep.md`, replace the substring:

```
Then `gh pr create --head "issue-$ISSUE" --base main --title "..." --body "...\n\nCloses #$ISSUE"` (link the spec/plan/log docs in the body).
```

with:

```
Then confirm the integration branch exists — `gh api "repos/$REPO/branches/$INTEGRATION_BRANCH" >/dev/null 2>&1 || { echo "integration branch '$INTEGRATION_BRANCH' not found on $REPO (missing branch, or a transient API error) — create it or set branchStrategy.integrationBranch"; exit 1; }` — and `gh pr create --head "issue-$ISSUE" --base "$INTEGRATION_BRANCH" --title "..." --body "...\n\nCloses #$ISSUE"` (link the spec/plan/log docs in the body; `$INTEGRATION_BRANCH` comes from `load_config`, default `main`).
```

- [ ] **Step 6: Verify no literal `--base main` remains and the var is referenced**

Run: `grep -rn "base main" plugins/orchestration plugins/ganpan-codex; echo "---"; grep -rln "INTEGRATION_BRANCH" plugins/orchestration/commands plugins/orchestration/references plugins/ganpan-codex`
Expected: first grep prints nothing (exit 1); second lists the four edited files (work-issue.md, work-issue-deep.md, and the two references).

- [ ] **Step 7: Commit**

```bash
git add plugins/orchestration/references/lanes/work-issue.md plugins/ganpan-codex/skills/ganpan-work-issue/references/work-issue.md plugins/orchestration/commands/work-issue.md plugins/orchestration/commands/work-issue-deep.md
git commit -m "feat(orch): Coder lane targets configured integration branch

Feature PRs now target \$INTEGRATION_BRANCH (default main) instead of
hardcoded main, after verifying the branch exists on the remote so a
git-flow setup missing 'develop' fails loudly. Codex copy kept in sync.
Refs #56"
```

---

### Task 3: Ship the git-flow config template and user docs

**Files:**
- Modify: `plugins/orchestration/assets/orchestration.json`
- Modify: `plugins/orchestration/assets/CLAUDE.md` (after the "## Branches / worktrees" block, ~line 11)
- Modify: `docs/SETUP.md` (in the "## Steps" → Config item, line 53 area)

**Interfaces:** none (config + docs).

- [ ] **Step 1: Add the `branchStrategy` block to the shipped template**

In `plugins/orchestration/assets/orchestration.json`, change the last two lines from:

```json
  "project": { "number": null, "statusField": "Status" },
  "reviewer": { "permissionThreshold": "write", "allowlist": [], "followupIssueCapPerPR": 3, "autoMerge": false }
}
```

to:

```json
  "project": { "number": null, "statusField": "Status" },
  "reviewer": { "permissionThreshold": "write", "allowlist": [], "followupIssueCapPerPR": 3, "autoMerge": false },
  "branchStrategy": { "integrationBranch": "develop" }
}
```

- [ ] **Step 2: Validate the template JSON**

Run: `jq . plugins/orchestration/assets/orchestration.json >/dev/null && echo OK`
Expected: `OK`.

- [ ] **Step 3: Document the policy in shipped `assets/CLAUDE.md`**

In `plugins/orchestration/assets/CLAUDE.md`, immediately after the "## Branches / worktrees" bullets (after the `Never force-push…` line, before `## Merge gate`), insert:

```markdown
- **Branch strategy** (`branchStrategy.integrationBranch`): the branch Coder-lane feature PRs target. Two policies:
  - **git-flow** (what the shipped config template selects): set `integrationBranch: "develop"` — `main` is your production line, day-to-day work integrates into `develop`. **You must create the `develop` branch on the remote first**; the Coder lane stops with a clear error if it is missing.
  - **trunk / release-branch**: set `integrationBranch: "main"` (or omit `branchStrategy` entirely) — feature PRs target `main`. **Omitting the block defaults to `main`**, so do not delete it once set or your integration branch silently reverts to `main`.
  - Release/tag/version automation for the production line is not built yet (tracked separately).
```

- [ ] **Step 4: Document the config key in `docs/SETUP.md`**

In `docs/SETUP.md`, in the "## Steps" section, find the Config bullet (line 53, starts `3. **Config:** discovery order is…`). At the end of that bullet, append:

```
 Set `branchStrategy.integrationBranch` to choose where feature PRs land: the shipped template uses `"develop"` (git-flow — create that branch on the remote first), or set `"main"` / omit the block for trunk-style (feature PRs target `main`). Omitting the block defaults to `main`.
```

- [ ] **Step 5: Commit**

```bash
git add plugins/orchestration/assets/orchestration.json plugins/orchestration/assets/CLAUDE.md docs/SETUP.md
git commit -m "feat(orch): ship git-flow branchStrategy template + docs

assets template selects integrationBranch=develop; CLAUDE.md and
SETUP.md document the two policies, the main default when omitted, and
the create-develop-first prerequisite. Refs #56"
```

---

### Task 4: Version bump, full gate, and dev-log

**Files:**
- Modify: `plugins/orchestration/.claude-plugin/plugin.json`
- Create: `docs/log/2026-06-26-branch-strategy.md`

- [ ] **Step 1: Bump the minor version (feat)**

Read current: `jq -r .version plugins/orchestration/.claude-plugin/plugin.json` (expect `1.6.0`). Edit `version` to `1.7.0` (feat → minor).

- [ ] **Step 2: Validate JSON**

Run: `jq . plugins/orchestration/.claude-plugin/plugin.json .claude-plugin/marketplace.json >/dev/null && echo OK`
Expected: `OK`.

- [ ] **Step 3: Full suite + shellcheck gate**

Run: `bats tests/*.bats tests/orchestration/*.bats`
Expected: all green.
Run: `shellcheck plugins/orchestration/scripts/orchestration/*.sh`
Expected: exit 0.

- [ ] **Step 4: Write the dev-log entry**

Create `docs/log/2026-06-26-branch-strategy.md` per `docs/log/README.md`. It MUST record:
- What changed: optional `branchStrategy.integrationBranch` config, `INTEGRATION_BRANCH` export, Coder-lane base-branch + existence guard, git-flow template, docs.
- The **scope split**: subsystem A (this PR) vs deferred subsystem B, and **enumerate B's scope** — version bump automation, `gh release`, `git tag`/scheme, release notes/changelog, doc generation, `staging`/beta branch management, `branchStrategy.productionBranch` field + `PRODUCTION_BRANCH` export, and Policy 1 production-branch/tag semantics.
- Key decisions: (a) absent block ⇒ `main` for backward compat; (b) shipped template ⇒ `develop` to honor the issue's git-flow default; (c) a runtime branch-existence guard rather than docs-only mitigation; (d) defer `productionBranch` (YAGNI) but name the load_config integration point for B.
- Alternatives rejected: shipping the template defaulting to `main` (rejected — contradicts the issue's git-flow default; the guard makes `develop` safe); adding `productionBranch` now (rejected — unused dead config); changing `auto-merge.sh` (rejected — already base-aware); a flat top-level `integrationBranch` key (rejected — `branchStrategy.*` namespaces the future production/staging siblings).

- [ ] **Step 5: Commit the dev-log FIRST (separate from the bump)**

The log is committed on its own so it survives independently if the version-bump commit is amended/re-bumped at merge time (see the cross-PR note below).

```bash
git add docs/log/2026-06-26-branch-strategy.md
git commit -m "docs(log): #56 branch-strategy foundation + deferred subsystem B"
```

- [ ] **Step 6: Commit the version bump separately**

```bash
git add plugins/orchestration/.claude-plugin/plugin.json
git commit -m "chore(release): bump orchestration to 1.7.0 for #56

Refs #56"
```

> **Cross-PR version note:** main is `1.6.0`; open feat PRs #53/#54 also bump toward `1.7.0`. If one merges first, this PR's version needs re-bumping at merge — flag it in the PR body for the human merge gate. The dev-log is a separate commit (Step 5) so a bump re-do never drops it.
