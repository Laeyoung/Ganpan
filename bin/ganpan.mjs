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
