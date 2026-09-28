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

- `ganpan-setup/SKILL.md` gains a first step: if `scripts/orchestration/lib.sh` is
  missing in the repo root, run `npx -y github:Laeyoung/Ganpan init` (default target
  `codex`, i.e. `.agents/skills` + `AGENTS.md` payload) and then continue setup.
- Each lane skill (`ganpan-triage`, `ganpan-work-issue`, `ganpan-review-queue`,
  `ganpan-qa-check`) gains one line: if `scripts/orchestration/lib.sh` is missing, stop
  and run the `ganpan-setup` skill first. (`ganpan-update` is advisory and keeps its own
  wording.)

These edits are to `SKILL.md` only; the shared `references/lanes/*.md` copies are
untouched, so the existing `cmp` sync test stays green.

### 3.3 `bin/ganpan.mjs` — zero-dependency Node ESM CLI

`#!/usr/bin/env node`, executable, only `node:` built-ins. Node ≥ 18.

- `ganpan init [dir] [--target claude|codex|antigravity|both|all] [--force]`
  - `dir` defaults to `.`; `--target` defaults to `codex`.
  - Delegates to the package's `install.sh` via `spawnSync('bash', [install.sh, dir, …],
    { stdio: 'inherit' })` and exits with its status. No re-implementation of copy /
    sentinel / never-clobber logic.
- `ganpan validate [dir]` — offline structural check, no `gh` calls. Checks, each
  printed as `ok` / `FAIL` / `warn` with a reason:
  1. `dir` exists;
  2. config resolves in the engine's order (`$ORCH_CONFIG` → `.ganpan/orchestration.json`
     → `.claude/orchestration.json`), is valid JSON, and `repo` / `bot` are set and not
     the template placeholders `owner/repo` / `bot-login` (`repo` must look like
     `owner/name`);
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

`private: true` — distribution is `npx github:Laeyoung/Ganpan`, not the npm registry.
`version` must equal `plugin.json`'s `version`; a bats test enforces it (the SemVer
bump rule in CLAUDE.md now touches both files).

### 3.5 `scripts/release.sh <X.Y.Z>`

Guards (each fails with a clear message, nothing mutated before all pass):

- argument is a SemVer `X.Y.Z`;
- current branch is `main` and the working tree is clean;
- `plugin.json` and `package.json` versions both equal the argument;
- tag `vX.Y.Z` does not already exist;
- `bin/ganpan.mjs` is executable (`chmod +x` it and fail asking for a commit if not —
  the tracked mode is what users get).

Then `git tag -a vX.Y.Z -m "ganpan vX.Y.Z"` and `git push origin vX.Y.Z`.
`--dry-run` runs all guards and prints the commands without executing them. Version
bumps stay in the feature PR (existing convention); the script never edits versions.

### 3.6 Docs

- README: new "방법 E — Skills CLI (`npx skills`)" subsection with the global/project
  commands, a note that the engine is installed per repo by `ganpan-setup` /
  `npx -y github:Laeyoung/Ganpan init`, and `ganpan validate`. Surface table gets a row.
- CLAUDE.md: Layout gains `bin/ganpan.mjs`, `package.json`, `scripts/release.sh`;
  Versioning notes `package.json` must match.
- `docs/log/2026-09-28-npx-skills-install.md`.

### 3.7 Version

`1.15.1 → 1.16.0` (feat).

## 4. Testing

New `tests/cli.bats`:

- `init` into a temp git repo creates `scripts/orchestration/lib.sh`,
  `.ganpan/orchestration.json`, `.agents/skills/ganpan-setup/SKILL.md`; exit 0.
- `validate` on a fresh `init` fails (placeholder `repo`/`bot`), exit 1; after filling
  them in, passes, exit 0.
- `validate` on a missing dir / dir without engine → exit 1 with the reason.
- engine version drift → `warn`, still exit 0.
- `ORCH_CONFIG` override is honored.
- `--version` equals `plugin.json` version; `package.json` version equals it too.
- `bin/ganpan.mjs` is executable in git (`git ls-files -s` mode `100755`).
- unknown command → exit 2.
- `release.sh`: rejects bad SemVer, version mismatch; `--dry-run` on a matching
  version in a scratch clone prints the tag command.
- discovery guard from §3.1.
- lane skills contain the engine-missing preflight line.

## 5. Out of scope

- The brief's `references/spec.md` and signboard principles (unrelated to this toolkit).
- Publishing to the npm registry.
- A Codex plugin or `ganpan lane ...` runner (already listed as "planned").
