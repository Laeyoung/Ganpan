# Orchestration Plugin + `/orch-setup` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Repackage the merged v1 orchestration toolkit as a Claude Code plugin distributed from this repo as a marketplace, add an `/orch-setup` command, and keep `install.sh` as the copy-in alternative — from the design spec `docs/superpowers/specs/2026-06-18-orchestration-plugin-design.md`.

**Architecture:** Consolidate the engine + lane commands + payload assets under `plugins/orchestration/` (single source of truth). Lane commands invoke scripts via `${CLAUDE_PLUGIN_ROOT}/scripts/orchestration/…`; `lib.sh`/`detect-test-cmd.sh` discover config cwd-relative (`./.claude/orchestration.json`) so the engine is location-independent. A root `.claude-plugin/marketplace.json` makes the repo installable. `install.sh` copies the plugin-canonical files into a target repo, rewriting `${CLAUDE_PLUGIN_ROOT}/` → `./` and stamping a version sentinel.

**Tech Stack:** bash (`set -euo pipefail`), `gh`, `jq`, `yq`, `git`/`git worktree`, `bats-core`, `shellcheck`, Claude Code plugin manifests (JSON).

## Global Constraints

- **Atomic move — binding invariant (spec §8.3):** the move + every path repoint the **bats suite** depends on (script relocation, `lib.sh`/`detect-test-cmd.sh`/`bootstrap-labels.sh` config/label defaults, and all `tests/orchestration/*.bats` prefixes) land in **one commit** (Task 1), so `bats tests/orchestration/` is green on every commit. **Refinement of §8.3's literal "single commit":** §8.3 also lists lane-command invocations and `install.sh` source paths; those are *not* exercised by the bats suite per-commit (commands are prompts; `install.sh` has no test until Task 5). The plan keeps them in their own reviewable commits (Tasks 2 & 5) for review granularity. No intermediate broken state ever reaches `main` because the whole branch merges as one PR; the bats-green-per-commit guarantee — the property §8.3 exists to protect — holds throughout.
- **Platform:** this repo runs on **macOS (darwin)** — all `sed -i ''` invocations use the BSD two-arg form. On a GNU/Linux runner use `sed -i` (no `''`).
- **Single source of truth (spec §3.1):** engine scripts exist only at `plugins/orchestration/scripts/orchestration/`. No duplicate copies committed in the repo.
- **Config discovery order (spec §3.3):** `$ORCH_CONFIG` → `./.claude/orchestration.json`. The `$SCRIPT_DIR/../../` fallback is removed from both `lib.sh` and `detect-test-cmd.sh`.
- **`${CLAUDE_PLUGIN_ROOT}` (spec §3.2):** lane commands reference scripts as `"${CLAUDE_PLUGIN_ROOT}/scripts/orchestration/<x>.sh"`. A failed expansion must never silently become `/scripts/...`.
- **Human merge gate (spec §8.5, CLAUDE.md):** agents never merge/approve PRs. This branch's PR is merged by a human.
- **shellcheck clean** on every `.sh` (engine + `install.sh`); **conventional commits** per `CLAUDE.md`.
- **`install.sh` copy-in destinations:** scripts→`scripts/orchestration/`, commands→`.claude/commands/`, assets→`.github/` + `.claude/orchestration.json` at the target repo root.

---

## File structure

```
.claude-plugin/marketplace.json                         # NEW (Task 4)
plugins/orchestration/.claude-plugin/plugin.json        # NEW (Task 4)
plugins/orchestration/scripts/orchestration/*.sh        # MOVED from scripts/orchestration/ (Task 1)
plugins/orchestration/commands/{work-issue,triage,review-queue,qa-check}.md  # MOVED + rewritten (Task 2)
plugins/orchestration/commands/orch-setup.md            # NEW (Task 3)
plugins/orchestration/assets/orchestration.json         # MOVED from .claude/orchestration.json (Task 1)
plugins/orchestration/assets/labels.yml                 # MOVED from .github/labels.yml (Task 1)
plugins/orchestration/assets/task.yml                   # MOVED from .github/ISSUE_TEMPLATE/task.yml (Task 1)
plugins/orchestration/assets/CLAUDE.md                  # COPY of root CLAUDE.md conventions (Task 1)
tests/orchestration/*.bats                              # path prefixes repointed (Task 1) + new discovery test
tests/install.bats                                      # NEW install.sh e2e (Task 5)
install.sh                                              # source paths repointed + --force + sentinel (Task 5)
docs/SETUP.md                                           # plugin install path (Task 6)
CLAUDE.md                                               # KEPT at root (ganpan's own conventions)
```

**What stays at repo root and is NOT moved:** `CLAUDE.md` (ganpan's own conventions; a *copy* goes to assets), `docs/`, `install.sh`, `.gitignore`.

---

## Task 1: Atomic restructure — move engine + repoint config discovery + repoint tests

**Files:**
- Move: `scripts/orchestration/*.sh` → `plugins/orchestration/scripts/orchestration/*.sh`
- Move: `.github/labels.yml` → `plugins/orchestration/assets/labels.yml`
- Move: `.github/ISSUE_TEMPLATE/task.yml` → `plugins/orchestration/assets/task.yml`
- Move: `.claude/orchestration.json` → `plugins/orchestration/assets/orchestration.json`
- Copy: `CLAUDE.md` → `plugins/orchestration/assets/CLAUDE.md`
- Modify: `plugins/orchestration/scripts/orchestration/lib.sh` (config fallback)
- Modify: `plugins/orchestration/scripts/orchestration/detect-test-cmd.sh` (config fallback)
- Modify: `plugins/orchestration/scripts/orchestration/bootstrap-labels.sh` (default labels path)
- Modify: all 7 `tests/orchestration/*.bats` (SCRIPT=/LIB=/LABELS= prefixes)
- Test: add a discovery test to `tests/orchestration/lib.bats`

> This is the single atomic commit the Global Constraints require. Every edit below is part of it; the commit happens once at Step 11 with all 46 tests green.

- [ ] **Step 1: Create the plugin directory skeleton and move the engine**

```bash
mkdir -p plugins/orchestration/scripts plugins/orchestration/assets \
         plugins/orchestration/commands plugins/orchestration/.claude-plugin
git mv scripts/orchestration plugins/orchestration/scripts/orchestration
```
Expected: `scripts/orchestration/*.sh` now live under `plugins/orchestration/scripts/orchestration/`; the now-empty `scripts/` dir is gone.

- [ ] **Step 2: Move assets and copy CLAUDE.md**

```bash
git mv .github/labels.yml plugins/orchestration/assets/labels.yml
git mv .github/ISSUE_TEMPLATE/task.yml plugins/orchestration/assets/task.yml
git mv .claude/orchestration.json plugins/orchestration/assets/orchestration.json
cp CLAUDE.md plugins/orchestration/assets/CLAUDE.md
git add plugins/orchestration/assets/CLAUDE.md
```
Expected: assets populated; root `CLAUDE.md` still present (copy, not move).

- [ ] **Step 3: Repoint `lib.sh` config fallback to cwd-relative**

In `plugins/orchestration/scripts/orchestration/lib.sh`, change line 11 from:
```bash
  local cfg="${ORCH_CONFIG:-$SCRIPT_DIR/../../.claude/orchestration.json}"
```
to:
```bash
  local cfg="${ORCH_CONFIG:-./.claude/orchestration.json}"
```

- [ ] **Step 4: Repoint `detect-test-cmd.sh` config fallback**

In `plugins/orchestration/scripts/orchestration/detect-test-cmd.sh`, change line 10 from:
```bash
cfg="${ORCH_CONFIG:-$SCRIPT_DIR/../../.claude/orchestration.json}"
```
to:
```bash
cfg="${ORCH_CONFIG:-./.claude/orchestration.json}"
```

- [ ] **Step 5: Repoint `bootstrap-labels.sh` default labels path**

In `plugins/orchestration/scripts/orchestration/bootstrap-labels.sh`, change line 9 from:
```bash
labels_file="${1:-$DIR/../../.github/labels.yml}"
```
to (now plugin-relative: `$DIR` is `…/scripts/orchestration`, so `../../assets` is `plugins/orchestration/assets`):
```bash
labels_file="${1:-$DIR/../../assets/labels.yml}"
```

- [ ] **Step 6: Repoint every test's SCRIPT=/LIB= prefix**

Run a single sweep across the bats files (BSD/macOS `sed -i ''`; the pattern has no leading-slash anchor so it matches unambiguously inside `$BATS_TEST_DIRNAME/../../scripts/orchestration/`):
```bash
sed -i '' 's#\.\./\.\./scripts/orchestration/#../../plugins/orchestration/scripts/orchestration/#g' \
  tests/orchestration/claim.bats tests/orchestration/reclaim.bats \
  tests/orchestration/detect-test-cmd.bats tests/orchestration/bootstrap-labels.bats \
  tests/orchestration/wip-check.bats tests/orchestration/lib.bats \
  tests/orchestration/heartbeat.bats
```
Expected: each `SCRIPT=`/`LIB=` now reads `$BATS_TEST_DIRNAME/../../plugins/orchestration/scripts/orchestration/<x>.sh`. (This also rewrites `lib.bats`'s `LIB=` line, so the discovery test added in Step 8 picks up the new path via `$LIB`.) Verify: `grep -rn 'BATS_TEST_DIRNAME/\.\./\.\./scripts/orchestration' tests/orchestration/` → no output.

- [ ] **Step 7: Repoint the labels path in `bootstrap-labels.bats`**

In `tests/orchestration/bootstrap-labels.bats`, change line 9 from:
```bash
  LABELS="$BATS_TEST_DIRNAME/../../.github/labels.yml"
```
to:
```bash
  LABELS="$BATS_TEST_DIRNAME/../../plugins/orchestration/assets/labels.yml"
```

- [ ] **Step 8: Add the cwd-relative discovery test (the new spec §6 test)**

Append to `tests/orchestration/lib.bats` (the `setup()` there already writes `$ORCH_CONFIG` to `$BATS_TEST_TMPDIR/orchestration.json` with `repo:"o/r"`):
```bash
@test "load_config finds ./.claude/orchestration.json from cwd when ORCH_CONFIG unset" {
  work="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$work/.claude"
  cp "$ORCH_CONFIG" "$work/.claude/orchestration.json"
  # unset the override and run from inside $work so only the cwd fallback can resolve it
  run bash -c 'unset ORCH_CONFIG; cd "$1"; source "$2"; load_config; echo "$REPO"' _ "$work" "$LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "o/r" ]
}
```

- [ ] **Step 9: Run the full suite — expect 46 green**

Run: `bats tests/orchestration/`
Expected: `46 tests, 0 failures` (45 original + 1 new discovery test).

- [ ] **Step 10: shellcheck the moved engine**

Run: `shellcheck plugins/orchestration/scripts/orchestration/*.sh`
Expected: exit 0 (no errors).

- [ ] **Step 11: Commit (single atomic commit)**

```bash
git add -A
git commit -m "refactor(orch): consolidate engine+assets under plugins/orchestration, cwd-relative config

Move scripts/orchestration -> plugins/orchestration/scripts/orchestration and
.claude/orchestration.json + .github/{labels.yml,ISSUE_TEMPLATE/task.yml} ->
plugins/orchestration/assets. Switch lib.sh and detect-test-cmd.sh config
discovery from \$SCRIPT_DIR/../.. to cwd-relative ./.claude/orchestration.json,
repoint bootstrap-labels default + all bats path prefixes, and add a cwd
discovery test. Single atomic commit so bats stays green (46/46).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Move + rewrite lane commands to the plugin

**Files:**
- Move: `.claude/commands/{work-issue,triage,review-queue,qa-check}.md` → `plugins/orchestration/commands/`
- Modify: the moved `work-issue.md`, `triage.md`, `qa-check.md` (script paths), `work-issue.md` (worktree config fix), `qa-check.md`/`review-queue.md` (prose lib.sh path)

**Interfaces:**
- Consumes: engine scripts now at `${CLAUDE_PLUGIN_ROOT}/scripts/orchestration/*.sh` (Task 1).
- Produces: plugin-canonical command files that `install.sh` (Task 5) copies and rewrites.

> Not bats-gated (command `.md` files are prompts). Per spec §3.2 the edit is content-aware: `work-issue.md` invokes `wip-check.sh`/`claim.sh`/`heartbeat.sh`/`detect-test-cmd.sh` + an explicit `source …/lib.sh`; `triage.md` invokes `reclaim.sh`; `qa-check.md` invokes `detect-test-cmd.sh` (+ prose lib.sh); `review-queue.md` has only prose lib.sh.

- [ ] **Step 1: Move the four command files**

```bash
git mv .claude/commands/work-issue.md   plugins/orchestration/commands/work-issue.md
git mv .claude/commands/triage.md       plugins/orchestration/commands/triage.md
git mv .claude/commands/review-queue.md plugins/orchestration/commands/review-queue.md
git mv .claude/commands/qa-check.md     plugins/orchestration/commands/qa-check.md
```

- [ ] **Step 2: Rewrite explicit `scripts/orchestration/` paths to `${CLAUDE_PLUGIN_ROOT}/…`**

Only files with literal `scripts/orchestration/` occurrences are touched (review-queue has none, so it is unaffected). The pattern below only matches an occurrence **not already** preceded by `}` (i.e. not already `${CLAUDE_PLUGIN_ROOT}/scripts/orchestration/`), so re-running it is idempotent and never double-prefixes:
```bash
sed -i '' -E 's#(^|[^}])scripts/orchestration/#\1${CLAUDE_PLUGIN_ROOT}/scripts/orchestration/#g' \
  plugins/orchestration/commands/work-issue.md \
  plugins/orchestration/commands/triage.md \
  plugins/orchestration/commands/qa-check.md
```
Then verify no bare occurrences remain and there is no double-prefix:
```bash
grep -rn 'scripts/orchestration/' plugins/orchestration/commands/ | grep -v '${CLAUDE_PLUGIN_ROOT}/scripts/orchestration/'   # → no output
grep -rn '${CLAUDE_PLUGIN_ROOT}/${CLAUDE_PLUGIN_ROOT}' plugins/orchestration/commands/                                      # → no output
```

- [ ] **Step 3: Fix the worktree config hazard in `work-issue.md` (spec §3.3)**

In `plugins/orchestration/commands/work-issue.md`, the intro line currently reads:
```
You are the **Coder** lane. Run from the **main repo root**. All orchestration scripts live at `${CLAUDE_PLUGIN_ROOT}/scripts/orchestration/`. Config: `.claude/orchestration.json`.
```
Replace it with (adds the repo-root capture mandate):
```
You are the **Coder** lane. Run from the **main repo root**. All orchestration scripts live at `${CLAUDE_PLUGIN_ROOT}/scripts/orchestration/`. Config: `.claude/orchestration.json`.

**Before any `cd`, capture the main checkout root once:** `REPO_ROOT="$PWD"`. Steps 5–8 may run from inside `wt-issue-<ISSUE>` (a git worktree has no `.claude/` dir), so any `load_config` must point at the main config via `ORCH_CONFIG="$REPO_ROOT/.claude/orchestration.json"`. Do **not** use `git rev-parse --show-toplevel` for this — inside a worktree it returns the worktree, not the main checkout.
```

- [ ] **Step 4: Update `work-issue.md` step 8 to set ORCH_CONFIG**

Step 8 currently reads:
```
8. **Project sync.** `source ${CLAUDE_PLUGIN_ROOT}/scripts/orchestration/lib.sh && load_config && project_sync "$ISSUE" "In Review"`.
```
Replace with:
```
8. **Project sync.** `source "${CLAUDE_PLUGIN_ROOT}/scripts/orchestration/lib.sh" && ORCH_CONFIG="$REPO_ROOT/.claude/orchestration.json" load_config && project_sync "$ISSUE" "In Review"`.
```

- [ ] **Step 5: Update the prose `lib.sh` references in `qa-check.md` and `review-queue.md`**

These say "(source lib.sh first)". Make the path explicit and plugin-relative so the agent sources the right file. In both files, change the parenthetical `(source lib.sh first)` to:
```
(source "${CLAUDE_PLUGIN_ROOT}/scripts/orchestration/lib.sh" first; set ORCH_CONFIG to the main repo's .claude/orchestration.json if you are inside a worktree)
```

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(orch): move lane commands into plugin, reference CLAUDE_PLUGIN_ROOT

Relocate the four lane commands to plugins/orchestration/commands and repoint
script invocations to \${CLAUDE_PLUGIN_ROOT}/scripts/orchestration. Fix the
worktree config hazard in work-issue (capture REPO_ROOT before cd; set
ORCH_CONFIG for project_sync) and make the prose lib.sh paths explicit.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Add the `/orch-setup` command

**Files:**
- Create: `plugins/orchestration/commands/orch-setup.md`

**Interfaces:**
- Consumes: `${CLAUDE_PLUGIN_ROOT}/assets/{orchestration.json,labels.yml,task.yml,CLAUDE.md}` and `${CLAUDE_PLUGIN_ROOT}/scripts/orchestration/bootstrap-labels.sh` (Task 1).

- [ ] **Step 1: Write `plugins/orchestration/commands/orch-setup.md`**

````markdown
---
description: One-time setup — write config, install labels/issue-template, bootstrap labels, then print the human checklist.
---

You are the **Setup** lane. Run from the **target repo root** (cwd = the repo you want to orchestrate). Optional argument: `owner/repo` (and a bot login). All source paths are absolute under `${CLAUDE_PLUGIN_ROOT}/assets/...` — never bare relative, because cwd is the target repo, not the plugin dir.

Do exactly this:

1. **Prerequisite check.** Verify tooling and auth; stop (do nothing else) if any is missing:
   ```bash
   command -v gh jq yq || { echo "missing prerequisite (need gh, jq, yq)"; exit 1; }
   gh auth status || { echo "gh not authenticated — run: GH_TOKEN=... or gh auth login"; exit 1; }
   ```
2. **Config (guarded — binary, per spec §3.4).** If `./.claude/orchestration.json` already exists, **leave it untouched and report**. Only when it is absent: copy the template and fill `repo`/`bot` (from the `owner/repo` argument or by asking) — both happen inside the same absent-branch, so an existing config is never rewritten:
   ```bash
   mkdir -p .claude
   if [ -f .claude/orchestration.json ]; then
     echo ".claude/orchestration.json exists — left untouched"
   else
     cp "${CLAUDE_PLUGIN_ROOT}/assets/orchestration.json" .claude/orchestration.json
     tmp=$(mktemp); jq --arg r "owner/repo" --arg b "bot-login" '.repo=$r | .bot=$b' \
       .claude/orchestration.json > "$tmp" && mv "$tmp" .claude/orchestration.json
     echo "wrote .claude/orchestration.json (repo=owner/repo bot=bot-login)"
   fi
   ```
3. **Assets (guarded "if absent").** Install labels + issue template only when the destination is absent, so a re-run never clobbers user customizations:
   ```bash
   mkdir -p .github/ISSUE_TEMPLATE
   [ -f .github/labels.yml ] || cp "${CLAUDE_PLUGIN_ROOT}/assets/labels.yml" .github/labels.yml
   [ -f .github/ISSUE_TEMPLATE/task.yml ] || cp "${CLAUDE_PLUGIN_ROOT}/assets/task.yml" .github/ISSUE_TEMPLATE/task.yml
   ```
   Merge the conventions block into `CLAUDE.md` once, guarded by a sentinel (do nothing if already present):
   ```bash
   SENT='<!-- orchestration-conventions -->'
   if [ ! -f CLAUDE.md ]; then printf '%s\n' "$SENT" > CLAUDE.md; cat "${CLAUDE_PLUGIN_ROOT}/assets/CLAUDE.md" >> CLAUDE.md;
   elif ! grep -qF "$SENT" CLAUDE.md; then printf '\n%s\n' "$SENT" >> CLAUDE.md; cat "${CLAUDE_PLUGIN_ROOT}/assets/CLAUDE.md" >> CLAUDE.md; fi
   ```
4. **Label bootstrap (always runs — NOT guarded).** This runs on every invocation so a re-run after an earlier auth failure still converges:
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/orchestration/bootstrap-labels.sh" .github/labels.yml \
     || { echo "setup incomplete — label bootstrap failed; fix gh auth and re-run /orch-setup"; exit 1; }
   ```
5. **Manual-steps checklist (print — do NOT attempt to automate).** Tell the human to:
   - Create a **bot account + fine-grained PAT** scoped to the target repo: Contents RW, Pull requests RW, Issues RW, Projects RW; export `GH_TOKEN=github_pat_...` (HTTPS, not ssh).
   - **Add the bot as a collaborator** on the repo.
   - **Branch protection on `main`:** require 1 human review (or CODEOWNERS), no force-push, include administrators; the bot must **not** be an admin.
6. **Verify (optional).** Confirm labels exist and echo the lane-run commands:
   ```bash
   gh label list --repo "$(jq -r .repo .claude/orchestration.json)" | grep -c '^status:' || true
   ```
   Then print: Triager `/loop 10m /triage` · Coder `/loop /work-issue` · Reviewer `/loop 5m /review-queue` · QA `/qa-check` (under `/goal`).

Never create the PAT or change branch protection yourself — those are human, security-sensitive actions.
````

- [ ] **Step 2: Commit**

```bash
git add plugins/orchestration/commands/orch-setup.md
git commit -m "feat(orch): add /orch-setup command (prereq+config+assets+labels, human checklist)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Plugin manifests + marketplace

**Files:**
- Create: `plugins/orchestration/.claude-plugin/plugin.json`
- Create: `.claude-plugin/marketplace.json`

> The exact manifest schema must be validated against current Claude Code plugin docs (spec §3.6). The JSON below reflects the documented shape; Step 3 verifies it loads in a live install.

- [ ] **Step 1: Write `plugins/orchestration/.claude-plugin/plugin.json`**

```json
{
  "name": "orchestration",
  "version": "1.0.0",
  "description": "GitHub-native agent orchestration: Triager/Coder/Reviewer/QA lanes over Issues/PRs/labels, plus /orch-setup.",
  "author": { "name": "Laeyoung Chang" }
}
```

- [ ] **Step 2: Write `.claude-plugin/marketplace.json`**

```json
{
  "name": "ganpan",
  "owner": { "name": "Laeyoung Chang" },
  "plugins": [
    {
      "name": "orchestration",
      "source": "./plugins/orchestration",
      "description": "GitHub-native agent orchestration lanes + /orch-setup."
    }
  ]
}
```

- [ ] **Step 3: Verify manifests parse and load**

```bash
jq . .claude-plugin/marketplace.json
jq . plugins/orchestration/.claude-plugin/plugin.json
```
Expected: both pretty-print (valid JSON, exit 0).

Then validate against a live Claude Code install (spec §3.2 feasibility gate — `${CLAUDE_PLUGIN_ROOT}` must actually expand in command markdown):
```bash
# In Claude Code: /plugin marketplace add ./   then install "orchestration",
# run /orch-setup in a scratch repo, and confirm a script invocation resolves
# (e.g. bootstrap-labels.sh runs and ${CLAUDE_PLUGIN_ROOT} did not expand to empty).
```
If `${CLAUDE_PLUGIN_ROOT}` does not expand in command markdown on this Claude Code version, apply the spec §3.2 mitigation (SessionStart hook exporting `CLAUDE_PLUGIN_ROOT`) before shipping. Record the result in the PR description.

- [ ] **Step 4: Commit**

```bash
git add .claude-plugin/marketplace.json plugins/orchestration/.claude-plugin/plugin.json
git commit -m "feat(orch): add plugin + marketplace manifests

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Repoint `install.sh` + `--force` + version sentinel + e2e test

**Files:**
- Modify: `install.sh` (source paths, copy-in layout, `${CLAUDE_PLUGIN_ROOT}/`→`./` rewrite, `--force`, sentinel)
- Create: `tests/install.bats`

**Interfaces:**
- Consumes: `plugins/orchestration/{scripts/orchestration,commands,assets}` (Tasks 1–3) and `plugins/orchestration/.claude-plugin/plugin.json` version (Task 4).

> `install.sh` currently copies from repo-root `scripts/`, `.claude/commands`, `.github/`. Those locations no longer exist after Task 1, so this task rewrites its source paths and adds the copy-in semantics from spec §3.5.

> **Whole-body replacement, not additive.** The current `install.sh` already has a "portable files" copy section + a config-copy block that all `cp` from `$SRC/scripts/...`, `$SRC/.claude/commands/...`, `$SRC/.github/...`, and `$SRC/.claude/orchestration.json` — paths that **no longer exist after Task 1**. Under `set -euo pipefail` those stale `cp`s would abort the script. Steps 3–5 below **replace that entire copy body** (everything from the first `cp`/`mkdir` of portable files through the config copy). After this task, `install.sh` must contain **no** `$SRC/scripts`, `$SRC/.claude/commands`, `$SRC/.github`, or `$SRC/.claude/orchestration.json` reference. Verify at the end: `grep -nE '\$SRC/(scripts|\.claude/commands|\.github|\.claude/orchestration\.json)' install.sh` → no output (only `$SRC/CLAUDE.md` may legitimately remain if you kept the merge sourced from root — but Step 3 repoints even that to `$PLUGIN/assets/CLAUDE.md`, so expect zero).

- [ ] **Step 1: Write the failing e2e test `tests/install.bats`**

```bash
#!/usr/bin/env bats

setup() {
  REPO_ROOT="$BATS_TEST_DIRNAME/.."
  TARGET="$BATS_TEST_TMPDIR/target"
  mkdir -p "$TARGET/.git"
}

@test "install copies engine, commands, assets into the target repo" {
  run bash "$REPO_ROOT/install.sh" "$TARGET"
  [ "$status" -eq 0 ]
  [ -f "$TARGET/scripts/orchestration/claim.sh" ]
  [ -f "$TARGET/.claude/commands/work-issue.md" ]
  [ -f "$TARGET/.github/labels.yml" ]
  [ -f "$TARGET/.claude/orchestration.json" ]
}

@test "copied commands have zero CLAUDE_PLUGIN_ROOT residue (path-drift guard)" {
  run bash "$REPO_ROOT/install.sh" "$TARGET"
  [ "$status" -eq 0 ]
  run grep -rl CLAUDE_PLUGIN_ROOT "$TARGET/.claude/commands" "$TARGET/scripts/orchestration"
  [ "$status" -ne 0 ]   # grep -l exits non-zero when there are no matches
}

@test "both .sh and .md copies carry exactly one version sentinel" {
  run bash "$REPO_ROOT/install.sh" "$TARGET"
  [ "$status" -eq 0 ]
  run grep -c 'ganpan-orchestration:' "$TARGET/scripts/orchestration/claim.sh"
  [ "$output" = "1" ]
  run grep -c 'ganpan-orchestration:' "$TARGET/.claude/commands/work-issue.md"
  [ "$output" = "1" ]
  # the .md sentinel must be an HTML comment, not a Markdown heading
  run grep -q '<!-- ganpan-orchestration:' "$TARGET/.claude/commands/work-issue.md"
  [ "$status" -eq 0 ]
}

@test "re-run with --force restamps without doubling the sentinel" {
  run bash "$REPO_ROOT/install.sh" "$TARGET"
  [ "$status" -eq 0 ]
  run bash "$REPO_ROOT/install.sh" "$TARGET" --force
  [ "$status" -eq 0 ]
  run grep -c 'ganpan-orchestration:' "$TARGET/scripts/orchestration/claim.sh"
  [ "$output" = "1" ]   # .sh restamped, not doubled
  run grep -c 'ganpan-orchestration:' "$TARGET/.claude/commands/work-issue.md"
  [ "$output" = "1" ]   # .md restamped, not doubled
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/install.bats`
Expected: FAIL (current `install.sh` copies from the old repo-root paths / has no sentinel).

- [ ] **Step 3: Rewrite `install.sh` source paths and copy-in layout**

**Replace the existing arg-parse block** in `install.sh` (currently lines 25–33, handling only `--with-tests`) with the version below — this is a whole-block replacement, not an addition, so there is no duplicate loop (`die` already exists at install.sh:19):
```bash
FORCE=""
for arg in "$@"; do
  case "$arg" in
    --with-tests) WITH_TESTS=1 ;;
    --force) FORCE=1 ;;
    -h|--help) usage; exit 0 ;;     # preserve the existing help flag
    -*) die "unknown flag: $arg" ;;
    *) [ -z "${TARGET:-}" ] && TARGET="$arg" || die "unexpected arg: $arg" ;;
  esac
done
```
(Keep whatever help handler the current loop uses — if it inlines a `grep`/`sed` usage dump rather than a `usage` function, retain that exact line; the point is the replacement must not drop `-h|--help`.)
Set the source root and version (sentinel *token* is shared; comment *syntax* differs by file type — see Step 5):
```bash
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$SRC/plugins/orchestration"
VERSION=$(jq -r '.version' "$PLUGIN/.claude-plugin/plugin.json")
SENTINEL_TOKEN="ganpan-orchestration: v$VERSION"
```
Create dirs and copy the **assets** (these are NOT sentinel-stamped — plain "if absent" guard; engine `.sh` and command `.md` files are copied by the guarded loop in Step 5, **not** here):
```bash
mkdir -p "$TARGET/scripts/orchestration" "$TARGET/.claude/commands" "$TARGET/.github/ISSUE_TEMPLATE"
[ -f "$TARGET/.github/labels.yml" ]            || cp "$PLUGIN/assets/labels.yml" "$TARGET/.github/labels.yml"
[ -f "$TARGET/.github/ISSUE_TEMPLATE/task.yml" ] || cp "$PLUGIN/assets/task.yml" "$TARGET/.github/ISSUE_TEMPLATE/task.yml"
[ -f "$TARGET/.claude/orchestration.json" ]    || cp "$PLUGIN/assets/orchestration.json" "$TARGET/.claude/orchestration.json"
```
**Repoint the CLAUDE.md merge source (concrete):** the current `install.sh` CLAUDE.md-merge block (≈ lines 94–101) `cat`s `"$SRC/CLAUDE.md"` at two spots (≈ lines 95 and 100). Replace both `"$SRC/CLAUDE.md"` with `"$PLUGIN/assets/CLAUDE.md"`. (Both files are identical today — root `CLAUDE.md` *is* the orchestration conventions block — but sourcing from `assets/` keeps the single-source-of-truth invariant.) The merge keeps its `<!-- orchestration-conventions -->` sentinel guard unchanged. `orch-setup.md` is plugin-only and is **not** copied into the target.

- [ ] **Step 4: (reference only — do NOT run standalone) the `${CLAUDE_PLUGIN_ROOT}/` → `./` rewrite**

This documents the per-command rewrite that is **already inlined** in the Step 5 loop (line `sed -i '' 's|\${CLAUDE_PLUGIN_ROOT}/|./|g' "$dest"`). There is no separate code to run here — `$dest` is the Step 5 loop variable. The rewrite strips the variable and its trailing slash together, preserving any surrounding quote (spec §3.5):
```bash
# illustrative only — the live copy is in Step 5:
sed -i '' 's|\${CLAUDE_PLUGIN_ROOT}/|./|g' "$dest"
```
So `"${CLAUDE_PLUGIN_ROOT}/scripts/orchestration/claim.sh"` → `"./scripts/orchestration/claim.sh"`. It runs **after** the copy and **before** `stamp`, so the sentinel stays the true last line. Engine `.sh` files are not rewritten (they contain no `${CLAUDE_PLUGIN_ROOT}`).

- [ ] **Step 5: Add `--force` flag + version-sentinel stamping**

Sentinel applies to **engine `.sh` and command `.md`** files (NOT `CLAUDE.md` — merge-managed, spec §3.5). The comment **syntax differs by type**: a `.md` file must use an HTML comment (`<!-- … -->`) because a leading `#` renders as a Markdown heading, not a comment; a `.sh` file uses `#`. Both carry the same `$SENTINEL_TOKEN` so the detection grep is uniform.

Add these helpers and a stamp/skip pass that runs over each copied destination file (the loop variable is `dest`):
```bash
# stamp <file> — append the version sentinel as the last line, in the right comment syntax.
stamp() {
  local dest="$1"
  sed -i '' "\|$SENTINEL_TOKEN|d" "$dest" 2>/dev/null || true   # drop any prior sentinel (| delimiter: robust to any version string)
  case "$dest" in
    *.md) printf '\n<!-- %s -->\n' "$SENTINEL_TOKEN" >> "$dest" ;;
    *)    printf '\n# %s\n'        "$SENTINEL_TOKEN" >> "$dest" ;;
  esac
}
# needs_write <file> — decide whether to (re)write a destination before copying.
needs_write() {
  local dest="$1" cur
  [ ! -f "$dest" ] && return 0                                 # absent → write
  [ -n "$FORCE" ] && return 0                                  # --force → overwrite
  cur=$(grep -m1 "$SENTINEL_TOKEN" "$dest" || true)
  [ -n "$cur" ] && return 1                                    # same version sentinel present → skip
  grep -q 'ganpan-orchestration:' "$dest" && return 0          # different version → overwrite
  echo "warn: $dest has no sentinel (user-owned); skipping (use --force)"; return 1
}
```
Then run the **single authoritative copy loop** over engine `.sh` and command `.md` (this is the only place those files are copied — Step 3 deliberately copied only assets):
```bash
# engine scripts (no rewrite)
for src in "$PLUGIN"/scripts/orchestration/*.sh; do
  dest="$TARGET/scripts/orchestration/$(basename "$src")"
  needs_write "$dest" && { cp "$src" "$dest"; chmod +x "$dest"; stamp "$dest"; }
done
# lane commands (rewrite ${CLAUDE_PLUGIN_ROOT}/ -> ./ between copy and stamp; orch-setup.md excluded)
for name in work-issue triage review-queue qa-check; do
  src="$PLUGIN/commands/$name.md"; dest="$TARGET/.claude/commands/$name.md"
  needs_write "$dest" && { cp "$src" "$dest"; sed -i '' 's|\${CLAUDE_PLUGIN_ROOT}/|./|g' "$dest"; stamp "$dest"; }
done
```
`stamp` strips any existing sentinel first, so `--force` re-stamping replaces rather than doubles; `needs_write` skips same-version files so a no-arg re-run is a no-op.

- [ ] **Step 6: Run the e2e test — expect pass**

Run: `bats tests/install.bats`
Expected: `4 tests, 0 failures`.

- [ ] **Step 7: shellcheck install.sh**

Run: `shellcheck install.sh`
Expected: exit 0.

- [ ] **Step 8: Commit**

```bash
git add install.sh tests/install.bats
git commit -m "feat(orch): repoint install.sh to plugin subtree, add --force + version sentinel

Copy engine/commands/assets from plugins/orchestration into the target repo,
rewrite \${CLAUDE_PLUGIN_ROOT}/ -> ./ in copied commands, and stamp a
# ganpan-orchestration version sentinel for deterministic copy-in upgrades
(CLAUDE.md excluded — merge-managed). Add tests/install.bats e2e with a
path-drift guard.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Update `docs/SETUP.md` for the plugin install path

**Files:**
- Modify: `docs/SETUP.md`

> Concrete edits per spec §3.7. Read the current file first; it is entirely v1 (repo-root layout).

- [ ] **Step 1: Add a Plugin install section at the top**

Insert above the existing "Steps" section:
```markdown
## Install (plugin — recommended)
1. `/plugin marketplace add Laeyoung/Ganpan`
2. Install the `orchestration` plugin.
3. In the target repo, run `/orch-setup owner/repo` — it checks prerequisites,
   writes `.claude/orchestration.json`, installs `.github/labels.yml` + the issue
   template, merges the CLAUDE.md conventions, and bootstraps labels.
4. Complete the human checklist `/orch-setup` prints (bot PAT, collaborator,
   branch protection).

## Install (copy-in — alternative)
Run `./install.sh <target-repo-path>` from a ganpan checkout. Then complete the
same human checklist below.

### Upgrading a copy-in install
`install.sh` re-run upgrades files whose version sentinel differs. **v1 files
predate the sentinel**, so the first upgrade off a v1 copy must use
`./install.sh <target> --force` (overwrite + stamp regardless), or delete the
old `scripts/orchestration/` + `.claude/commands/` first. Subsequent upgrades
are automatic.
```

- [ ] **Step 2: Replace the manual config + label-bootstrap steps**

In the existing numbered "Steps", change step 3 (was "Edit `.claude/orchestration.json`") to:
```markdown
3. **Config** is written by `/orch-setup` (plugin) or `install.sh` (copy-in). Set `repo`, `bot`, and (optionally) `project.number`.
```
and step 4 (was "Bootstrap labels: `scripts/orchestration/bootstrap-labels.sh …`") to:
```markdown
4. **Labels** are bootstrapped by `/orch-setup`. For the copy-in path run `scripts/orchestration/bootstrap-labels.sh .github/labels.yml`.
```
Leave the PAT / branch-protection / worktree-dependency steps unchanged (still human actions).

- [ ] **Step 3: Commit**

```bash
git add docs/SETUP.md
git commit -m "docs(orch): document plugin install path and /orch-setup in SETUP

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Final verification

- [ ] **Full suite:** `bats tests/orchestration/ tests/install.bats` → all green (46 + 4).
- [ ] **shellcheck:** `shellcheck plugins/orchestration/scripts/orchestration/*.sh install.sh` → exit 0.
- [ ] **Manifests:** `jq . .claude-plugin/marketplace.json plugins/orchestration/.claude-plugin/plugin.json` → valid.
- [ ] **Live plugin check + §5 unset-guard (spec §3.2/§5 gate):** install the marketplace locally, run `/orch-setup` in a scratch repo, confirm `${CLAUDE_PLUGIN_ROOT}` expands in command markdown. **If it expands**, the spec §5 "unset → fail loudly" guard is satisfied implicitly (a bad expansion yields `/scripts/...` which fails with a clear "No such file"). **If it does NOT expand**, add a `SessionStart` hook (plugin-side) that exports `CLAUDE_PLUGIN_ROOT` and `exit 1`s loudly when it cannot resolve — this is the correct home for the guard, **not** the command markdown: a markdown `[ -z "${CLAUDE_PLUGIN_ROOT}" ]` guard would survive `install.sh`'s `${CLAUDE_PLUGIN_ROOT}/`→`./` rewrite (no trailing slash to match) and then wrongly fire in every copy-in install. Record the outcome in the PR.
- [ ] **No duplicate engine:** `git ls-files 'scripts/orchestration/*'` → empty (single source of truth under `plugins/`).
- [ ] **Spec coverage:** §3.1 layout (T1), §3.2 command rewrite + `${CLAUDE_PLUGIN_ROOT}` feasibility (T2 + live check above), §3.3 config discovery + worktree fix (T1+T2), §3.4 /orch-setup (T3), §3.5 install.sh + sentinel (T5), §3.6 manifests (T4), §3.7 SETUP (T6), §4 data flow (realized by T2+T3 runtime behavior), §5 error handling (config-guard T3; CLAUDE.md sentinel T1/T3; `${CLAUDE_PLUGIN_ROOT}` unset → live check above; engine exit codes unchanged), §6 tests (T1+T5), §8 atomic move + migration (T1 + T6 upgrade note) — all mapped.
- [ ] **PR:** open against `main`; a human reviews and merges (merge-gate).
