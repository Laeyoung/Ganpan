# Repository Guidelines

## Project Structure & Module Organization

Ganpan is a GitHub-native orchestration toolkit for Claude Code, Codex, and Antigravity CLI.

- `install.sh` installs the toolkit into target repositories.
- `plugins/orchestration/` contains the shared orchestration engine, Claude commands, assets, and lane references.
- `plugins/ganpan-codex/` contains Codex repo-local skill sources and `AGENTS.md` assets.
- `tests/` contains Bats tests for installer behavior and orchestration scripts.
- `docs/` contains setup guides, Codex runbooks, design specs, and implementation plans.

## Build, Test, and Development Commands

Use shell scripts directly; there is no package build step.

```bash
bash -n install.sh plugins/orchestration/scripts/orchestration/*.sh
```

Checks shell syntax for installer and engine scripts.

```bash
bats tests/*.bats tests/orchestration/*.bats
```

Runs the full test suite.

```bash
./install.sh /path/to/target --target codex
./install.sh /path/to/target --target both
./install.sh /path/to/target --target antigravity
```

Smoke-tests installation flows against a temporary target repo.

## Coding Style & Naming Conventions

Shell code uses Bash with `set -euo pipefail`. Keep functions small and quote variables. Prefer portable shell patterns that work on macOS and Linux. Use kebab-case for lane and skill names, for example `ganpan-work-issue`, and keep GitHub labels in the `status:*` pattern.

## Testing Guidelines

Tests use Bats. Add regression tests before changing behavior. Installer tests belong in `tests/install.bats`; orchestration script tests belong in `tests/orchestration/*.bats`; Codex skill validation belongs in `tests/codex-skills.bats`; Antigravity install validation belongs in `tests/antigravity.bats`. New install behavior should be tested against temporary target repos.

## Commit & Pull Request Guidelines

Use Conventional Commits, as seen in history: `feat(scope): subject`, `fix(scope): subject`, `docs(scope): subject`, or `chore(scope): subject`. PRs should describe behavior changes, link related issues, list verification commands, and call out security or GitHub permission implications.

## Security & Configuration Tips

Never print token values or full environment dumps. Config discovery order is `$ORCH_CONFIG`, `.ganpan/orchestration.json`, then `.claude/orchestration.json`. Agents must not approve or merge PRs; human review remains the merge gate.
