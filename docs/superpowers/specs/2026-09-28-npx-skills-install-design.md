# `npx skills add Laeyoung/Ganpan` install surface — design

- **Date:** 2026-09-28
- **Status:** approved (conversation), pending written-spec review
- **Source request:** external task brief "Agent Skills (`skills.sh`) Specification Integration",
  reinterpreted for the orchestration toolkit (the brief described an unrelated
  "AI-agent signboard `/ganpan/start.md`" spec; the user chose to adapt it to this repo).

## 1. Goal

A user can run

```bash
npx skills add Laeyoung/Ganpan -g     # global (all projects)
npx skills add Laeyoung/Ganpan        # project scope
```

to install the `ganpan-*` agent skills into Claude Code / Codex / Cursor / etc., and the
installed skills can bootstrap the per-repo engine they depend on with one command.

## 2. Findings that shape the design

1. **Discovery already works.** The `skills` CLI (vercel-labs/skills) walks standard
   containers (root `SKILL.md`, `skills/`, `.agents/skills/`, `.claude/skills/`, plugin
   manifest `skills` entries); when none match it falls back to a **recursive search**.
   `npx skills add . --list` on this repo lists all 6 skills from
   `plugins/ganpan-codex/skills/`. A `-g --copy` install copies the whole skill dir
   (`SKILL.md`, `references/`, `agents/`) into `~/.claude/skills/<name>/`.
2. **A root `SKILL.md` would break it.** A shallower `SKILL.md` shadows everything nested,
   so the brief's root `SKILL.md` would hide the 6 real skills. Not added.
3. **Adding `skills` to `.claude-plugin/marketplace.json` is wrong here.** That manifest
   is also the Claude Code plugin marketplace; declaring the Codex skills on the `ganpan`
   plugin entry would register them as Claude plugin skills and duplicate the lanes.
4. **The real gap is the engine.** Every lane skill does
   `source scripts/orchestration/lib.sh` in the target repo. `npx skills` only copies the
   skill directory, so on a repo without the engine the skills fail immediately.

## 3. Design

### 3.1 Discovery: rely on the recursive fallback, guard it with a test

No new `skills/` directory or symlinks (symlinks break on Windows clones; the fallback
already finds the skills). A bats guard asserts the preconditions of the fallback:

- no `SKILL.md` at the repo root;
- none of `skills/`, `.agents/skills/`, `.claude/skills/` exist at the repo root;
- the only `SKILL.md` files in the tree (excluding `.git`, `node_modules`) are exactly
  the 6 under `plugins/ganpan-codex/skills/ganpan-*/`.

If someone later adds one of those, the guard fails with a message explaining the
shadowing.

### 3.2 Engine bootstrap from the skills

The bootstrap command is **pinned to a release tag**, never the mutable `main` ref:
`npx -y github:Laeyoung/Ganpan#v<VERSION> init`, where `<VERSION>` is the literal
current `plugin.json` version written into `ganpan-setup/SKILL.md` (a test keeps them
equal, so every version bump updates it). Pinning makes the bootstrap reproducible and
means a broken `main` does not execute on fresh repos.

- `ganpan-setup/SKILL.md` gains a first step, run from the repo root:
  - `scripts/orchestration/lib.sh` **missing** → run the pinned `init` (default target
    `codex`, i.e. `.agents/skills` + `AGENTS.md` payload), then continue setup;
  - present but its `ganpan-orchestration: vX.Y.Z` sentinel differs from `<VERSION>` →
    the agent **never runs `--force` itself** (it overwrites sentinel-stamped engine
    files and a skill has no real confirmation gate, esp. when unattended); it reports
    the drift, prints the exact pinned `init --force` command for a human to run, and
    continues setup against the installed engine;
  - equal → skip.
- Each lane skill (`ganpan-triage`, `ganpan-work-issue`, `ganpan-review-queue`,
  `ganpan-qa-check`) gains one preflight line: if `scripts/orchestration/lib.sh` is
  missing, **hard-stop** (same pattern as the bot-identity check) with a message telling
  the user to run the `ganpan-setup` skill — a lane never bootstraps the engine itself. Lanes do **not** check staleness
  themselves — that is already `ganpan-update`'s job (advisory version check), and
  `ganpan-setup` / `ganpan validate` both report drift. `ganpan-update` keeps its
  own wording.

These edits are to `SKILL.md` only; the shared `references/lanes/*.md` copies are
untouched, so the existing `cmp` sync test stays green.

**Release ordering:** the pinned tag only exists after `scripts/release.sh` runs (§3.5),
so the release step must follow each version-bump merge promptly; until it does, the
bootstrap line of the new version fails with a clear "tag not found" from npm while the
previous tag keeps working for already-installed skills.

### 3.3 `bin/ganpan.mjs` — zero-dependency Node ESM CLI

`#!/usr/bin/env node`, executable, only `node:` built-ins. Node ≥ 18.

- `ganpan init [dir] [--target claude|codex|antigravity|both|all] [--force]`
  - `dir` defaults to `.` and is resolved to an absolute path against the process cwd;
    `--target` defaults to `codex` and is **always passed explicitly** to `install.sh`
    (whose own default is `claude`).
  - Preflight, each failing with an actionable message and exit `1` before spawning:
    `bash` and `jq` are on PATH (Windows users are told to use Git Bash or WSL — native
    Windows without bash is unsupported, as for `install.sh` today); `dir` is not itself
    a ganpan checkout (contains `plugins/orchestration/.claude-plugin/plugin.json`) —
    `install.sh`'s own `TARGET == SRC` guard cannot catch this because under `npx`
    `SRC` is the npx cache, not the user's clone.
  - Then delegates to the package's `install.sh` via `spawnSync('bash', [install.sh,
    absDir, '--target', t, …], { stdio: 'inherit' })` and exits with its status. No
    re-implementation of copy / sentinel / never-clobber logic.
- `ganpan validate [dir]` — offline structural check, no `gh` calls. `dir` defaults to
  `.`; all paths below are resolved against `dir`, **including a relative `$ORCH_CONFIG`**
  (the engine resolves it against cwd because lanes always run from the repo root;
  `validate` pins that root to `dir`). Checks, each printed as `ok` / `FAIL` / `warn`
  with a reason:
  1. `dir` exists;
  2. config resolves in the engine's order (`$ORCH_CONFIG` → `.ganpan/orchestration.json`
     → `.claude/orchestration.json`), exists, is valid JSON, and `repo` / `bot` are
     non-empty strings that are not the template placeholders `owner/repo` /
     `bot-login` (`repo` must match `owner/name`);
  3. `scripts/orchestration/lib.sh` exists;
  4. installed engine version (sentinel `ganpan-orchestration: vX.Y.Z` in `lib.sh`)
     equals the CLI's own version → otherwise `warn` (drift, not failure; suggests
     `ganpan init --force`);
  5. `.github/labels.yml` exists.
  Exit `0` if no `FAIL`, else `1`.
- `ganpan --version` / `-v`, `ganpan help` / `-h` / no args → usage. Unknown command →
  usage on stderr, exit `2`.
- The CLI's version is read from `plugins/orchestration/.claude-plugin/plugin.json`
  (the single source of truth), not duplicated.

### 3.4 `package.json`

```json
{
  "name": "ganpan",
  "version": "<= plugin.json version>",
  "private": true,
  "type": "module",
  "bin": { "ganpan": "./bin/ganpan.mjs" },
  "files": ["bin", "install.sh", "plugins", "docs/SETUP.md"],
  "engines": { "node": ">=18" },
  "scripts": { "test": "bats tests/*.bats tests/orchestration/*.bats" }
}
```

`private: true` — distribution is `npx github:Laeyoung/Ganpan#vX.Y.Z`, not the npm
registry. `files` covers everything `install.sh` reads (all under `plugins/` plus
`docs/SETUP.md`); whether a git-spec `npx` install applies the `files` filter is
verified empirically during implementation (§4 smoke checks) rather than assumed.
`version` must equal `plugin.json`'s `version`; a bats test enforces it (the SemVer
bump rule in CLAUDE.md now touches both files).

### 3.5 `scripts/release.sh [--dry-run] [--remote <name>] <X.Y.Z>`

Tags are **additive** to the existing release model: the merge to `main` is still what
ships to plugin users; the tag only gives the `npx` bootstrap (§3.2) an immutable ref.

Guards (read-only; each fails with a clear message and exit `1`, nothing is mutated
before all pass):

- argument is a SemVer `X.Y.Z`;
- current branch is `main`, the working tree is clean, and `HEAD` equals
  `<remote>/main` after a `git fetch <remote>` (the tag must point at shipped code);
- `plugin.json`, `package.json`, and the pinned version in `ganpan-setup/SKILL.md` all
  equal the argument;
- `git remote get-url <remote>` points at the canonical repo (matches
  `github.com[:/]Laeyoung/Ganpan(\.git)?$`, case-insensitive) — a fork `origin` would
  otherwise "succeed" while the pinned bootstrap still resolves against
  `Laeyoung/Ganpan`. Tests override the expected pattern with the per-invocation env
  `GANPAN_RELEASE_REMOTE_RE` (never exported globally);
- tag `vX.Y.Z` exists neither locally nor on `<remote>`;
- `bin/ganpan.mjs` is tracked with mode `100755` (`git ls-files -s`) — checked only,
  never `chmod`ed.

`<remote>` defaults to `origin`. Then `git tag -a vX.Y.Z -m "ganpan vX.Y.Z"` and
`git push <remote> vX.Y.Z`; if the push fails the script prints the recovery command
(`git tag -d vX.Y.Z`) and exits `1`. `--dry-run` runs all guards and prints the two
commands without executing them. The script never edits versions — bumps stay in the
feature PR (existing convention).

### 3.6 Docs & CI

- README: new "방법 E — Skills CLI (`npx skills`)" subsection with the global/project
  commands, a note that the engine is installed per repo by `ganpan-setup` /
  `npx -y github:Laeyoung/Ganpan#vX.Y.Z init` (bash + jq required; Windows via Git Bash
  or WSL), and `ganpan validate`. Surface table gets a row.
- `docs/RELEASE_PLAYBOOK.md` and `docs/RELEASE_CHECKLIST.md`: replace the "no git tags"
  statements with "merge to `main` ships; then tag with `scripts/release.sh` so the
  pinned `npx` bootstrap resolves"; add the tag step after merge; Rollback notes a
  rollback ships a *new* version + tag (tags are never moved or deleted); surfaces table
  gains the Skills CLI row; shellcheck command includes `scripts/release.sh`.
- CLAUDE.md: Layout gains `bin/ganpan.mjs`, `package.json`, `scripts/release.sh`;
  Versioning notes `package.json` and the `ganpan-setup` pin must match `plugin.json`;
  the shellcheck command includes `scripts/release.sh`.
- `.github/workflows/ci.yml`: the shellcheck step includes `scripts/release.sh` and the
  manifest step validates `package.json`.
- `docs/log/2026-09-28-npx-skills-install.md`.

### 3.7 Version

`1.15.1 → 1.16.0` (feat).

## 4. Testing

New `tests/cli.bats` (offline, deterministic):

- `init` into a temp git repo creates `scripts/orchestration/lib.sh`,
  `.ganpan/orchestration.json`, `.agents/skills/ganpan-setup/SKILL.md`; exit 0.
- `init` with a relative `dir` from a different cwd installs into that dir.
- `init` targeting a ganpan checkout (a temp dir containing
  `plugins/orchestration/.claude-plugin/plugin.json`) → exit 1, nothing written.
- `init` with `jq` hidden from PATH → exit 1 with the "jq required" message.
- `validate` on a fresh `init` fails (placeholder `repo`/`bot`), exit 1; after filling
  them in, passes, exit 0; `repo`/`bot` as `null` or a number → FAIL.
- `validate` on a missing dir / dir without engine / without `.github/labels.yml` →
  exit 1 with a FAIL line naming what is missing.
- engine version drift → `warn`, still exit 0.
- `ORCH_CONFIG` override is honored, both absolute and relative-to-`dir` with a cwd
  different from `dir`.
- `--version` equals `plugin.json` version; `package.json` version and the
  `ganpan-setup/SKILL.md` pin equal it too.
- `bin/ganpan.mjs` is executable in git (`git ls-files -s` mode `100755`; runs after
  the file is committed, like the existing manifest checks).
- unknown command → exit 2.
- `release.sh`, each in a scratch clone whose `origin` is a local bare repo
  (`file://…`), never the real remote:
  - rejects bad SemVer, version mismatch, dirty tree, non-`main` branch, existing tag,
    non-`100755` mode, and a local `main` commit not yet pushed to the bare remote
    (HEAD ≠ `<remote>/main`), and a remote URL not matching the canonical pattern
    (default pattern, no override) — each with no tag created locally or remotely;
  - `--dry-run` on a matching version prints the tag + push commands and creates no tag;
  - the real path creates `vX.Y.Z` locally and on the bare remote.
- discovery guard from §3.1.
- `ganpan-setup/SKILL.md` contains the pinned `npx -y github:Laeyoung/Ganpan#v<VERSION>
  init` step; the 4 lane skills contain the engine-missing preflight line.

Manual smoke checks during implementation (network, not in the suite):
`npx skills add . --list` still lists the 6 skills; `npm pack --dry-run` includes
`install.sh`, `plugins/**`, `docs/SETUP.md`; `npx -y github:Laeyoung/Ganpan#<branch>
init <scratch-repo>` after pushing the branch installs successfully.

## 5. Out of scope

- The brief's `references/spec.md` and signboard principles (unrelated to this toolkit).
- Publishing to the npm registry.
- A Codex plugin or `ganpan lane ...` runner (already listed as "planned").
