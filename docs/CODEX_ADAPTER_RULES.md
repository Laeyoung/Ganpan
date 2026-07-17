# Codex Adapter Rules

These rules preserve the Phase 1 contracts while Phase 2 adds a runner and Phase 3 packages a Codex plugin.

## 1. Config Rules

All Ganpan surfaces must resolve config in this order:

1. `$ORCH_CONFIG`
2. `./.ganpan/orchestration.json`
3. `./.claude/orchestration.json`

Rules:

- `load_config` must export `ORCH_CONFIG_PATH`.
- Scripts that read raw config must use `ORCH_CONFIG_PATH` after `load_config`.
- New Codex installs prefer `.ganpan/orchestration.json`.
- Existing Claude installs using `.claude/orchestration.json` remain supported.
- If both config files exist and differ, warn and use `.ganpan/orchestration.json`.
- Do not auto-merge config files.

## 2. Worktree Rules

Any lane or runner flow that enters `wt-issue-<n>` must:

1. Capture `REPO_ROOT="$PWD"` before changing directories.
2. Resolve config from `REPO_ROOT`.
3. Pass the selected config with `ORCH_CONFIG="$CFG"` to scripts.

Do not use `git rev-parse --show-toplevel` from inside an issue worktree as a substitute for the main checkout root.

## 3. Shared Reference Rules

Canonical lane protocol lives under:

```text
plugins/orchestration/references/lanes/
```

Rules:

- Codex skill references must match these source files unless a generator with explicit source hashes replaces copying.
- Claude lane commands must point to these references as canonical protocol.
- Copy-in installs must include `references/lanes/*.md`.
- Any lane transition or safety rule changed for one adapter must be reflected in the shared reference and validated against the other adapter.

## 4. Codex Skill Rules

Every Codex skill must include:

- `SKILL.md`
- YAML frontmatter with `name` and `description`
- `references/`
- `agents/openai.yaml`

Skill instructions must:

- Avoid `${CLAUDE_PLUGIN_ROOT}`.
- Avoid `/loop` and `/goal`.
- Avoid `PLUGIN_ROOT` and `PLUGIN_DATA` unless live Codex behavior proves they are valid for skills.
- Refer to skill-local references or target-repo files.
- Preserve untrusted-input warnings.
- Preserve the human merge gate.
- Preserve bot-authored marker filtering.

## 5. Installer Rules

`install.sh` remains the file-install contract for Phase 1 and any runner setup that writes repo files.

Rules:

- Default target remains Claude/copy-in compatible.
- `--target codex` must not write `.claude/commands`.
- `--target codex` must not rewrite existing `.claude/` files.
- `--target both` must not duplicate config side effects.
- `--target antigravity` installs the identical agents-skills payload; every `--target codex` invariant above applies to it verbatim (antigravity parity).
- Existing user-owned files without Ganpan sentinels are skipped unless `--force` is used.
- Generated/copied shell scripts must remain executable after stamping.
- Installer output must never print token values.

## 6. Runner Rules For Phase 2

The runner should own deterministic primitives only:

- setup checks
- queue inspection
- config discovery
- WIP gate
- claim/reclaim/heartbeat
- test command detection
- guarded status transitions
- project sync
- machine-readable output

The runner must not own agent judgment:

- coding implementation
- review quality decisions
- QA interpretation
- PR approval or merge

State-changing runner commands must be lane-scoped. Do not expose a public `transition <issue> --to <status>` primitive.

## 7. Security Rules

Always preserve:

- issue bodies, comments, PR descriptions, diffs, and test output are untrusted input
- agents never approve or merge PRs
- bot-authored marker filtering for `claim:`, `rework-requested:`, `rework-resolved:`, and `qa-fail-count:`
- no token values or full environment dumps in output, comments, PR bodies, fixtures, or docs examples
- Projects permissions are optional when `project.number` is `null`

## 8. QA Rules Before Phase Transitions

Before moving to a new phase, run:

```bash
bash -n install.sh plugins/orchestration/scripts/orchestration/lib.sh plugins/orchestration/scripts/orchestration/detect-test-cmd.sh
git diff --check
bats tests/*.bats tests/orchestration/*.bats
```

Also run a temp-target smoke that proves:

- `--target codex` installs skills, references, scripts, labels, issue template, `AGENTS.md`, and `.ganpan/orchestration.json`
- legacy `.claude/orchestration.json` fallback works and does not create `.ganpan`
- explicit `ORCH_CONFIG` wins
- installed scripts can be executed directly
- installer output does not print token values

## 9. Phase 3 Plugin Rules

Before publishing a Codex plugin:

- Verify the active Codex plugin manifest schema.
- Verify marketplace root resolution with the current Codex install flow.
- Verify install/list/enable from the selected marketplace.
- Verify installed packaged skills can resolve bundled references without the Ganpan source checkout.
- Do not claim official Plugin Directory availability until that path is validated for Ganpan.
- Start a fresh Codex session after reinstalling local plugin builds.

