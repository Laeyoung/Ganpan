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

Every script invocation changes from repo-relative to plugin-relative:

```
scripts/orchestration/claim.sh   →   "${CLAUDE_PLUGIN_ROOT}/scripts/orchestration/claim.sh"
```

Not all lane commands contain script invocations, and the edit pass must be content-aware (not a blind global sed across all four files):

- `work-issue.md` — invokes `wip-check.sh`/`claim.sh`/`heartbeat.sh`/`detect-test-cmd.sh` and has an explicit `source scripts/orchestration/lib.sh` shell line.
- `triage.md` — invokes `reclaim.sh`.
- `qa-check.md` — invokes `detect-test-cmd.sh`; its `project_sync` step references `lib.sh` only as **prose** ("(source lib.sh first)"), not an explicit shell `source` line.
- `review-queue.md` — calls only `gh`; references `lib.sh` only as **prose**; has **no** `scripts/orchestration/<x>.sh` shell invocation.

The only explicit shell `source …/lib.sh` line is in `work-issue.md` — that one must be repointed. The prose `lib.sh` mentions in `qa-check.md`/`review-queue.md` should be updated to the plugin-relative path as prose (so the agent writes the right path when it runs them), but there is no literal shell line there to sed.

`${CLAUDE_PLUGIN_ROOT}` is set by Claude Code to the installed plugin's directory. The lanes still run with **cwd = target repo root** (unchanged), so all `gh`/`git`/worktree operations continue to target the user's repo.

**Feasibility risk — `${CLAUDE_PLUGIN_ROOT}` in command markdown.** This variable is documented as substituted inline in skill/agent/command content, but there is an open report (GitHub claude-code #9354) that expansion may not fire inside *command* markdown in some versions. Implementation MUST verify against a live plugin install before shipping. Mitigation if it does not expand: have each command resolve the plugin root once at the top (e.g. derive from a `SessionStart` hook that exports `CLAUDE_PLUGIN_ROOT`, or a documented fallback), and reference that — never let a failed expansion silently become `/scripts/...`.

### 3.3 `lib.sh` config discovery becomes cwd-relative

Change the fallback search order in `load_config` from script-relative to:

1. `$ORCH_CONFIG` (explicit override — used by tests and power users)
2. `./.claude/orchestration.json` (cwd-relative — the target repo root, where every lane runs)

This makes the engine location-independent: it works whether the scripts are bundled in a plugin (cwd = target repo) or copied into the repo by `install.sh` (cwd = target repo). The `$SCRIPT_DIR/../../` fallback is removed.

**Worktree cwd hazard.** `work-issue.md` runs from the repo root but `cd`s into `wt-issue-<n>` for implement/test (step 5), and a git worktree does **not** contain the main checkout's `.claude/` dir. Step 8 then `source`s `lib.sh` and calls `load_config`/`project_sync`; if still inside the worktree, the cwd-relative `./.claude/orchestration.json` would not resolve. Resolution — the command MUST point `ORCH_CONFIG` at the **main checkout's** config before `load_config`. Note `git rev-parse --show-toplevel` is wrong here: from inside a linked worktree it returns the *worktree's* own root (`wt-issue-<n>`), not the main checkout. Use one of:

- **Preferred:** capture the repo root at the very start of the command, before any `cd` (`REPO_ROOT="$PWD"`), then `ORCH_CONFIG="$REPO_ROOT/.claude/orchestration.json"`.
- **Or** derive the main checkout from git: `MAIN_ROOT="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"` (the common `.git` dir's parent is the main worktree root), then `ORCH_CONFIG="$MAIN_ROOT/.claude/orchestration.json"`.

The spec mandates the explicit `ORCH_CONFIG` form for any `load_config` call that may run from inside a worktree.

**Compatibility:** the discovery change is invisible to tests that call `load_config`, because they all set `$ORCH_CONFIG` explicitly. (`stub.bats` sets no `$ORCH_CONFIG` but never calls `load_config`, so it is unaffected — the earlier blanket "all tests set `$ORCH_CONFIG`" claim is imprecise.) Two code edits are required, not one: (a) `lib.sh` `load_config` fallback, **and** (b) `detect-test-cmd.sh` has its **own** independent `cfg=` line. That line already respects `$ORCH_CONFIG` today (`cfg="${ORCH_CONFIG:-$SCRIPT_DIR/../../.claude/orchestration.json}"`); only its **fallback** must change from `$SCRIPT_DIR/../../.claude/orchestration.json` to `./.claude/orchestration.json` — no new variable, just the fallback. A sed on `lib.sh` alone is insufficient because this second site is independent.

### 3.4 `/orch-setup` command (automation + guidance hybrid)

A new command file `plugins/orchestration/commands/orch-setup.md`. Optional argument: `owner/repo` (and bot login). Behavior:

All source paths below are absolute (`${CLAUDE_PLUGIN_ROOT}/assets/...`) — never bare relative, because cwd is the target repo root, not the plugin dir.

1. **Prerequisite check** — verify `gh`, `jq`, `yq` on PATH and `gh auth status` succeeds. Report missing items and stop if any are absent.
2. **Config** — if `./.claude/orchestration.json` is absent, copy `${CLAUDE_PLUGIN_ROOT}/assets/orchestration.json` into place; fill `repo`/`bot` from the argument or by asking. If it already exists, leave it untouched and report.
3. **Assets (each guarded "if absent")** — copy `${CLAUDE_PLUGIN_ROOT}/assets/labels.yml` → `.github/labels.yml` and `${CLAUDE_PLUGIN_ROOT}/assets/task.yml` → `.github/ISSUE_TEMPLATE/task.yml`, creating dirs as needed. Like the config, these are copied **only if the destination is absent** and reported-skipped otherwise, so a re-run never clobbers user-customized labels/templates. Merge the `${CLAUDE_PLUGIN_ROOT}/assets/CLAUDE.md` conventions block into the target's `CLAUDE.md` once, guarded by the `<!-- orchestration-conventions -->` sentinel (same logic as `install.sh`).
4. **Label bootstrap** — after step 3 has ensured `.github/labels.yml` exists, run `"${CLAUDE_PLUGIN_ROOT}/scripts/orchestration/bootstrap-labels.sh" .github/labels.yml`. (`bootstrap-labels.sh` itself is idempotent via `gh label create --force`.) **This step is NOT guarded by an "if absent" check** — unlike the file copies in steps 2–3, it runs on every `/orch-setup` invocation. This matters for partial-failure recovery: if a first run wrote the config/assets but the label bootstrap failed (API error, expired auth), a re-run skips the already-written files (reported) and **still retries the bootstrap**, so setup converges. The command must report "setup incomplete — label bootstrap failed, re-run /orch-setup after fixing auth" on failure rather than exiting silently.
5. **Manual-steps checklist (printed, not automated)** — bot account + fine-grained PAT (Contents/PR/Issues/Projects RW), add bot as collaborator, branch protection on `main` (1 human review, bot not admin). These are GitHub UI / security actions a human must perform; the command surfaces them as an explicit checklist.
6. **Verification (optional)** — confirm labels now exist (`gh label list`) and echo the lane-run commands.

`/orch-setup` performs steps 1–4 and 6 automatically; step 5 is guidance only — matching the approved "automation + guidance hybrid" scope.

### 3.5 `install.sh` stays as the copy-in alternative

Repoint its source paths from repo-root (`scripts/orchestration/`, `.claude/commands/`, `.github/...`) to `plugins/orchestration/{scripts,commands,assets}`.

**Copy-in destination (made explicit):** `install.sh` copies engine scripts to `scripts/orchestration/` at the **target repo root**, lane commands to `.claude/commands/`, and assets to `.github/` + `.claude/orchestration.json`. In the copy-in model the scripts therefore sit at the repo root, so the lanes must use repo-relative `scripts/orchestration/...`, not `${CLAUDE_PLUGIN_ROOT}/...`.

**Rewrite of `${CLAUDE_PLUGIN_ROOT}`:** the source for `install.sh` is the **plugin-canonical** command files under `plugins/orchestration/commands/` — i.e. the post-§3.2-rewrite files that use `"${CLAUDE_PLUGIN_ROOT}/scripts/orchestration/..."`, *not* today's bare repo-relative files (which §3.2 has not yet been applied to). The implementation order is: first §3.2 makes the plugin command files use `${CLAUDE_PLUGIN_ROOT}`, then `install.sh` copies those and rewrites them back to repo-relative. Because those canonical files typically double-quote the path, a naive `sed 's|${CLAUDE_PLUGIN_ROOT}/scripts/orchestration/|scripts/orchestration/|'` leaves a dangling leading quote (`"scripts/...`). The rewrite must strip the variable **and its trailing slash together**, preserving any surrounding quote — e.g. `sed 's|\${CLAUDE_PLUGIN_ROOT}/|./|g'` applied uniformly so `"${CLAUDE_PLUGIN_ROOT}/scripts/orchestration/claim.sh"` → `"./scripts/orchestration/claim.sh"`. The CLAUDE.md merge + idempotency behavior already implemented stays.

**Stale copy-in detection (mechanism).** Each command/script file `install.sh` writes gets a sentinel comment line as its **last** line: `# ganpan-orchestration: vX.Y.Z` (the version read from `plugins/orchestration/.claude-plugin/plugin.json`). On a later run, `install.sh` greps each destination file for `# ganpan-orchestration:`; if the embedded version differs from the toolkit's current version, it overwrites that file (re-copy + path rewrite + re-stamp). Files without the sentinel are treated as user-owned and left untouched with a warning — except an explicit `install.sh --force` overwrites and stamps regardless (needed for the first migration off a sentinel-less v1 copy; see §8). This gives a deterministic upgrade for copy-in installs without a package manager. (The `.sh` engine files are copied verbatim, so the sentinel is a trailing shell comment; command `.md` files take it as a trailing HTML/Markdown comment.)

**`CLAUDE.md` is excluded from sentinel stamping.** Its conventions are *merged* (append-once under the `<!-- orchestration-conventions -->` guard), not overwritten, so a trailing version line plus an append-only guard would either duplicate the block on a version bump or leave the re-copy undefined. `CLAUDE.md` therefore gets the merge guard only (no `# ganpan-orchestration:` line) and is never force-overwritten; updating its conventions text is a manual merge, not a file replace. See §8 migration.

### 3.6 Plugin manifests

`.claude-plugin/marketplace.json` (repo root) declares one plugin sourced from `./plugins/orchestration`. `plugins/orchestration/.claude-plugin/plugin.json` carries name/version/description/author and relies on default discovery of `commands/`. **The exact manifest field names will be validated against current Claude Code plugin documentation during implementation** (schema may have changed); the design fixes the structure, not the precise keys.

### 3.7 `docs/SETUP.md` changes (concrete)

The current `docs/SETUP.md` is entirely v1 (repo-root layout, manual steps). The implementation must make these specific edits, not merely "update it":

- Add a **Plugin install** section at the top: `/plugin marketplace add Laeyoung/Ganpan` → install `orchestration` → run `/orch-setup owner/repo` (which now performs prereq check, config write, asset install, label bootstrap).
- Replace the current manual step 3 ("Edit `.claude/orchestration.json`") with "config is written by `/orch-setup` (or `install.sh`)".
- Replace step 4 ("Bootstrap labels: `scripts/orchestration/bootstrap-labels.sh …`") with "labels are bootstrapped by `/orch-setup`; for the copy-in path run `scripts/orchestration/bootstrap-labels.sh .github/labels.yml`".
- Keep the **copy-in** path (`install.sh`) documented as the alternative below the plugin section.
- The PAT / collaborator / branch-protection / worktree-dependency steps stay (still human actions).

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
- **`install.sh` e2e:** re-run the temp-repo dry run (copy + CLAUDE.md merge + idempotency + the `${CLAUDE_PLUGIN_ROOT}/`→`./` rewrite). **Assert path-drift is zero:** `grep -r CLAUDE_PLUGIN_ROOT <target>/.claude/commands <target>/scripts/orchestration` must find **no** matches after install (covering both the copied command `.md` files and the copied engine `.sh` files, in case a script ever gains an inter-script `${CLAUDE_PLUGIN_ROOT}` reference); the test fails otherwise. This guards against drift between the plugin and copy-in variants.
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
3. **Atomic move.** The script relocation and every path repoint (tests' `SCRIPT=`/`LIB=` prefixes, `lib.sh`/`detect-test-cmd.sh` config defaults, lane-command invocations, `install.sh` source paths) land in a **single commit** — there is no intermediate commit where scripts have moved but references have not, so `bats tests/orchestration/` is green on every commit. "Lockstep" is enforced by atomicity, not convention. (If CI exists, it runs `bats` per push as a backstop.) **Rollback:** if the atomic commit nonetheless reaches `main` and `bats` fails post-merge, the named recovery is `git revert <sha>` and re-open the PR — never a partial hand-patch on `main`.
4. **Existing v1 users (copy-in).** Anyone who installed v1 by committing the repo-root files into their own repo is unaffected by this restructure of *ganpan* — their files are a static copy. They only need action if they want the plugin: install it and run `/orch-setup`, then optionally delete the old committed `scripts/orchestration/` + `.claude/commands/`. **Caveat on copy-in upgrade:** v1 files predate the §3.5 stale-sentinel, so they carry no `# ganpan-orchestration:` line and a plain `install.sh` re-run treats them as user-owned and skips them. The first migration off a sentinel-less v1 therefore requires an explicit `install.sh --force` (overwrite + stamp regardless of sentinel) or manual deletion of the old files first; subsequent upgrades are automatic via the sentinel. This migration note ships in `docs/SETUP.md`.
5. A follow-up PR delivers the plugin; a human reviews and merges (repo merge-gate convention). This branch's own PR is merged by a human, consistent with the gate — agents do not self-merge.
6. **Plugin upgrade path.** `plugin.json` carries a semver `version`. When ganpan (the marketplace) ships changes, installed users update via Claude Code's plugin update flow (`/plugin` → update `orchestration`, which re-pulls the marketplace source). The spec does not invent a bespoke updater; it relies on the platform's plugin update mechanism and bumps `version` on each shipped change. Because the engine scripts live in the plugin, an update refreshes them automatically — no per-target-repo re-copy needed (that burden exists only for the copy-in path, handled by re-running `install.sh`, §3.5 stale-sentinel detection).
