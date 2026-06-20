# Phase 1 Development Log

This log records the Codex Skill MVP work so Phase 2 and Phase 3 can build on the actual implementation, not just the original plan.

## Scope Delivered

Phase 1 made Ganpan usable from Codex through repo-local skills while keeping Claude Code support intact.

Delivered surfaces:

- Claude Code plugin/copy-in commands remain supported.
- Codex repo-local skills are installed under `.agents/skills/ganpan-*`.
- Shared shell engine stays under `scripts/orchestration/*.sh`.
- Shared lane references live under `references/lanes/*.md` in target repos.
- New Codex installs prefer `.ganpan/orchestration.json`.
- Legacy Claude installs using `.claude/orchestration.json` still work.

## Main Implementation Changes

### Config Resolution

Added `resolve_config_path` in `plugins/orchestration/scripts/orchestration/lib.sh`.

Resolution order:

1. `$ORCH_CONFIG`
2. `./.ganpan/orchestration.json`
3. `./.claude/orchestration.json`

`load_config` now exports `ORCH_CONFIG_PATH`. Scripts that need raw config, such as `detect-test-cmd.sh`, read that resolved path instead of recomputing a fallback.

### Installer Targets

`install.sh` now accepts:

```bash
./install.sh <target-repo-path>
./install.sh <target-repo-path> --target claude
./install.sh <target-repo-path> --target codex
./install.sh <target-repo-path> --target both
./install.sh <target-repo-path> --force
```

Default behavior remains Claude/copy-in compatible.

Target behavior:

- `claude`: installs scripts, `.claude/commands`, shared references, `CLAUDE.md`, GitHub assets, and `.claude/orchestration.json` only when no config exists.
- `codex`: installs scripts, shared references, `.agents/skills/ganpan-*`, `AGENTS.md`, GitHub assets, and `.ganpan/orchestration.json` only when no config exists.
- `both`: installs both surfaces, creates `.ganpan/orchestration.json` for new repos, and does not create a new `.claude/orchestration.json` when absent.

If `.ganpan/orchestration.json` and `.claude/orchestration.json` both exist and differ, installer output warns that `.ganpan` wins and does not merge them.

### Codex Skill Source

Canonical Codex skill source now lives at:

```text
plugins/ganpan-codex/skills/
  ganpan-triage/
  ganpan-work-issue/
  ganpan-review-queue/
  ganpan-qa-check/
  ganpan-setup/
```

Each skill includes:

- `SKILL.md`
- `references/<lane>.md`
- `agents/openai.yaml`

The target install output mirrors that structure under `.agents/skills/ganpan-*`.

### Shared Lane References

Shared lane references were added under:

```text
plugins/orchestration/references/lanes/
  triage.md
  work-issue.md
  review-queue.md
  qa-check.md
  setup.md
```

Codex skill references are copied from these files and tests assert they match.

Claude lane commands now point to the shared reference files as the canonical protocol while preserving Claude-specific execution snippets.

### Claude Command Updates

Runtime Claude lane commands no longer hardcode `.claude/orchestration.json` for config reads. They resolve config once from the main checkout and pass `ORCH_CONFIG` into scripts that may run from worktrees.

Updated commands:

- `plugins/orchestration/commands/triage.md`
- `plugins/orchestration/commands/work-issue.md`
- `plugins/orchestration/commands/review-queue.md`
- `plugins/orchestration/commands/qa-check.md`
- `plugins/orchestration/commands/orch-setup.md`

`orch-setup.md` now respects the shared config contract and does not create `.claude/orchestration.json` when `.ganpan/orchestration.json` already exists.

## Bugs Found During QA

### Installed Scripts Lost Execute Permission

Symptom:

```text
permission denied: scripts/orchestration/detect-test-cmd.sh
```

Root cause:

`stamp()` edits files through `mktemp` + `mv`. The temp file mode replaced the executable script mode after `chmod +x` had already run.

Fix:

For engine scripts, run `stamp "$dest"` before `chmod +x "$dest"`.

Regression evidence:

- `tests/install.bats` asserts installed `detect-test-cmd.sh` is executable.
- Direct temp-target smoke executes `scripts/orchestration/detect-test-cmd.sh` successfully.

### Installer Printed Wrong Config Path

Symptom:

`install.sh --target claude` on a repo with existing `.ganpan/orchestration.json` printed instructions to edit `.claude/orchestration.json`, even though no `.claude` config was created.

Fix:

Installer now computes `SELECTED_CONFIG_PATH` after config creation/preservation and prints that path.

Regression evidence:

- `tests/install.bats` covers `--target claude` with existing `.ganpan/orchestration.json`.

### Legacy Fallback Was Too Silent

Symptom:

`--target codex` with only `.claude/orchestration.json` correctly used legacy fallback but did not tell users how to migrate.

Fix:

Installer now prints:

- legacy `.claude/orchestration.json` is selected
- migration requires deliberately creating `.ganpan/orchestration.json`

Regression evidence:

- `tests/install.bats` checks the fallback output.

### Claude Setup Prompt Had Stale Config Rules

Symptom:

`orch-setup.md` still described `.claude/orchestration.json` as the only setup config and could instruct agents to create it even when `.ganpan` exists.

Fix:

`orch-setup.md` now follows the shared config contract:

- `.ganpan` wins
- `.claude` remains fallback
- neither exists means create `.claude` for Claude setup
- differing config files trigger a warning

Regression evidence:

- `tests/codex-skills.bats` checks the setup command contract.

### QA And Rework Instructions Were Too Weak

Issues found:

- QA command text referenced capturing `REPO_ROOT` but did not show the assignment.
- QA first-failure path did not strongly require linking the regression issue number back on the original issue.
- Shared work-issue reference did not preserve rework resume safety steps from the Claude command.

Fixes:

- Added concrete `REPO_ROOT="$PWD"` in `qa-check.md`.
- Required QA first failure to comment with both `qa-fail-count: 1` and the linked regression issue number.
- Added orphan heartbeat cleanup and `rework-resolved:` marker rules to shared work-issue references.

Regression evidence:

- `tests/codex-skills.bats` checks these prompt safety requirements.

## Test Coverage Added

New/expanded tests cover:

- config discovery order: `$ORCH_CONFIG`, `.ganpan`, `.claude`
- `ORCH_CONFIG_PATH` export
- `detect-test-cmd.sh` using `.ganpan` overrides
- installer target matrix for `claude`, `codex`, and `both`
- existing `.ganpan`
- existing `.claude`
- matching `.ganpan` + `.claude`
- diverging `.ganpan` + `.claude`
- Codex-only install never writing `.claude/commands`
- AGENTS convention block idempotency
- installer output does not print token values
- installed scripts are executable
- shared references are installed
- Codex skill frontmatter exists
- Codex `agents/openai.yaml` parses with `yq`
- Codex artifacts do not contain Claude-only execution tokens
- Codex skill references match shared references
- installed Codex skill references resolve from `.agents/skills`
- Claude commands no longer hardcode legacy config paths
- Claude commands point to shared lane references
- Claude setup command follows shared config contract

## Verification Commands

Last full verification used:

```bash
bash -n install.sh plugins/orchestration/scripts/orchestration/lib.sh plugins/orchestration/scripts/orchestration/detect-test-cmd.sh
git diff --check
bats tests/*.bats tests/orchestration/*.bats
```

Expected current result:

```text
75/75 tests passed
```

Additional runtime smoke verified temp target installs for:

- new Codex install using `.ganpan/orchestration.json`
- legacy fallback using `.claude/orchestration.json`
- explicit `ORCH_CONFIG`
- direct execution of installed `scripts/orchestration/detect-test-cmd.sh`

## Phase 2 Handoff Notes

Phase 2 should treat the shell scripts and config resolver as the stable core.

Do:

- Reuse `resolve_config_path` and `ORCH_CONFIG_PATH`.
- Keep `.ganpan` preferred and `.claude` as fallback.
- Use lane-scoped runner commands, not a generic transition API.
- Preserve bot-authored marker filtering.
- Preserve human merge gate.
- Preserve installed script execute permissions after stamping or generation.
- Return machine-readable output for runner primitives.

Do not:

- Reintroduce `.claude/orchestration.json` hardcodes.
- Make the runner perform coding, review, or QA judgment.
- Print token values in doctor/dry-run/setup output.
- Add a second installer contract through `ganpan setup`.

## Phase 3 Handoff Notes

Phase 3 should package the Phase 1 skill source and shared references without assuming the Ganpan source checkout exists.

Before shipping a Codex plugin:

- Verify the current Codex plugin manifest schema.
- Prove marketplace install/list/enable behavior with the active Codex CLI or UI.
- Prove packaged skills can read bundled references from the installed plugin package.
- Do not rely on `PLUGIN_ROOT` or `PLUGIN_DATA` in skills unless current Codex docs and live install behavior prove those variables are available for skill execution.
- Require a fresh Codex thread/session after reinstalling a local plugin before declaring updated skills available.

