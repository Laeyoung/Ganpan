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

// npxCmd — the runnable form of a ganpan subcommand: under `npx github:…` distribution
// the `ganpan` bin is not on PATH, so hints must print the pinned npx invocation.
function npxCmd(sub) {
  return `npx -y github:Laeyoung/Ganpan#v${version()} ${sub}`;
}

function fail(msg) {
  process.stderr.write(`ganpan: ${msg}\n`);
  return 1;
}

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
  else return report('FAIL', `config missing: .ganpan/orchestration.json (or legacy .claude/orchestration.json) — run \`${npxCmd('init')}\``);

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
    report('FAIL', `engine missing: scripts/orchestration/lib.sh — run \`${npxCmd('init')}\``);
  } else {
    const m = readFileSync(lib, 'utf8').match(/ganpan-orchestration: v(\d+\.\d+\.\d+)/);
    const cli = version();
    if (!m) report('warn', `engine lib.sh has no ganpan-orchestration sentinel — \`${npxCmd('init --force')}\` re-stamps it`);
    else if (m[1] !== cli) report('warn', `engine v${m[1]} differs from ganpan v${cli} — update with \`${npxCmd('init --force')}\``);
    else report('ok', `engine version v${m[1]}`);
  }

  if (existsSync(join(root, '.github/labels.yml'))) report('ok', 'labels .github/labels.yml');
  else report('FAIL', `labels missing: .github/labels.yml — run \`${npxCmd('init')}\``);

  return failed ? 1 : 0;
}

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

function main(argv) {
  const [cmd, ...rest] = argv;
  try {
    switch (cmd) {
      case 'init':
        return cmdInit(rest);
      case 'validate':
        return cmdValidate(rest);
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
