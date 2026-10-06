# `npx skills` Install Surface Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `npx skills add Laeyoung/Ganpan [-g]` installs the six `ganpan-*` skills, and those skills can bootstrap the per-repo engine through a pinned, zero-dependency `ganpan` CLI (`init` / `validate`), with `scripts/release.sh` producing the tag the pin resolves to.

**Architecture:** Discovery keeps relying on the `skills` CLI's recursive fallback over `plugins/ganpan-codex/skills/`, protected by a git-tracked-files guard test. A new `bin/ganpan.mjs` (Node ESM, `node:` built-ins only) delegates `init` to the existing, tested `install.sh` and implements `validate` as an offline structural check. `scripts/release.sh` is a read-only-guarded tagger; tags are additive to the existing "merge to `main` ships" release model.

**Tech Stack:** Node ≥ 18 (ESM, `node:fs`/`node:path`/`node:child_process`/`node:url`), bash, jq, git, bats (tests), shellcheck (lint).

**Spec:** `docs/superpowers/specs/2026-09-28-npx-skills-install-design.md`

## Global Constraints

- Node ≥ 18; `bin/ganpan.mjs` imports only `node:` built-ins — no npm dependencies, no `node_modules`.
- `bin/ganpan.mjs` starts with `#!/usr/bin/env node` and is tracked as mode `100755`.
- Version is `1.16.0` in **three** places that must stay equal: `plugins/orchestration/.claude-plugin/plugin.json`, `package.json`, and every `github:Laeyoung/Ganpan#v<VERSION>` pin in `plugins/ganpan-codex/skills/ganpan-setup/SKILL.md`.
- The CLI reads its version from `plugin.json` at runtime — never hard-code it in `ganpan.mjs`.
- `ganpan init` default `--target` is `codex` and is always passed explicitly to `install.sh` (whose own default is `claude`).
- Never rename engine internals (`scripts/orchestration/`, `orchestration.json`, the `ganpan-orchestration` sentinel).
- No root `SKILL.md`, and no tracked `skills/`, `.agents/skills/`, `.claude/skills/` at the repo root — they would shadow discovery.
- Skills never run `init --force` themselves; lane skills hard-stop (never bootstrap) when `scripts/orchestration/lib.sh` is missing.
- `release.sh` guards are read-only; nothing is created before all pass; it never edits versions.
- Every shell script passes `shellcheck` (v0.11.0 in CI).
- Commits: Conventional Commits `type(scope): subject`, body explains what+why, ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. There is no GitHub issue for this work, so omit the `Refs #<n>` footer (never use `Closes #`).

## Review Focus

1. **`init` into a path containing spaces** (`"my repo"`) — must install correctly; argv is passed as an array, never a shell string. Test in Task 3.
2. **`init` into a directory that doesn't exist** — must exit 1 with `target is not a directory`, not a Node stack trace. Test in Task 3.
3. **`init --target` with a bad or missing value** (`--target nope`, trailing `--target`) — usage error, exit 2, `install.sh` never spawned. Test in Task 3.
4. **Config that is valid JSON but not an object** (`null`, `[]`) — `validate` must print a FAIL line, not throw `TypeError`. Test in Task 2.
5. **`$ORCH_CONFIG` pointing at a nonexistent file** — FAIL that names `$ORCH_CONFIG`, and no silent fallback to `.ganpan/…`, because the engine doesn't fall back either. Test in Task 2.

---

## File map

| File | Status | Responsibility |
|---|---|---|
| `package.json` | create | npm metadata: `bin`, `files`, `engines`, `test` script |
| `bin/ganpan.mjs` | create | CLI entry: dispatch, `--version`/`help`, `init`, `validate` |
| `tests/cli.bats` | create | CLI + version-sync + executable-bit tests |
| `scripts/release.sh` | create | guarded `vX.Y.Z` tag + push |
| `tests/release.bats` | create | release.sh guard/dry-run/push tests against a local bare remote |
| `.gitignore` | modify | un-ignore `scripts/release.sh` (today `/scripts/` ignores it) |
| `plugins/orchestration/.claude-plugin/plugin.json` | modify | `1.15.1` → `1.16.0` |
| `plugins/ganpan-codex/skills/ganpan-setup/SKILL.md` | modify | pinned engine bootstrap step + validate step |
| `plugins/ganpan-codex/skills/ganpan-{triage,work-issue,review-queue,qa-check}/SKILL.md` | modify | engine-missing hard-stop preflight |
| `tests/codex-skills.bats` | modify | discovery guard, pin, preflight tests |
| `.github/workflows/ci.yml` | modify | node setup, shellcheck `scripts/release.sh`, validate `package.json` |
| `README.md`, `CLAUDE.md`, `docs/RELEASE_PLAYBOOK.md`, `docs/RELEASE_CHECKLIST.md` | modify | docs |
| `docs/log/2026-09-29-npx-skills-install.md` | create | change record |

---

### Task 1: Package manifest, CLI skeleton, version bump

**Files:**
- Create: `package.json`, `bin/ganpan.mjs`, `tests/cli.bats`
- Modify: `plugins/orchestration/.claude-plugin/plugin.json` (version)

**Interfaces:**
- Produces: `bin/ganpan.mjs` module-level helpers used by Tasks 2–3:
  - `PKG_ROOT: string` (absolute package root), `PLUGIN_JSON: string`, `INSTALL_SH: string`
  - `version(): string` (reads `plugin.json`)
  - `class UsageError extends Error` (thrown → exit 2)
  - `fail(msg: string): 1` (writes `ganpan: <msg>` to stderr, returns 1)
  - `main(argv: string[]): number` with a `switch (cmd)` that Tasks 2–3 extend with `case 'validate'` / `case 'init'`.
- Produces: `tests/cli.bats` with `setup()` defining `REPO_ROOT`, `CLI`.

- [ ] **Step 1: Write the failing tests**

Create `tests/cli.bats`:

```bash
#!/usr/bin/env bats
# tests/cli.bats — bin/ganpan.mjs (npx `ganpan` CLI) + version-sync guards.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CLI="$REPO_ROOT/bin/ganpan.mjs"
  PLUGIN_VERSION="$(jq -r .version "$REPO_ROOT/plugins/orchestration/.claude-plugin/plugin.json")"
}

@test "--version prints the plugin.json version" {
  run node "$CLI" --version
  [ "$status" -eq 0 ]
  [ "$output" = "$PLUGIN_VERSION" ]
  run node "$CLI" -v
  [ "$output" = "$PLUGIN_VERSION" ]
}

@test "package.json version equals plugin.json version" {
  run jq -r .version "$REPO_ROOT/package.json"
  [ "$status" -eq 0 ]
  [ "$output" = "$PLUGIN_VERSION" ]
}

@test "package.json declares the ganpan bin, ESM, node>=18, and the install payload" {
  pkg="$REPO_ROOT/package.json"
  [ "$(jq -r .type "$pkg")" = "module" ]
  [ "$(jq -r .private "$pkg")" = "true" ]
  [ "$(jq -r '.bin.ganpan' "$pkg")" = "./bin/ganpan.mjs" ]
  [ "$(jq -r '.engines.node' "$pkg")" = ">=18" ]
  [ "$(jq -c '.files' "$pkg")" = '["bin","install.sh","plugins","docs/SETUP.md"]' ]
}

@test "help / no args print usage and exit 0" {
  for arg in "" help -h --help; do
    if [ -z "$arg" ]; then run node "$CLI"; else run node "$CLI" "$arg"; fi
    [ "$status" -eq 0 ]
    [[ "$output" == *"ganpan init [dir]"* ]]
    [[ "$output" == *"ganpan validate [dir]"* ]]
  done
}

@test "unknown command prints usage and exits 2" {
  run node "$CLI" frobnicate
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown command: frobnicate"* ]]
  [[ "$output" == *"usage:"* ]]
}

@test "bin/ganpan.mjs has a node shebang and is tracked executable (100755)" {
  run head -n1 "$CLI"
  [ "$output" = "#!/usr/bin/env node" ]
  run git -C "$REPO_ROOT" ls-files -s bin/ganpan.mjs
  [ "$status" -eq 0 ]
  [[ "$output" == 100755* ]]
}

@test "ganpan.mjs imports only node: built-ins" {
  # every import specifier must carry the literal node: prefix ('node-fetch' etc. must fail)
  run grep -cE "^import " "$CLI"
  [ "$output" -gt 0 ]
  run bash -c "grep -E \"^import \" '$CLI' | grep -v \"from 'node:\""
  [ -z "$output" ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/cli.bats`
Expected: every test FAILs (`bin/ganpan.mjs` / `package.json` don't exist; the version is still 1.15.1 with no package.json).

- [ ] **Step 3: Bump the version and create `package.json`**

In `plugins/orchestration/.claude-plugin/plugin.json` change `"version": "1.15.1"` to `"version": "1.16.0"`.

Create `package.json`:

```json
{
  "name": "ganpan",
  "version": "1.16.0",
  "description": "GitHub-native agent orchestration toolkit — engine installer and validator for the ganpan-* agent skills.",
  "private": true,
  "type": "module",
  "bin": { "ganpan": "./bin/ganpan.mjs" },
  "files": ["bin", "install.sh", "plugins", "docs/SETUP.md"],
  "engines": { "node": ">=18" },
  "scripts": { "test": "bats tests/*.bats tests/orchestration/*.bats" },
  "repository": { "type": "git", "url": "git+https://github.com/Laeyoung/Ganpan.git" },
  "license": "UNLICENSED"
}
```

(Check the repo root for a `LICENSE` file first: `ls LICENSE* 2>/dev/null`. If one exists, set `"license"` to its SPDX id, e.g. `"MIT"`.)

- [ ] **Step 4: Create the CLI skeleton**

Create `bin/ganpan.mjs`:

```js
#!/usr/bin/env node
// ganpan — zero-dependency helper CLI for the Ganpan orchestration toolkit.
//
//   ganpan init [dir] [--target claude|codex|antigravity|both|all] [--force]
//   ganpan validate [dir]
//
// `init` delegates to the packaged install.sh (the tested copy/sentinel logic);
// `validate` is an offline structural check (no gh calls). Distributed via
// `npx -y github:Laeyoung/Ganpan#vX.Y.Z <cmd>`; only node: built-ins are used.
import { spawnSync } from 'node:child_process';
import { accessSync, constants, existsSync, readFileSync, statSync } from 'node:fs';
import { delimiter, dirname, isAbsolute, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const PKG_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const PLUGIN_JSON = join(PKG_ROOT, 'plugins/orchestration/.claude-plugin/plugin.json');
const INSTALL_SH = join(PKG_ROOT, 'install.sh');

const USAGE = `usage:
  ganpan init [dir] [--target claude|codex|antigravity|both|all] [--force]
  ganpan validate [dir]
  ganpan --version | --help`;

class UsageError extends Error {}

// Single source of truth for the version: the Claude plugin manifest.
function version() {
  return JSON.parse(readFileSync(PLUGIN_JSON, 'utf8')).version;
}

function fail(msg) {
  process.stderr.write(`ganpan: ${msg}\n`);
  return 1;
}

function main(argv) {
  const [cmd, ...rest] = argv;
  try {
    switch (cmd) {
      case '-v':
      case '--version':
        console.log(version());
        return 0;
      case undefined:
      case 'help':
      case '-h':
      case '--help':
        console.log(USAGE);
        return 0;
      default:
        throw new UsageError(`unknown command: ${cmd}`);
    }
  } catch (e) {
    if (e instanceof UsageError) {
      process.stderr.write(`ganpan: ${e.message}\n${USAGE}\n`);
      return 2;
    }
    throw e;
  }
}

process.exitCode = main(process.argv.slice(2));
```

Note: `spawnSync`, `accessSync`, `constants`, `existsSync`, `statSync`, `delimiter`, `isAbsolute`, `INSTALL_SH` and `rest` are unused until Tasks 2–3. That's intentional (Node doesn't warn); keep the import line as-is so later tasks only add code.

- [ ] **Step 5: Make it executable and stage it (the mode test reads the index)**

```bash
chmod +x bin/ganpan.mjs
git add package.json bin/ganpan.mjs tests/cli.bats plugins/orchestration/.claude-plugin/plugin.json
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bats tests/cli.bats`
Expected: 7/7 PASS.

Run: `bats tests/*.bats tests/orchestration/*.bats`
Expected: all PASS. If a pre-existing test pinned `1.15.1`, update it to read the version from `plugin.json` instead.

- [ ] **Step 7: Commit**

```bash
git commit -m "feat(cli): add zero-dependency ganpan CLI skeleton and package.json

Introduce bin/ganpan.mjs (node: built-ins only, version read from
plugin.json) and a private package.json so the toolkit can run as
npx -y github:Laeyoung/Ganpan#vX.Y.Z. Bump 1.15.1 -> 1.16.0 (feat) and
guard package.json/plugin.json version equality in tests/cli.bats.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: `ganpan validate`

**Files:**
- Modify: `bin/ganpan.mjs`
- Test: `tests/cli.bats`

**Interfaces:**
- Consumes: `version()`, `UsageError`, `main` switch from Task 1.
- Produces: `cmdValidate(args: string[]): 0|1`, `checkConfig(root: string, report: (level, msg) => void): void`, and the `report` line format `"<level padded to 4> <msg>"`, where the levels are `ok`, `FAIL` and `warn`. Task 3's tests call `validate` after `init`.
- Also produces the test helper `install_fresh()` in `tests/cli.bats`. Task 3 reuses it.

- [ ] **Step 1: Write the failing tests**

Append to `tests/cli.bats`. `install_fresh` builds the fixture with `install.sh` directly, so this task doesn't depend on `init`:

```bash
# install_fresh <dir> — engine + codex payload into <dir> via install.sh (fixture for validate).
install_fresh() {
  mkdir -p "$1/.git"
  bash "$REPO_ROOT/install.sh" "$1" --target codex >/dev/null
}

# fill_config <dir> — replace the template placeholders with real-looking values.
fill_config() {
  local cfg="$1/.ganpan/orchestration.json"
  jq '.repo = "acme/widgets" | .bot = "acme-bot"' "$cfg" > "$cfg.tmp" && mv "$cfg.tmp" "$cfg"
}

@test "validate: fresh install fails on template placeholders" {
  T="$BATS_TEST_TMPDIR/t"; install_fresh "$T"
  run node "$CLI" validate "$T"
  [ "$status" -eq 1 ]
  [[ "$output" == *'FAIL config.repo is still the template placeholder "owner/repo"'* ]]
  [[ "$output" == *'FAIL config.bot is still the template placeholder "bot-login"'* ]]
}

@test "validate: filled-in install passes" {
  T="$BATS_TEST_TMPDIR/t"; install_fresh "$T"; fill_config "$T"
  run node "$CLI" validate "$T"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok   config"*"repo acme/widgets"* ]]
  [[ "$output" == *"ok   engine version v$PLUGIN_VERSION"* ]]
  [[ "$output" == *"ok   labels .github/labels.yml"* ]]
  [[ "$output" != *"FAIL"* ]]
}

@test "validate: defaults to the current directory" {
  T="$BATS_TEST_TMPDIR/t"; install_fresh "$T"; fill_config "$T"
  cd "$T"
  run node "$CLI" validate
  [ "$status" -eq 0 ]
}

@test "validate: repo/bot null or non-string, or repo not owner/name -> FAIL" {
  T="$BATS_TEST_TMPDIR/t"; install_fresh "$T"
  cfg="$T/.ganpan/orchestration.json"
  jq '.repo = null | .bot = 5' "$cfg" > "$cfg.tmp" && mv "$cfg.tmp" "$cfg"
  run node "$CLI" validate "$T"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL config.repo must be a non-empty string"* ]]
  [[ "$output" == *"FAIL config.bot must be a non-empty string"* ]]
  jq '.repo = "just-a-name" | .bot = "b"' "$cfg" > "$cfg.tmp" && mv "$cfg.tmp" "$cfg"
  run node "$CLI" validate "$T"
  [ "$status" -eq 1 ]
  [[ "$output" == *'FAIL config.repo "just-a-name" must look like owner/name'* ]]
}

@test "validate: config that is JSON null or an array -> FAIL, not a crash (Review Focus 4)" {
  T="$BATS_TEST_TMPDIR/t"; install_fresh "$T"
  for body in 'null' '[]'; do
    printf '%s\n' "$body" > "$T/.ganpan/orchestration.json"
    run node "$CLI" validate "$T"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL config must be a JSON object"* ]]
    [[ "$output" != *"TypeError"* ]]
  done
}

@test "validate: invalid JSON -> FAIL" {
  T="$BATS_TEST_TMPDIR/t"; install_fresh "$T"
  printf '{ not json' > "$T/.ganpan/orchestration.json"
  run node "$CLI" validate "$T"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL config is not valid JSON"* ]]
}

@test "validate: missing dir -> exit 1" {
  run node "$CLI" validate "$BATS_TEST_TMPDIR/nope"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL directory not found"* ]]
}

@test "validate: dir without engine or config -> exit 1 naming both" {
  T="$BATS_TEST_TMPDIR/empty"; mkdir -p "$T"
  run node "$CLI" validate "$T"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL config missing"* ]]
  [[ "$output" == *"FAIL engine missing: scripts/orchestration/lib.sh"* ]]
}

@test "validate: missing .github/labels.yml -> FAIL naming it" {
  T="$BATS_TEST_TMPDIR/t"; install_fresh "$T"; fill_config "$T"
  rm "$T/.github/labels.yml"
  run node "$CLI" validate "$T"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL labels missing: .github/labels.yml"* ]]
}

@test "validate: engine version drift is a warn, still exit 0" {
  T="$BATS_TEST_TMPDIR/t"; install_fresh "$T"; fill_config "$T"
  lib="$T/scripts/orchestration/lib.sh"
  sed "s/ganpan-orchestration: v[0-9.]*/ganpan-orchestration: v0.0.1/" "$lib" > "$lib.tmp" && mv "$lib.tmp" "$lib"
  run node "$CLI" validate "$T"
  [ "$status" -eq 0 ]
  [[ "$output" == *"warn engine v0.0.1 differs from ganpan v$PLUGIN_VERSION"* ]]
}

@test "validate: legacy .claude/orchestration.json is used when .ganpan is absent" {
  T="$BATS_TEST_TMPDIR/t"; install_fresh "$T"; fill_config "$T"
  mkdir -p "$T/.claude"; mv "$T/.ganpan/orchestration.json" "$T/.claude/orchestration.json"
  run node "$CLI" validate "$T"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok   config $T/.claude/orchestration.json"* ]]
}

@test "validate: absolute ORCH_CONFIG wins over .ganpan" {
  T="$BATS_TEST_TMPDIR/t"; install_fresh "$T"          # .ganpan config keeps placeholders
  jq '.repo = "acme/alt" | .bot = "alt-bot"' "$T/.ganpan/orchestration.json" > "$BATS_TEST_TMPDIR/alt.json"
  run env ORCH_CONFIG="$BATS_TEST_TMPDIR/alt.json" node "$CLI" validate "$T"
  [ "$status" -eq 0 ]
  [[ "$output" == *"repo acme/alt"* ]]
}

@test "validate: relative ORCH_CONFIG resolves against dir, not cwd" {
  T="$BATS_TEST_TMPDIR/t"; install_fresh "$T"          # .ganpan config keeps placeholders
  mkdir -p "$T/custom"
  jq '.repo = "acme/rel" | .bot = "rel-bot"' "$T/.ganpan/orchestration.json" > "$T/custom/cfg.json"
  cd "$BATS_TEST_TMPDIR"                                # cwd != dir, and has no custom/cfg.json
  run env ORCH_CONFIG=custom/cfg.json node "$CLI" validate t
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok   config $T/custom/cfg.json"* ]]
}

@test "validate: ORCH_CONFIG pointing at a missing file -> FAIL, no fallback (Review Focus 5)" {
  T="$BATS_TEST_TMPDIR/t"; install_fresh "$T"; fill_config "$T"   # a valid .ganpan config exists
  run env ORCH_CONFIG="$BATS_TEST_TMPDIR/missing.json" node "$CLI" validate "$T"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL config not found: $BATS_TEST_TMPDIR/missing.json (from \$ORCH_CONFIG)"* ]]
}

@test "validate: rejects extra args and flags with exit 2" {
  run node "$CLI" validate a b
  [ "$status" -eq 2 ]
  run node "$CLI" validate --strict
  [ "$status" -eq 2 ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/cli.bats`
Expected: the new `validate:` tests FAIL (`unknown command: validate`, exit 2); Task 1 tests still pass.

- [ ] **Step 3: Implement `validate`**

In `bin/ganpan.mjs`, add below `fail()`:

```js
// Template placeholders shipped in plugins/orchestration/assets/orchestration.json.
const PLACEHOLDERS = { repo: 'owner/repo', bot: 'bot-login' };

// checkConfig — mirror lib.sh resolve_config_path order ($ORCH_CONFIG → .ganpan → .claude),
// but pin the root to `root`: a relative $ORCH_CONFIG is resolved against the target
// repo, because lanes always run from the repo root. No fallback when $ORCH_CONFIG is
// set but missing — the engine doesn't fall back either.
function checkConfig(root, report) {
  const fromEnv = process.env.ORCH_CONFIG;
  let rel;
  if (fromEnv) rel = fromEnv;
  else if (existsSync(join(root, '.ganpan/orchestration.json'))) rel = '.ganpan/orchestration.json';
  else if (existsSync(join(root, '.claude/orchestration.json'))) rel = '.claude/orchestration.json';
  else return report('FAIL', 'config missing: .ganpan/orchestration.json (or legacy .claude/orchestration.json) — run `ganpan init`');

  const path = isAbsolute(rel) ? rel : join(root, rel);
  if (!existsSync(path)) return report('FAIL', `config not found: ${path}${fromEnv ? ' (from $ORCH_CONFIG)' : ''}`);

  let cfg;
  try {
    cfg = JSON.parse(readFileSync(path, 'utf8'));
  } catch (e) {
    return report('FAIL', `config is not valid JSON: ${path} (${e.message})`);
  }
  if (cfg === null || typeof cfg !== 'object' || Array.isArray(cfg)) {
    return report('FAIL', `config must be a JSON object: ${path}`);
  }

  let ok = true;
  for (const key of ['repo', 'bot']) {
    const v = cfg[key];
    if (typeof v !== 'string' || v.trim() === '') {
      report('FAIL', `config.${key} must be a non-empty string (${path})`);
      ok = false;
    } else if (v === PLACEHOLDERS[key]) {
      report('FAIL', `config.${key} is still the template placeholder "${v}" — set it in ${path}`);
      ok = false;
    }
  }
  if (ok && !/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(cfg.repo)) {
    report('FAIL', `config.repo "${cfg.repo}" must look like owner/name (${path})`);
    ok = false;
  }
  if (ok) report('ok', `config ${path} (repo ${cfg.repo}, bot ${cfg.bot})`);
}

function cmdValidate(args) {
  if (args.length > 1) throw new UsageError(`unexpected arg: ${args[1]}`);
  if (args[0]?.startsWith('-')) throw new UsageError(`unknown flag: ${args[0]}`);
  const root = resolve(args[0] ?? '.');
  let failed = false;
  const report = (level, msg) => {
    if (level === 'FAIL') failed = true;
    console.log(`${level.padEnd(4)} ${msg}`);
  };

  if (!existsSync(root) || !statSync(root).isDirectory()) {
    report('FAIL', `directory not found: ${root}`);
    return 1;
  }
  report('ok', `directory ${root}`);

  checkConfig(root, report);

  const lib = join(root, 'scripts/orchestration/lib.sh');
  if (!existsSync(lib)) {
    report('FAIL', 'engine missing: scripts/orchestration/lib.sh — run `ganpan init`');
  } else {
    const m = readFileSync(lib, 'utf8').match(/ganpan-orchestration: v(\d+\.\d+\.\d+)/);
    const cli = version();
    if (!m) report('warn', 'engine lib.sh has no ganpan-orchestration sentinel — `ganpan init --force` re-stamps it');
    else if (m[1] !== cli) report('warn', `engine v${m[1]} differs from ganpan v${cli} — update with \`ganpan init --force\``);
    else report('ok', `engine version v${m[1]}`);
  }

  if (existsSync(join(root, '.github/labels.yml'))) report('ok', 'labels .github/labels.yml');
  else report('FAIL', 'labels missing: .github/labels.yml — run `ganpan init`');

  return failed ? 1 : 0;
}
```

In `main`'s `switch`, add before `case '-v':`:

```js
      case 'validate':
        return cmdValidate(rest);
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/cli.bats`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add bin/ganpan.mjs tests/cli.bats
git commit -m "feat(cli): add offline ganpan validate

Check config resolution (\$ORCH_CONFIG -> .ganpan -> .claude, relative
ORCH_CONFIG pinned to the target dir), non-placeholder repo/bot,
engine presence and sentinel drift (warn), and labels.yml. Exit 1 on
any FAIL so skills and humans can gate on it; no gh calls.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: `ganpan init`

**Files:**
- Modify: `bin/ganpan.mjs`
- Test: `tests/cli.bats`

**Interfaces:**
- Consumes: `INSTALL_SH`, `fail`, `UsageError`, `main` switch (Task 1); `install_fresh` / `fill_config` helpers (Task 2).
- Produces: `cmdInit(args: string[]): number`, `parseInit(args) → { dir: string, target: string, force: boolean }`, and `onPath(cmd: string): boolean`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/cli.bats`:

```bash
@test "init: installs the codex payload by default" {
  T="$BATS_TEST_TMPDIR/t"; mkdir -p "$T/.git"
  run node "$CLI" init "$T"
  [ "$status" -eq 0 ]
  [ -f "$T/scripts/orchestration/lib.sh" ]
  [ -f "$T/.ganpan/orchestration.json" ]
  [ -f "$T/.agents/skills/ganpan-setup/SKILL.md" ]
  [ -f "$T/AGENTS.md" ]
  [ ! -d "$T/.claude/commands" ]          # codex, not claude
}

@test "init: --target claude is forwarded" {
  T="$BATS_TEST_TMPDIR/t"; mkdir -p "$T/.git"
  run node "$CLI" init "$T" --target claude
  [ "$status" -eq 0 ]
  [ -f "$T/.claude/commands/work-issue.md" ]
  [ ! -d "$T/.agents" ]
}

@test "init: then validate fails on placeholders until filled" {
  T="$BATS_TEST_TMPDIR/t"; mkdir -p "$T/.git"
  node "$CLI" init "$T" >/dev/null
  run node "$CLI" validate "$T"
  [ "$status" -eq 1 ]
  fill_config "$T"
  run node "$CLI" validate "$T"
  [ "$status" -eq 0 ]
}

@test "init: relative dir from another cwd installs into that dir" {
  mkdir -p "$BATS_TEST_TMPDIR/work/t/.git"
  cd "$BATS_TEST_TMPDIR/work"
  run node "$CLI" init t
  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/work/t/scripts/orchestration/lib.sh" ]
  [ ! -d "$BATS_TEST_TMPDIR/work/scripts" ]
}

@test "init: dir with spaces works (Review Focus 1)" {
  T="$BATS_TEST_TMPDIR/my repo"; mkdir -p "$T/.git"
  run node "$CLI" init "$T"
  [ "$status" -eq 0 ]
  [ -f "$T/scripts/orchestration/lib.sh" ]
}

@test "init: nonexistent dir -> exit 1, no stack trace (Review Focus 2)" {
  run node "$CLI" init "$BATS_TEST_TMPDIR/nope"
  [ "$status" -eq 1 ]
  [[ "$output" == *"target is not a directory"* ]]
  [[ "$output" != *"    at "* ]]
}

@test "init: refuses a ganpan checkout, writes nothing" {
  T="$BATS_TEST_TMPDIR/ganpan-clone"
  mkdir -p "$T/.git" "$T/plugins/orchestration/.claude-plugin"
  echo '{"version":"0.0.0"}' > "$T/plugins/orchestration/.claude-plugin/plugin.json"
  run node "$CLI" init "$T"
  [ "$status" -eq 1 ]
  [[ "$output" == *"is a ganpan checkout"* ]]
  [ ! -d "$T/scripts" ]
  [ ! -d "$T/.ganpan" ]
}

@test "init: jq missing from PATH -> actionable error, nothing written" {
  T="$BATS_TEST_TMPDIR/t"; mkdir -p "$T/.git"
  FAKEBIN="$BATS_TEST_TMPDIR/fakebin"; mkdir -p "$FAKEBIN"
  ln -s "$(command -v node)" "$FAKEBIN/node"
  ln -s "$(command -v bash)" "$FAKEBIN/bash"
  run env PATH="$FAKEBIN" "$FAKEBIN/node" "$CLI" init "$T"
  [ "$status" -eq 1 ]
  [[ "$output" == *"jq is required but not found on PATH"* ]]
  [ ! -d "$T/scripts" ]
}

@test "init: bash missing from PATH -> actionable error" {
  T="$BATS_TEST_TMPDIR/t"; mkdir -p "$T/.git"
  FAKEBIN="$BATS_TEST_TMPDIR/fakebin"; mkdir -p "$FAKEBIN"
  ln -s "$(command -v node)" "$FAKEBIN/node"
  ln -s "$(command -v jq)" "$FAKEBIN/jq"
  run env PATH="$FAKEBIN" "$FAKEBIN/node" "$CLI" init "$T"
  [ "$status" -eq 1 ]
  [[ "$output" == *"bash is required but not found on PATH"* ]]
}

@test "init: bad or missing --target value -> exit 2, nothing written (Review Focus 3)" {
  T="$BATS_TEST_TMPDIR/t"; mkdir -p "$T/.git"
  run node "$CLI" init "$T" --target nope
  [ "$status" -eq 2 ]
  [[ "$output" == *"--target must be one of: claude, codex, antigravity, both, all"* ]]
  run node "$CLI" init "$T" --target
  [ "$status" -eq 2 ]
  [[ "$output" == *"--target requires a value"* ]]
  run node "$CLI" init "$T" --bogus
  [ "$status" -eq 2 ]
  run node "$CLI" init "$T" extra-arg
  [ "$status" -eq 2 ]
  [ ! -d "$T/scripts" ]
}

@test "init: --force re-stamps drifted engine files" {
  T="$BATS_TEST_TMPDIR/t"; install_fresh "$T"
  lib="$T/scripts/orchestration/lib.sh"
  sed "s/ganpan-orchestration: v[0-9.]*/ganpan-orchestration: v0.0.1/" "$lib" > "$lib.tmp" && mv "$lib.tmp" "$lib"
  run node "$CLI" init "$T" --force
  [ "$status" -eq 0 ]
  run grep -c "ganpan-orchestration: v$PLUGIN_VERSION" "$lib"
  [ "$output" = "1" ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/cli.bats`
Expected: the new `init:` tests FAIL with `unknown command: init` (exit 2). Two of them may already pass by accident, because they only assert exit 2: "bad or missing --target value" and parts of the extra-arg case. That's fine; they must still pass after Step 3.

- [ ] **Step 3: Implement `init`**

In `bin/ganpan.mjs`, add below `cmdValidate`:

```js
const TARGETS = ['claude', 'codex', 'antigravity', 'both', 'all'];

// onPath — is an executable named `cmd` on PATH? (Windows: also try cmd.exe.)
function onPath(cmd) {
  const names = process.platform === 'win32' ? [cmd, `${cmd}.exe`] : [cmd];
  for (const d of (process.env.PATH || '').split(delimiter)) {
    if (!d) continue;
    for (const n of names) {
      try {
        accessSync(join(d, n), constants.X_OK);
        return true;
      } catch {
        // not here — keep looking
      }
    }
  }
  return false;
}

function parseInit(args) {
  const opts = { dir: '.', target: 'codex', force: false };
  let dirSet = false;
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === '--force') opts.force = true;
    else if (a === '--target') {
      if (i + 1 >= args.length) throw new UsageError('--target requires a value');
      opts.target = args[++i];
    } else if (a.startsWith('--target=')) opts.target = a.slice('--target='.length);
    else if (a.startsWith('-')) throw new UsageError(`unknown flag: ${a}`);
    else if (!dirSet) {
      opts.dir = a;
      dirSet = true;
    } else throw new UsageError(`unexpected arg: ${a}`);
  }
  if (!TARGETS.includes(opts.target)) throw new UsageError(`--target must be one of: ${TARGETS.join(', ')}`);
  return opts;
}

function cmdInit(args) {
  const { dir, target, force } = parseInit(args);
  const abs = resolve(dir);

  for (const tool of ['bash', 'jq']) {
    if (!onPath(tool)) {
      const hint = process.platform === 'win32' ? ' — on Windows run ganpan from Git Bash or WSL' : '';
      return fail(`${tool} is required but not found on PATH${hint}`);
    }
  }
  if (!existsSync(abs) || !statSync(abs).isDirectory()) return fail(`target is not a directory: ${abs}`);
  // install.sh's own TARGET == SRC guard can't catch this under npx: SRC is the npx cache.
  if (existsSync(join(abs, 'plugins/orchestration/.claude-plugin/plugin.json'))) {
    return fail(`${abs} is a ganpan checkout — run init in the repository you want to orchestrate`);
  }

  const argv = [INSTALL_SH, abs, '--target', target];
  if (force) argv.push('--force');
  const r = spawnSync('bash', argv, { stdio: 'inherit' });
  if (r.error) return fail(`could not run install.sh: ${r.error.message}`);
  return r.status ?? 1;
}
```

In `main`'s `switch`, add before `case 'validate':`:

```js
      case 'init':
        return cmdInit(rest);
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/cli.bats`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add bin/ganpan.mjs tests/cli.bats
git commit -m "feat(cli): add ganpan init delegating to install.sh

init resolves dir to an absolute path, preflights bash and jq, refuses
a ganpan checkout (install.sh's SRC guard can't see it under npx), and
spawns install.sh with an explicit --target (default codex) instead of
re-implementing the copy/sentinel logic.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Skill bootstrap and preflight, plus the discovery guard

**Files:**
- Modify: `plugins/ganpan-codex/skills/ganpan-setup/SKILL.md`
- Modify: `plugins/ganpan-codex/skills/ganpan-triage/SKILL.md`, `ganpan-work-issue/SKILL.md`, `ganpan-review-queue/SKILL.md`, `ganpan-qa-check/SKILL.md`
- Test: `tests/codex-skills.bats`

**Interfaces:**
- Consumes: the `1.16.0` version from Task 1. The pin must match `plugin.json`.
- Produces: the pin string format `github:Laeyoung/Ganpan#v<X.Y.Z>`, which Task 5's `release.sh` greps for.

- [ ] **Step 1: Write the failing tests**

Append to `tests/codex-skills.bats`:

```bash
@test "npx skills discovery: exactly the 6 ganpan-* SKILL.md files are tracked" {
  # The skills CLI finds our skills via its recursive fallback. A root SKILL.md or a
  # tracked skills/, .agents/skills/, .claude/skills/ at the repo root would shadow it
  # (a shallower SKILL.md hides everything nested). Checked on git-tracked files —
  # that is what `npx skills add Laeyoung/Ganpan` clones.
  run git -C "$REPO_ROOT" ls-files -- ':(glob)**/SKILL.md'
  [ "$status" -eq 0 ]
  expected="plugins/ganpan-codex/skills/ganpan-qa-check/SKILL.md
plugins/ganpan-codex/skills/ganpan-review-queue/SKILL.md
plugins/ganpan-codex/skills/ganpan-setup/SKILL.md
plugins/ganpan-codex/skills/ganpan-triage/SKILL.md
plugins/ganpan-codex/skills/ganpan-update/SKILL.md
plugins/ganpan-codex/skills/ganpan-work-issue/SKILL.md"
  [ "$output" = "$expected" ]
  run git -C "$REPO_ROOT" ls-files -- SKILL.md skills .agents/skills .claude/skills
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "ganpan-setup pins the engine bootstrap to the current plugin version" {
  version="$(jq -r .version "$REPO_ROOT/plugins/orchestration/.claude-plugin/plugin.json")"
  skill="$CODEX_SKILLS/ganpan-setup/SKILL.md"
  run grep -q "npx -y github:Laeyoung/Ganpan#v$version init" "$skill"
  [ "$status" -eq 0 ]
  # every pin in the file is the current version (no stale second pin)
  run bash -c "grep -oE 'github:Laeyoung/Ganpan#v[0-9]+\.[0-9]+\.[0-9]+' '$skill' | sort -u"
  [ "$output" = "github:Laeyoung/Ganpan#v$version" ]
  # never the mutable branch ref
  run grep -E 'github:Laeyoung/Ganpan( |$|#main)' "$skill"
  [ "$status" -ne 0 ]
  # the skill must never run --force itself
  run grep -q 'never run `--force` yourself' "$skill"
  [ "$status" -eq 0 ]
}

@test "lane skills hard-stop when the engine is missing" {
  for lane in triage work-issue review-queue qa-check; do
    run grep -q 'If `scripts/orchestration/lib.sh` is missing, stop' "$CODEX_SKILLS/ganpan-$lane/SKILL.md"
    [ "$status" -eq 0 ]
    run grep -q 'ganpan-setup' "$CODEX_SKILLS/ganpan-$lane/SKILL.md"
    [ "$status" -eq 0 ]
  done
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/codex-skills.bats`
Expected: the discovery test PASSes (it's a guard on today's tree). The pin test and the lane preflight test FAIL.

- [ ] **Step 3: Rewrite `ganpan-setup/SKILL.md`**

Replace the whole file with:

````markdown
---
name: ganpan-setup
description: Set up Ganpan conventions, config, labels, and human security checklist for a target repository.
---

# Ganpan Setup

Use this skill from the target repository root. This skill pins ganpan **v1.16.0**.

1. Read `references/setup.md`.
2. Verify prerequisites: `gh`, `git`, `jq`, and `yq` — plus `node` (≥ 18) and `bash` for the engine installer.
3. Install or check the engine:
   - If `scripts/orchestration/lib.sh` is missing, install it (default `--target codex`: engine scripts, `.agents/skills/ganpan-*`, `AGENTS.md`, `.ganpan/orchestration.json` template, labels, issue template; pass `--target claude|antigravity|both|all` for other surfaces):
     ```bash
     npx -y github:Laeyoung/Ganpan#v1.16.0 init
     ```
   - If it exists but the version stamped on the last line of `lib.sh` is not `v1.16.0`, report the drift and give the user this command to run themselves — never run `--force` yourself; it overwrites sentinel-stamped engine files:
     ```bash
     npx -y github:Laeyoung/Ganpan#v1.16.0 init --force
     ```
     Then continue setup against the installed engine.
4. Prefer `.ganpan/orchestration.json` for new installs. Legacy `.claude/orchestration.json` remains a fallback.
5. Bootstrap labels and issue templates only from repo-owned files.
6. Check the result — each `FAIL` line names what is still missing (e.g. `repo`/`bot` placeholders):
   ```bash
   npx -y github:Laeyoung/Ganpan#v1.16.0 validate
   ```
7. Print human security steps; do not create tokens or change branch protection yourself.

Do not print token values or full environment output.
````

- [ ] **Step 4: Add the preflight to the four lane skills**

In each of `plugins/ganpan-codex/skills/ganpan-{triage,work-issue,review-queue,qa-check}/SKILL.md`, replace the line

```markdown
Use this skill from the target repository root.
```

with

```markdown
Use this skill from the target repository root.

**Preflight:** If `scripts/orchestration/lib.sh` is missing, stop — the Ganpan engine is not installed in this repository. Tell the user to run the `ganpan-setup` skill first; a lane never installs the engine itself.
```

Don't change anything else in these files. `references/*.md` stay untouched, so the existing `cmp` sync test stays green.

Keep the literal `ganpan-orchestration:` token out of SKILL.md prose: `install.sh`'s `needs_write`/`stamp` sentinel logic greps copied files for it.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bats tests/codex-skills.bats tests/antigravity.bats tests/install.bats`
Expected: all PASS. `install.bats` and `antigravity.bats` copy these SKILL.md files, so they confirm the edits didn't break frontmatter or the sentinel.

- [ ] **Step 6: Commit**

```bash
git add plugins/ganpan-codex/skills tests/codex-skills.bats
git commit -m "feat(skills): bootstrap the engine from ganpan-setup via pinned npx

npx skills installs only the skill directory, so the lane skills had no
engine on a fresh repo. ganpan-setup now installs it with
npx -y github:Laeyoung/Ganpan#v1.16.0 init (pinned, reproducible), only
prints --force on drift, and runs validate; lane skills hard-stop when
lib.sh is missing. Guard the skills CLI discovery preconditions on
git-tracked files.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: `scripts/release.sh`

**Files:**
- Create: `scripts/release.sh`, `tests/release.bats`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: the `plugin.json`, `package.json` and `ganpan-setup/SKILL.md` pin (Tasks 1 and 4), and `bin/ganpan.mjs` mode `100755` (Task 1).
- Produces: `scripts/release.sh [--dry-run] [--remote <name>] <X.Y.Z>`, which exits 0 on success, 1 on any guard or push failure, and 2 on a usage error. It honors the per-invocation env var `GANPAN_RELEASE_REMOTE_RE`.

- [ ] **Step 1: Un-ignore the script**

Today `.gitignore` has `/scripts/`, which would make git silently ignore `scripts/release.sh`. Replace that single line

```gitignore
/scripts/
```

with

```gitignore
/scripts/*
!/scripts/release.sh
```

The self-installed `scripts/orchestration/` copies stay ignored.

- [ ] **Step 2: Write the failing tests**

Create `tests/release.bats`:

```bash
#!/usr/bin/env bats
# tests/release.bats — scripts/release.sh guards, dry-run, tag+push, push-failure recovery.
# Every test runs in a scratch repo whose `origin` is a local bare repo — never GitHub.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  RELEASE="$REPO_ROOT/scripts/release.sh"
  BARE="$BATS_TEST_TMPDIR/remote.git"
  WORK="$BATS_TEST_TMPDIR/work"
  make_release_repo 1.2.3
}

# make_release_repo <version> — minimal repo carrying the three version sources, pushed to $BARE.
make_release_repo() {
  local v="$1"
  git init -q --bare "$BARE"
  git -C "$BARE" symbolic-ref HEAD refs/heads/main
  git init -q "$WORK"
  git -C "$WORK" symbolic-ref HEAD refs/heads/main
  git -C "$WORK" config user.email "t@example.com"
  git -C "$WORK" config user.name "t"
  git -C "$WORK" config commit.gpgsign false
  git -C "$WORK" config tag.gpgsign false
  mkdir -p "$WORK/plugins/orchestration/.claude-plugin" "$WORK/plugins/ganpan-codex/skills/ganpan-setup" "$WORK/bin"
  printf '{"version":"%s"}\n' "$v" > "$WORK/plugins/orchestration/.claude-plugin/plugin.json"
  printf '{"version":"%s"}\n' "$v" > "$WORK/package.json"
  printf 'npx -y github:Laeyoung/Ganpan#v%s init\n' "$v" > "$WORK/plugins/ganpan-codex/skills/ganpan-setup/SKILL.md"
  printf '#!/usr/bin/env node\n' > "$WORK/bin/ganpan.mjs"
  chmod +x "$WORK/bin/ganpan.mjs"
  git -C "$WORK" add -A
  git -C "$WORK" commit -q -m init
  git -C "$WORK" remote add origin "file://$BARE"
  git -C "$WORK" push -q origin main
}

# release <args…> — run release.sh inside $WORK, accepting the file:// test remote.
release() { cd "$WORK" && GANPAN_RELEASE_REMOTE_RE='^file://' bash "$RELEASE" "$@"; }
# release_canonical <args…> — same, but with the real (default) canonical-remote pattern.
release_canonical() { cd "$WORK" && env -u GANPAN_RELEASE_REMOTE_RE bash "$RELEASE" "$@"; }

no_tags_anywhere() {
  [ -z "$(git -C "$WORK" tag -l)" ]
  [ -z "$(git ls-remote --tags "$BARE")" ]
}

@test "release.sh is tracked-able (not gitignored) and shellcheck-clean" {
  run git -C "$REPO_ROOT" check-ignore -q scripts/release.sh
  [ "$status" -ne 0 ]
  run shellcheck "$RELEASE"
  [ "$status" -eq 0 ]
}

@test "rejects a non-SemVer version" {
  run release 1.2
  [ "$status" -eq 1 ]
  [[ "$output" == *"version must be X.Y.Z"* ]]
  no_tags_anywhere
}

@test "missing version or unknown flag is a usage error (exit 2)" {
  run release
  [ "$status" -eq 2 ]
  run release --bogus 1.2.3
  [ "$status" -eq 2 ]
}

@test "rejects a version that does not match plugin.json" {
  run release 9.9.9
  [ "$status" -eq 1 ]
  [[ "$output" == *"plugin.json is '1.2.3', expected 9.9.9"* ]]
  no_tags_anywhere
}

@test "rejects when package.json or the ganpan-setup pin disagree" {
  printf '{"version":"1.2.2"}\n' > "$WORK/package.json"
  git -C "$WORK" commit -qam drift && git -C "$WORK" push -q origin main
  run release 1.2.3
  [ "$status" -eq 1 ]
  [[ "$output" == *"package.json is '1.2.2', expected 1.2.3"* ]]
  printf '{"version":"1.2.3"}\n' > "$WORK/package.json"
  printf 'npx -y github:Laeyoung/Ganpan#v1.2.0 init\n' > "$WORK/plugins/ganpan-codex/skills/ganpan-setup/SKILL.md"
  git -C "$WORK" commit -qam drift2 && git -C "$WORK" push -q origin main
  run release 1.2.3
  [ "$status" -eq 1 ]
  [[ "$output" == *"ganpan-setup pin is '1.2.0', expected 1.2.3"* ]]
  no_tags_anywhere
}

@test "rejects a dirty working tree" {
  touch "$WORK/stray"
  run release 1.2.3
  [ "$status" -eq 1 ]
  [[ "$output" == *"working tree is not clean"* ]]
  no_tags_anywhere
}

@test "rejects a non-main branch" {
  git -C "$WORK" checkout -q -b feature
  run release 1.2.3
  [ "$status" -eq 1 ]
  [[ "$output" == *"must be on main (on 'feature')"* ]]
  no_tags_anywhere
}

@test "rejects an unpushed local main commit (HEAD != remote/main)" {
  git -C "$WORK" commit -q --allow-empty -m unpushed
  run release 1.2.3
  [ "$status" -eq 1 ]
  [[ "$output" == *"HEAD is not origin/main"* ]]
  no_tags_anywhere
}

@test "rejects a non-canonical remote with the default pattern" {
  run release_canonical 1.2.3
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not Laeyoung/Ganpan"* ]]
  no_tags_anywhere
}

@test "rejects an unknown --remote" {
  run release --remote nope 1.2.3
  [ "$status" -eq 1 ]
  [[ "$output" == *"no remote named 'nope'"* ]]
}

@test "rejects a tag that already exists locally" {
  git -C "$WORK" tag v1.2.3
  run release 1.2.3
  [ "$status" -eq 1 ]
  [[ "$output" == *"tag v1.2.3 already exists locally"* ]]
  [ -z "$(git ls-remote --tags "$BARE")" ]
}

@test "rejects a tag that already exists on the remote" {
  git -C "$WORK" tag v1.2.3 && git -C "$WORK" push -q origin v1.2.3 && git -C "$WORK" tag -d v1.2.3 >/dev/null
  run release 1.2.3
  [ "$status" -eq 1 ]
  [[ "$output" == *"tag v1.2.3 already exists on origin"* ]]
  [ -z "$(git -C "$WORK" tag -l)" ]
}

@test "rejects bin/ganpan.mjs not tracked as 100755, without chmod-ing it" {
  git -C "$WORK" update-index --chmod=-x bin/ganpan.mjs
  chmod -x "$WORK/bin/ganpan.mjs"
  git -C "$WORK" commit -qm "drop x" && git -C "$WORK" push -q origin main
  run release 1.2.3
  [ "$status" -eq 1 ]
  [[ "$output" == *"bin/ganpan.mjs is tracked as '100644', expected 100755"* ]]
  [ ! -x "$WORK/bin/ganpan.mjs" ]
  no_tags_anywhere
}

@test "--dry-run passes all guards, prints the commands, creates no tag" {
  run release --dry-run 1.2.3
  [ "$status" -eq 0 ]
  [[ "$output" == *'git tag -a v1.2.3 -m "ganpan v1.2.3"'* ]]
  [[ "$output" == *"git push origin v1.2.3"* ]]
  no_tags_anywhere
}

@test "real run creates the annotated tag locally and on the remote" {
  run release 1.2.3
  [ "$status" -eq 0 ]
  [ "$(git -C "$WORK" cat-file -t v1.2.3)" = "tag" ]
  run git ls-remote --tags "$BARE" refs/tags/v1.2.3
  [ -n "$output" ]
}

@test "--remote selects another remote" {
  git -C "$WORK" remote rename origin upstream
  run release --remote upstream 1.2.3
  [ "$status" -eq 0 ]
  run git ls-remote --tags "$BARE" refs/tags/v1.2.3
  [ -n "$output" ]
}

@test "push failure prints the git tag -d recovery command and exits 1" {
  printf '#!/bin/sh\nexit 1\n' > "$BARE/hooks/pre-receive"
  chmod +x "$BARE/hooks/pre-receive"
  run release 1.2.3
  [ "$status" -eq 1 ]
  [[ "$output" == *"git tag -d v1.2.3"* ]]
  [ -z "$(git ls-remote --tags "$BARE")" ]
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `bats tests/release.bats`
Expected: FAIL — `scripts/release.sh` doesn't exist. The first test fails on `shellcheck` of a missing file.

- [ ] **Step 4: Implement `scripts/release.sh`**

Create `scripts/release.sh`:

```bash
#!/usr/bin/env bash
# release.sh — tag a shipped ganpan version so the pinned npx bootstrap resolves.
#
# Usage: scripts/release.sh [--dry-run] [--remote <name>] <X.Y.Z>
#
# The release itself is still the merge to main (docs/RELEASE_PLAYBOOK.md). This adds
# the immutable vX.Y.Z tag that ganpan-setup's `npx -y github:Laeyoung/Ganpan#vX.Y.Z`
# resolves. Every guard is read-only; nothing is created until all pass. It never edits
# versions — bump plugin.json, package.json and the ganpan-setup pin in the feature PR.
#
# GANPAN_RELEASE_REMOTE_RE overrides the canonical-remote pattern (tests only; set it
# per invocation, never export it globally).

set -euo pipefail

die() { printf 'release: %s\n' "$*" >&2; exit 1; }
usage_die() { printf 'release: %s\nusage: scripts/release.sh [--dry-run] [--remote <name>] <X.Y.Z>\n' "$*" >&2; exit 2; }

DRY_RUN=""
REMOTE="origin"
VERSION=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --remote)
      shift
      [ "$#" -gt 0 ] || usage_die "--remote requires a name"
      REMOTE="$1"
      ;;
    --remote=*) REMOTE="${1#--remote=}" ;;
    -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) usage_die "unknown flag: $1" ;;
    *) [ -z "$VERSION" ] || usage_die "unexpected arg: $1"; VERSION="$1" ;;
  esac
  shift
done
[ -n "$VERSION" ] || usage_die "a version is required"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version must be X.Y.Z (got '$VERSION')"
TAG="v$VERSION"
command -v jq >/dev/null 2>&1 || die "jq is required but not found on PATH"

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"
cd "$ROOT"

# --- guards (read-only) -------------------------------------------------------
branch="$(git rev-parse --abbrev-ref HEAD)"
[ "$branch" = "main" ] || die "must be on main (on '$branch')"
[ -z "$(git status --porcelain)" ] || die "working tree is not clean"

url="$(git remote get-url "$REMOTE" 2>/dev/null)" || die "no remote named '$REMOTE'"
remote_re="${GANPAN_RELEASE_REMOTE_RE:-^(https://github\.com/|git@github\.com:|ssh://git@github\.com/)Laeyoung/Ganpan(\.git)?/?$}"
printf '%s\n' "$url" | grep -Eiq "$remote_re" \
  || die "remote '$REMOTE' ($url) is not Laeyoung/Ganpan — the pinned bootstrap resolves there; pass --remote <canonical>"

git fetch --quiet "$REMOTE" main || die "git fetch $REMOTE main failed"
[ "$(git rev-parse HEAD)" = "$(git rev-parse FETCH_HEAD)" ] \
  || die "HEAD is not $REMOTE/main — push or pull first; the tag must point at shipped code"

plugin_v="$(jq -r .version plugins/orchestration/.claude-plugin/plugin.json)" || die "cannot read plugin.json version"
package_v="$(jq -r .version package.json)" || die "cannot read package.json version"
pin_v="$(grep -oE 'github:Laeyoung/Ganpan#v[0-9]+\.[0-9]+\.[0-9]+' plugins/ganpan-codex/skills/ganpan-setup/SKILL.md | head -n1 | sed 's/.*#v//')" || true
[ "$plugin_v" = "$VERSION" ]  || die "plugin.json is '$plugin_v', expected $VERSION"
[ "$package_v" = "$VERSION" ] || die "package.json is '$package_v', expected $VERSION"
[ "$pin_v" = "$VERSION" ]     || die "ganpan-setup pin is '${pin_v:-missing}', expected $VERSION"

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then die "tag $TAG already exists locally"; fi
remote_tag="$(git ls-remote --tags "$REMOTE" "refs/tags/$TAG")" || die "git ls-remote $REMOTE failed"
[ -z "$remote_tag" ] || die "tag $TAG already exists on $REMOTE"

mode="$(git ls-files -s bin/ganpan.mjs | awk '{print $1}')"
[ "$mode" = "100755" ] \
  || die "bin/ganpan.mjs is tracked as '${mode:-untracked}', expected 100755 — run: git update-index --chmod=+x bin/ganpan.mjs, then commit"

# --- act ----------------------------------------------------------------------
if [ -n "$DRY_RUN" ]; then
  printf 'dry-run: all guards passed; would run:\n  git tag -a %s -m "ganpan %s"\n  git push %s %s\n' "$TAG" "$TAG" "$REMOTE" "$TAG"
  exit 0
fi

git tag -a "$TAG" -m "ganpan $TAG"
git push --quiet "$REMOTE" "$TAG" || die "push to $REMOTE failed; the local tag was kept — remove it with: git tag -d $TAG"
printf 'released %s -> %s\n' "$TAG" "$REMOTE"
```

Then:

```bash
chmod +x scripts/release.sh
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bats tests/release.bats && shellcheck scripts/release.sh`
Expected: all PASS, shellcheck exit 0. If shellcheck flags the `sed -n '2,/^$/p' "$0"` help line or anything else, fix the code rather than adding a disable, unless the finding is a false positive (then add a one-line `# shellcheck disable=SCxxxx  # reason`, the way `install.sh` does).

- [ ] **Step 6: Commit**

```bash
git add .gitignore scripts/release.sh tests/release.bats
git commit -m "feat(release): add guarded release.sh tagger

Tags vX.Y.Z so the pinned npx bootstrap resolves. All guards are
read-only: SemVer, main + clean + HEAD == <remote>/main, canonical
Laeyoung/Ganpan remote, plugin.json/package.json/ganpan-setup pin
equal, tag absent locally and remotely, bin/ganpan.mjs tracked 100755.
On push failure it prints the git tag -d recovery. Un-ignore
scripts/release.sh (/scripts/ was ignored for self-install copies).

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Docs, CI, change record

**Files:**
- Modify: `README.md`, `CLAUDE.md`, `docs/RELEASE_PLAYBOOK.md`, `docs/RELEASE_CHECKLIST.md`, `.github/workflows/ci.yml`
- Create: `docs/log/2026-09-29-npx-skills-install.md`

**Interfaces:**
- Consumes: the command names and flags from Tasks 1–5 exactly as defined there.

- [ ] **Step 1: CI — node, shellcheck `release.sh`, validate `package.json`**

In `.github/workflows/ci.yml`, right after `- uses: actions/checkout@v4`, add:

```yaml
      # bin/ganpan.mjs (tests/cli.bats) needs node >= 18; pin it for determinism.
      - uses: actions/setup-node@v4
        with:
          node-version: 20
```

Replace

```yaml
        run: shellcheck plugins/orchestration/scripts/orchestration/*.sh
```

with

```yaml
        run: shellcheck plugins/orchestration/scripts/orchestration/*.sh scripts/release.sh
```

and replace

```yaml
        run: jq . .claude-plugin/marketplace.json plugins/orchestration/.claude-plugin/plugin.json
```

with

```yaml
        run: jq . .claude-plugin/marketplace.json plugins/orchestration/.claude-plugin/plugin.json package.json
```

Also add `node --version` to the "Tool versions" step's `run` block.

- [ ] **Step 2: CLAUDE.md (dev rules)**

In the Development code block, change the shellcheck and jq lines to:

```bash
shellcheck plugins/orchestration/scripts/orchestration/*.sh scripts/release.sh
jq . .claude-plugin/marketplace.json plugins/orchestration/.claude-plugin/plugin.json package.json  # validate manifests
```

and update the bats comment to `# full test suite (includes codex-skills.bats, antigravity.bats, cli.bats, release.bats)`.

Append to the `## Layout` list:

```markdown
- `bin/ganpan.mjs` + `package.json` — zero-dependency Node CLI (`init` delegates to `install.sh`, `validate` is an offline check), run as `npx -y github:Laeyoung/Ganpan#vX.Y.Z <cmd>`; `ganpan-setup` uses it to bootstrap the engine after `npx skills add Laeyoung/Ganpan`.
- `scripts/release.sh` — guarded `vX.Y.Z` tagger run after a version-bump merge (the pinned npx bootstrap resolves the tag).
```

Append to the `## Gotchas` list:

```markdown
- **`npx skills` discovery relies on the recursive fallback** over `plugins/ganpan-codex/skills/`. Never add a root `SKILL.md` or a tracked root `skills/`, `.agents/skills/`, `.claude/skills/` — a shallower `SKILL.md` shadows the six real skills (`tests/codex-skills.bats` guards this).
```

In `## Versioning`, after the "Bump it in the same PR as the change." sentence, add:

```markdown
- `package.json` `version` and the `github:Laeyoung/Ganpan#vX.Y.Z` pins in `plugins/ganpan-codex/skills/ganpan-setup/SKILL.md` must equal `plugin.json` (tests enforce it). After the merge, run `scripts/release.sh X.Y.Z` so the pinned tag exists.
```

- [ ] **Step 3: Release docs**

In `docs/RELEASE_PLAYBOOK.md`:
- Replace the "The release model" paragraph `Ganpan has **no separate release artifact**. There are no git tags, no GitHub Releases, and no build step. The release *is* the merge to \`main\`:` with:

  ```markdown
  Ganpan has **no build step and no GitHub Release**. The release *is* the merge to
  `main`; afterwards a `vX.Y.Z` git tag (§6a) gives the `npx` engine bootstrap an
  immutable ref — the tag is additive and never changes what plugin users receive:
  ```
- In §2 (Bump the version), add a bullet: `- Also set \`package.json\` \`version\` and every \`github:Laeyoung/Ganpan#vX.Y.Z\` pin in \`plugins/ganpan-codex/skills/ganpan-setup/SKILL.md\` to the same value (tests enforce equality).`
- In §3's code block, change the shellcheck line to `shellcheck plugins/orchestration/scripts/orchestration/*.sh scripts/release.sh` and append ` package.json` to the jq line.
- After §6, insert:

  ````markdown
  ### 6a. Tag the release (Skills CLI bootstrap)
  From an up-to-date `main` checkout of `Laeyoung/Ganpan`:
  ```bash
  scripts/release.sh --dry-run X.Y.Z   # all guards, no changes
  scripts/release.sh X.Y.Z             # git tag -a vX.Y.Z + git push origin vX.Y.Z
  ```
  Do this right after the merge: until the tag exists, the new version's
  `ganpan-setup` bootstrap (`npx -y github:Laeyoung/Ganpan#vX.Y.Z init`) fails
  with "tag not found" (skills installed from the previous version keep working).
  If the push fails, the script prints `git tag -d vX.Y.Z` to remove the local tag.
  ````
- In "Rollback", replace `There is no tag to revert to; roll back the same way you shipped:` with `Tags are never moved or deleted; roll back the same way you shipped — a rollback is a *new* version (and a new tag):`, and append step `4. Run \`scripts/release.sh\` for the new version.`
- In the "Surfaces to keep in sync" table, add the row:
  `| Skills CLI (\`npx skills add Laeyoung/Ganpan\`) | recursive discovery of \`plugins/ganpan-codex/skills/\` + pinned \`npx … #vX.Y.Z init\` | \`tests/codex-skills.bats\`, \`tests/cli.bats\`, \`tests/release.bats\` |`

In `docs/RELEASE_CHECKLIST.md`:
- Replace `Ganpan has **no build artifact, git tag, or GitHub Release step** — the release\n*is* the merge to \`main\` with a bumped \`plugin.json\` version` with `Ganpan has **no build artifact or GitHub Release step** — the release\n*is* the merge to \`main\` with a bumped \`plugin.json\` version, followed by a\n\`vX.Y.Z\` tag for the Skills CLI bootstrap`. Keep the rest of the sentence.
- §1: change the lint line to `shellcheck plugins/orchestration/scripts/orchestration/*.sh scripts/release.sh`, and append ` package.json` to the manifests line.
- §2: add `- [ ] \`package.json\` \`version\` and the \`ganpan-setup/SKILL.md\` \`#vX.Y.Z\` pins equal the new \`plugin.json\` version.`
- §3: change "Ganpan ships five surfaces" to "six". Add `- [ ] **Skills CLI** (\`npx skills add Laeyoung/Ganpan\`): discovery guard + CLI tests pass (\`tests/codex-skills.bats\`, \`tests/cli.bats\`).`
- §5: after the "Merge to `main`" box, add `- [ ] Tag it: \`scripts/release.sh --dry-run X.Y.Z\` then \`scripts/release.sh X.Y.Z\`; confirm \`git ls-remote --tags origin vX.Y.Z\` shows it.`

- [ ] **Step 4: README**

In the `## 지원 표면` table, insert this row after the Antigravity row:

```markdown
| Skills CLI (`npx skills`) | Phase 1 (shared payload) | `npx skills add Laeyoung/Ganpan` → `ganpan-*` skills |
```

After the 방법 D section, before its closing `---`, insert:

````markdown
### 방법 E — Skills CLI (`npx skills`)

[Skills CLI](https://github.com/vercel-labs/skills)로 `ganpan-*` 스킬 6종을 Claude Code, Codex, Cursor 등 지원 에이전트에 설치합니다:

```bash
# 글로벌 에이전트 스킬로 설치 (모든 프로젝트에서 사용)
npx skills add Laeyoung/Ganpan -g

# 특정 프로젝트 범위로 설치
npx skills add Laeyoung/Ganpan
```

Skills CLI는 **스킬 디렉터리만** 복사하므로, 엔진(`scripts/orchestration/`)은 레포마다 따로 설치해야 합니다. 대상 레포에서 `ganpan-setup` 스킬을 실행하면, 스킬에 고정(pin)된 버전으로 설치합니다. 직접 실행해도 됩니다:

```bash
npx -y github:Laeyoung/Ganpan#v1.16.0 init       # 기본 --target codex (claude|antigravity|both|all 지정 가능)
npx -y github:Laeyoung/Ganpan#v1.16.0 validate   # config·엔진·라벨 점검 (오프라인, FAIL 시 exit 1)
```

`bash`와 `jq`가 필요합니다(Windows는 Git Bash 또는 WSL). 엔진이 없는 레포에서 레인 스킬을 실행하면 즉시 멈추고 `ganpan-setup`을 먼저 실행하라고 안내합니다. 버전이 어긋나면 `ganpan-setup`이 `init --force` 명령을 **안내만** 합니다(직접 덮어쓰지 않음).
````

In the `## 저장소 구조` code block, add after the `install.sh` line:

```
bin/ganpan.mjs + package.json            # npx CLI (init → install.sh, validate)
scripts/release.sh                       # vX.Y.Z 태그 (pinned npx bootstrap용)
```

- [ ] **Step 5: Change record**

Create `docs/log/2026-09-29-npx-skills-install.md`:

```markdown
# `npx skills add Laeyoung/Ganpan` install surface

- **Date:** 2026-09-29
- **Issue / PR:** — / (fill in the PR number when opened)
- **Type:** feat
- **Version:** 1.15.1 → 1.16.0 (feat → minor)

## What changed
- `bin/ganpan.mjs` + `package.json`: zero-dependency Node CLI run as
  `npx -y github:Laeyoung/Ganpan#vX.Y.Z`. `init` delegates to `install.sh`
  (default `--target codex`, bash/jq preflight, refuses a ganpan checkout);
  `validate` is an offline check of config (placeholders, `owner/name`,
  `$ORCH_CONFIG` resolved against the target dir), engine presence/sentinel drift
  (warn) and `labels.yml`.
- `ganpan-setup` skill bootstraps the engine via the pinned `npx … init`, only
  *prints* `init --force` on drift, and ends with `validate`; the four lane skills
  hard-stop when `scripts/orchestration/lib.sh` is missing.
- `scripts/release.sh`: guarded `vX.Y.Z` tagger (read-only guards incl. canonical
  remote and HEAD == remote/main; push-failure recovery). `.gitignore` un-ignores it.
- Tests: `tests/cli.bats`, `tests/release.bats`, discovery/pin/preflight guards in
  `tests/codex-skills.bats`. CI runs node, shellchecks `release.sh`, validates `package.json`.
- Docs: README 방법 E, release playbook/checklist tag step, CLAUDE.md.

## Why
An external brief asked for `npx skills add Laeyoung/Ganpan -g`. The skills CLI
already discovered the six skills, but it copies only skill directories — every
lane sources `scripts/orchestration/lib.sh`, so skills installed this way failed on
any repo without the engine.

## Key decisions
- **Adapt the brief instead of following it literally** — it described an unrelated
  "AI-agent signboard (`/ganpan/start.md`)" spec; the user chose to reinterpret it for
  the orchestration toolkit. Its `references/spec.md` was dropped.
- **No root `SKILL.md`, no `skills/` symlinks** — a shallower `SKILL.md` shadows nested
  ones; symlinks break on Windows clones. Rely on the recursive fallback and guard its
  preconditions on git-tracked files.
- **`init` delegates to `install.sh`** — one tested copy/sentinel/never-clobber
  implementation instead of a Node rewrite.
- **Pin the bootstrap to a tag** — reproducible installs, and a broken `main` never
  executes on fresh repos. This introduced tags, which are additive to the
  merge-to-`main` release model.
- **Skills never self-run `--force`; lanes never bootstrap** — a skill has no real
  confirmation gate, least of all when unattended.
- **Version stays single-sourced** — the CLI reads `plugin.json`; `package.json` and
  the pin are test-enforced copies.

## Alternatives considered (not chosen)
- Declaring the skills in `.claude-plugin/marketplace.json` — it is also the Claude
  plugin marketplace; it would register the Codex skills as Claude plugin skills.
- Bootstrapping from `main` (`npx github:Laeyoung/Ganpan init`) — mutable,
  non-reproducible, supply-chain exposure.
- Publishing to the npm registry — unnecessary for `npx github:`; kept `private: true`.
- Lanes checking engine staleness themselves — duplicates `ganpan-update`.
```

- [ ] **Step 6: Full verification**

Run each and confirm clean:

```bash
bats tests/*.bats tests/orchestration/*.bats
shellcheck plugins/orchestration/scripts/orchestration/*.sh scripts/release.sh
jq . .claude-plugin/marketplace.json plugins/orchestration/.claude-plugin/plugin.json package.json >/dev/null
npx -y skills add . --list 2>&1 | grep -c 'ganpan-'   # expect 6 (network)
npm pack --dry-run 2>&1 | grep -E 'install.sh|plugin.json|SETUP.md|ganpan.mjs'   # payload present
```

Expected: 0 test failures, shellcheck exit 0, jq exit 0, 6 skills listed, and `npm pack` lists `install.sh`, `plugins/orchestration/.claude-plugin/plugin.json`, `docs/SETUP.md` and `bin/ganpan.mjs`.

- [ ] **Step 7: Commit**

```bash
git add README.md CLAUDE.md docs/RELEASE_PLAYBOOK.md docs/RELEASE_CHECKLIST.md .github/workflows/ci.yml docs/log/2026-09-29-npx-skills-install.md
git commit -m "docs: document the npx skills install surface and tag step

README gains 방법 E (npx skills add + pinned ganpan init/validate); the
release playbook/checklist add the scripts/release.sh tag step and the
Skills CLI surface; CLAUDE.md records the discovery gotcha and the
three-way version pin; CI sets up node, shellchecks release.sh and
validates package.json. Adds the docs/log change record.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 8: Post-push smoke check (network, manual)**

After pushing the branch: in a scratch repo, run `npx -y github:Laeyoung/Ganpan#support-npx-skills-install init`. It should install successfully, which confirms a git-spec npx install ships `install.sh` + `plugins/`. Then run `npx -y skills add Laeyoung/Ganpan#support-npx-skills-install --list` and check that it lists 6 skills. Record both results in the PR description.
