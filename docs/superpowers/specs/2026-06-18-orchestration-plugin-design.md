# Orchestration Plugin + `/orch-setup` — Design Spec

**Date:** 2026-06-18
**Status:** Approved (brainstorming) → pending implementation plan
**Branch:** `feat/orchestration-plugin`
**Builds on:** `docs/superpowers/specs/2026-06-09-github-orchestration-spec-design.md` (v1 toolkit, merged in PR #1)

## 1. Goal

Make the GitHub-native orchestration toolkit installable into **any target repo** two ways:

1. **As a Claude Code plugin** distributed from this repo as a marketplace — users run `/plugin marketplace add Laeyoung/Ganpan`, install `orchestration`, and get the four lane commands (`/work-issue`, `/triage`, `/review-queue`, `/qa-check`) plus a new `/orch-setup` command — without copying script files into their repo.
2. **As a copy-in installer** (`install.sh`) — the existing non-plugin path for users who prefer the files committed into their own repo.

Both paths share a single source of truth for the engine scripts.

## 2. Problem with the current layout

The v1 toolkit lives at the repo root (`scripts/orchestration/`, `.claude/commands/`, `.github/`) and the lane commands invoke scripts via **repo-root-relative** paths (`scripts/orchestration/claim.sh`). That works only when the scripts are committed into the same repo the lanes run against. For plugin distribution:

- A git-based plugin ships only its **own subtree**, so the engine scripts must live *inside* the plugin directory to travel with it.
- `lib.sh` discovers config relative to the **script location** (`$SCRIPT_DIR/../../.claude/orchestration.json`). When the script lives in a plugin (outside the target repo), that path no longer points at the target repo's config.

## 3. Architecture

### 3.1 Repo becomes a plugin marketplace; toolkit consolidates under `plugins/orchestration/`

```
ganpan/
├── .claude-plugin/
│   └── marketplace.json                 # NEW — declares the orchestration plugin
├── plugins/
│   └── orchestration/
│       ├── .claude-plugin/
│       │   └── plugin.json              # NEW — plugin manifest
│       ├── commands/                    # MOVED from .claude/commands/ + edited
│       │   ├── work-issue.md
│       │   ├── triage.md
│       │   ├── review-queue.md
│       │   ├── qa-check.md
│       │   └── orch-setup.md            # NEW — /orch-setup
│       ├── scripts/orchestration/       # MOVED from repo-root scripts/orchestration/
│       │   ├── lib.sh  claim.sh  reclaim.sh  heartbeat.sh
│       │   ├── wip-check.sh  detect-test-cmd.sh  bootstrap-labels.sh
│       └── assets/                      # NEW — payload /orch-setup installs into a target repo
│           ├── orchestration.json       # config template (was .claude/orchestration.json)
│           ├── labels.yml               # was .github/labels.yml
│           ├── task.yml                 # was .github/ISSUE_TEMPLATE/task.yml
│           └── CLAUDE.md                # conventions block to merge (was repo-root CLAUDE.md)
├── tests/orchestration/                 # KEPT — paths repointed to plugins/orchestration/scripts
├── docs/SETUP.md                        # KEPT — updated for plugin install path
├── install.sh                           # KEPT — source paths repointed to plugins/orchestration/
└── CLAUDE.md                            # KEPT at root — ganpan's own repo conventions
```

Rationale for moving (not duplicating): a distributable plugin must own its scripts, and duplicated scripts drift. One canonical copy under `plugins/orchestration/`, consumed by the plugin, the tests, and `install.sh`.

### 3.2 Lane commands reference the plugin root

Every script invocation in the four lane commands changes from repo-relative to plugin-relative:

```
scripts/orchestration/claim.sh   →   "${CLAUDE_PLUGIN_ROOT}/scripts/orchestration/claim.sh"
```

`${CLAUDE_PLUGIN_ROOT}` is set by Claude Code to the installed plugin's directory. The lanes still run with **cwd = target repo root** (unchanged), so all `gh`/`git`/worktree operations continue to target the user's repo.

### 3.3 `lib.sh` config discovery becomes cwd-relative

Change the fallback search order in `load_config` from script-relative to:

1. `$ORCH_CONFIG` (explicit override — used by tests and power users)
2. `./.claude/orchestration.json` (cwd-relative — the target repo root, where every lane runs)

This makes the engine location-independent: it works whether the scripts are bundled in a plugin (cwd = target repo) or copied into the repo by `install.sh` (cwd = target repo). The `$SCRIPT_DIR/../../` fallback is removed.

**Compatibility:** all `*.bats` tests already set `$ORCH_CONFIG` explicitly, so the discovery change does not affect them. `detect-test-cmd.sh` also reads config via the same `$ORCH_CONFIG`/cwd path — update its internal `cfg=` default accordingly.

### 3.4 `/orch-setup` command (automation + guidance hybrid)

A new command file `plugins/orchestration/commands/orch-setup.md`. Optional argument: `owner/repo` (and bot login). Behavior:

1. **Prerequisite check** — verify `gh`, `jq`, `yq` on PATH and `gh auth status` succeeds. Report missing items and stop if any are absent.
2. **Config** — if `./.claude/orchestration.json` is absent, copy `${CLAUDE_PLUGIN_ROOT}/assets/orchestration.json` into place; fill `repo`/`bot` from the argument or by asking. If it already exists, leave it untouched and report.
3. **Assets** — copy `assets/labels.yml` → `.github/labels.yml` and `assets/task.yml` → `.github/ISSUE_TEMPLATE/task.yml` (create dirs as needed). Merge the `assets/CLAUDE.md` conventions block into the target's `CLAUDE.md` once, guarded by the `<!-- orchestration-conventions -->` sentinel (same logic as `install.sh`).
4. **Label bootstrap** — run `"${CLAUDE_PLUGIN_ROOT}/scripts/orchestration/bootstrap-labels.sh" .github/labels.yml`.
5. **Manual-steps checklist (printed, not automated)** — bot account + fine-grained PAT (Contents/PR/Issues/Projects RW), add bot as collaborator, branch protection on `main` (1 human review, bot not admin). These are GitHub UI / security actions a human must perform; the command surfaces them as an explicit checklist.
6. **Verification (optional)** — confirm labels now exist (`gh label list`) and echo the lane-run commands.

`/orch-setup` performs steps 1–4 and 6 automatically; step 5 is guidance only — matching the approved "automation + guidance hybrid" scope.

### 3.5 `install.sh` stays as the copy-in alternative

Repoint its source paths from repo-root (`scripts/orchestration/`, `.claude/commands/`, `.github/...`) to `plugins/orchestration/{scripts,commands,assets}`. **Caveat:** when copied into a target repo (non-plugin path), the lane commands' `${CLAUDE_PLUGIN_ROOT}` references must resolve to the repo root. `install.sh` will rewrite `${CLAUDE_PLUGIN_ROOT}/scripts/orchestration/` → `scripts/orchestration/` in the copied command files (a `sed` pass), since in the copy-in model the scripts sit at the repo root. The CLAUDE.md merge + idempotency behavior already implemented stays.

### 3.6 Plugin manifests

`.claude-plugin/marketplace.json` (repo root) declares one plugin sourced from `./plugins/orchestration`. `plugins/orchestration/.claude-plugin/plugin.json` carries name/version/description/author and relies on default discovery of `commands/`. **The exact manifest field names will be validated against current Claude Code plugin documentation during implementation** (schema may have changed); the design fixes the structure, not the precise keys.

## 4. Data flow (plugin path)

```
user: /plugin marketplace add Laeyoung/Ganpan → install "orchestration"
user (in target repo): /orch-setup owner/repo
  → checks prereqs
  → writes .claude/orchestration.json (repo, bot)
  → installs .github/labels.yml + ISSUE_TEMPLATE, merges CLAUDE.md
  → bootstrap-labels.sh creates labels via gh
  → prints PAT + branch-protection checklist
human: completes PAT / collaborator / branch protection
user: /loop /work-issue   (lanes call ${CLAUDE_PLUGIN_ROOT}/scripts/..., cwd = target repo)
  → claim.sh reads ./.claude/orchestration.json, operates on owner/repo via gh
```

## 5. Error handling

- **Missing prereqs / no `gh auth`** → `/orch-setup` reports and stops before mutating anything.
- **Existing config** → never clobbered; reported and skipped.
- **CLAUDE.md** → conventions appended once; re-runs are no-ops (sentinel guard).
- **`${CLAUDE_PLUGIN_ROOT}` unset** (command run outside plugin context) → commands fail loudly with a clear message rather than silently using a wrong path.
- Engine script exit codes (claim/reclaim/heartbeat/wip/detect) are unchanged from v1.

## 6. Testing

- **Move regression:** after relocating scripts, `bats tests/orchestration/` must stay green (45 tests). Test files update only the `SCRIPT=`/`LIB=` path prefixes to `plugins/orchestration/scripts/...`.
- **`lib.sh` discovery:** add a test that `load_config` finds `./.claude/orchestration.json` from cwd when `$ORCH_CONFIG` is unset.
- **Manifest validity:** `jq . .claude-plugin/marketplace.json` and `jq . plugins/orchestration/.claude-plugin/plugin.json` parse cleanly.
- **`install.sh` e2e:** re-run the temp-repo dry run (copy + CLAUDE.md merge + idempotency + the new `${CLAUDE_PLUGIN_ROOT}`→`scripts/` rewrite) and confirm the copied lanes reference repo-relative paths.
- **`shellcheck`** clean on all `.sh` (engine + install.sh).
- Command files (`.md`) remain prompt files — verified by the manual integration checklist in `docs/SETUP.md`, not unit tests.

## 7. Out of scope (YAGNI)

- Fully automating PAT issuance or branch protection (security-sensitive, brittle — kept as a human checklist).
- Publishing to any external/official plugin registry beyond this repo acting as a marketplace.
- A separate dedicated plugin repo (single-repo marketplace chosen).
- Versioned plugin release automation / changelog tooling.

## 8. Migration / sequencing

1. v1 merged to `main` via PR #1 (done).
2. Work proceeds on `feat/orchestration-plugin` (this branch).
3. The move is a restructure of v1's layout; tests and `install.sh` are updated in lockstep so the suite never goes red across the move.
4. A follow-up PR delivers the plugin; a human reviews and merges (repo merge-gate convention).
