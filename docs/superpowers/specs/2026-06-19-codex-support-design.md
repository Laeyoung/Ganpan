# Ganpan Codex Support — Design Spec

**Date:** 2026-06-19
**Status:** Draft
**Related plan:** `docs/superpowers/plans/2026-06-19-codex-support.md`
**Builds on:**
- `docs/superpowers/specs/2026-06-09-github-orchestration-spec-design.md`
- `docs/superpowers/specs/2026-06-18-orchestration-plugin-design.md`

## 1. Goal

Extend Ganpan from a Claude Code-only orchestration plugin into a public, multi-surface toolkit that supports:

1. **Claude Code** as a first-class existing surface via `/ganpan:*` plugin commands and the copy-in installer.
2. **Codex repo-local skills** as the Phase 1 MVP surface.
3. **A platform-neutral CLI runner** as the Phase 2 deterministic primitive surface.
4. **A Codex plugin package** as the Phase 3 public distribution surface.

The GitHub state machine remains unchanged: Issues, PRs, labels, bot-authored comments, and human-controlled merges remain the source of truth. No database, daemon, or service is introduced.

## 2. Locked Product Decisions

- **Rollout order:** Phase 1 = Codex Skill MVP, Phase 2 = CLI runner, Phase 3 = Codex plugin packaging.
- **Claude remains first-class:** no change may regress `/ganpan:*`, `plugins/orchestration/`, or copy-in install behavior.
- **Codex source path:** Codex adapter/plugin source lives at `plugins/ganpan-codex/`.
- **No dual plugin root:** `plugins/orchestration/` remains the Claude plugin/current core home; it must not become a mixed Claude/Codex plugin root.
- **Installer path:** extend `install.sh` with `--target claude|codex|both`. Default behavior remains Claude/copy-in compatible until a breaking release explicitly changes it.
- **Config compatibility:** `$ORCH_CONFIG` wins; `.ganpan/orchestration.json` is the platform-neutral preferred path; `.claude/orchestration.json` remains supported for existing Claude installs.
- **Public claims:** Phase 1 public support should claim local Codex CLI/IDE only unless Codex app/cloud auth, shell PATH, and `gh` behavior are verified.
- **Public distribution scope:** Phase 3 public distribution means a public repo/team marketplace install path from this repo unless and until OpenAI official Plugin Directory publishing is available and verified.

## 3. Architecture

Ganpan becomes a shared deterministic orchestration core plus surface-specific adapters.

```text
plugins/orchestration/                  # existing Claude plugin root and current core home
  scripts/orchestration/*.sh             # shared deterministic engine
  assets/{labels.yml,task.yml,...}       # shared setup assets
  references/lanes/*.md                  # shared lane protocol source
  commands/*.md                          # Claude adapter
  .claude-plugin/plugin.json

plugins/ganpan-codex/                   # Codex adapter/plugin source
  skills/ganpan-*/SKILL.md               # Phase 1 source, packaged in Phase 3
  skills/ganpan-*/references/*.md        # generated/copied from shared lane references
  skills/ganpan-*/agents/openai.yaml     # recommended Codex UI metadata
  assets/AGENTS.md                       # target-repo Codex conventions block
  .codex-plugin/plugin.json              # Phase 3

.agents/skills/ganpan-*/{SKILL.md,references/,agents/openai.yaml}
                                           # target-repo Phase 1 install output
.agents/plugins/marketplace.json         # repo/team Codex marketplace in Phase 3
```

The core owns deterministic primitives only: config loading, claim/reclaim, heartbeat, WIP checks, test command detection, label bootstrap, project sync, guarded status transitions, and setup checks. Agent judgment remains in Claude commands and Codex skills.

## 4. Shared Lane Protocol

Claude command prompts and Codex skills must not become independent copies of the lane protocol.

The canonical lane procedure text should live under:

```text
plugins/orchestration/references/lanes/
  triage.md
  work-issue.md
  review-queue.md
  qa-check.md
  setup.md
```

Claude commands and Codex skills are thin wrappers over these shared references. If adapter-specific files are copied during Phase 1, the copied files must carry a source version/hash sentinel and the release checklist must compare lane transitions and required security checks across adapters. If generation is introduced later, these references become the source inputs. Phase 3 packages these references into the Codex plugin as skill-local `references/` files or another verified Codex-readable plugin path so installed Codex skills can read them without depending on the Claude plugin installation path.

Every lane protocol must preserve:

- untrusted input warnings for issue bodies, comments, PR descriptions, and diffs;
- human merge gate;
- bot-authored marker filtering for `rework-requested:`, `rework-resolved:`, and `qa-fail-count:`;
- worktree config handling via captured `REPO_ROOT`;
- no approval or merge by agents.

## 5. Config Contract

All scripts that load config must resolve in this order:

1. `$ORCH_CONFIG`
2. `./.ganpan/orchestration.json`
3. `./.claude/orchestration.json`

`load_config` must export the resolved path as `ORCH_CONFIG_PATH`. Scripts that need to read raw config, such as `detect-test-cmd.sh`, must use `ORCH_CONFIG_PATH` after `load_config` rather than recomputing their own fallback.

Adapters must not hardcode `.claude/orchestration.json` for new logic. Existing Claude command snippets that run `jq ... .claude/orchestration.json` must be migrated to resolve the config path first, for example by calling a small shared helper or by sourcing `lib.sh` and using `ORCH_CONFIG_PATH`. Otherwise Claude and Codex can read different configs when both `.ganpan` and `.claude` exist.

Target repo config templates are identical in schema regardless of path:

```json
{
  "repo": "owner/repo",
  "bot": "bot-login",
  "candidateN": 5,
  "wipLimit": 5,
  "reclaim": { "timeoutMinutes": 120, "heartbeatMinutes": 15 },
  "commands": { "test": null, "build": null, "lint": null },
  "worktreeBaseDir": "../",
  "project": { "number": null, "statusField": "Status" }
}
```

When both config files exist, `.ganpan/orchestration.json` is the platform-neutral source of truth for new installs because it appears earlier in discovery order. The legacy `.claude/orchestration.json` remains a compatibility fallback, not an independent second config.

Installer behavior:

- "No config exists" means neither `.ganpan/orchestration.json` nor `.claude/orchestration.json` exists.
- `--target claude` creates `.claude/orchestration.json` only when no config exists. If `.ganpan/orchestration.json` already exists, Claude commands must use the resolver and read it through the normal discovery order.
- `--target codex` creates `.ganpan/orchestration.json` only when no config exists. If a legacy `.claude/orchestration.json` already exists, Codex uses the fallback path and setup/doctor should recommend a deliberate migration rather than silently copying it.
- `--target both` creates `.ganpan/orchestration.json` for new installs and does not create a new `.claude/orchestration.json` when it is absent. If a legacy `.claude/orchestration.json` already exists, it remains the selected fallback until a deliberate migration creates `.ganpan/orchestration.json`.
- If both files already exist and differ, setup/doctor must warn and print the selected path without attempting an automatic merge.

Worktree rule: any lane that `cd`s into `wt-issue-<n>` must capture `REPO_ROOT="$PWD"` before changing directories, resolve the selected config path from that root once, and pass it explicitly as `ORCH_CONFIG`. Linked worktrees do not contain `.ganpan/` or `.claude/` by default. Do not hardcode `ORCH_CONFIG="$REPO_ROOT/.ganpan/orchestration.json"` unless that file was actually selected; use a helper such as `resolve_config_path "$REPO_ROOT"` and pass the returned path.

## 6. Codex Skill MVP

Phase 1 ships repo-local Codex skills. The canonical source lives at:

```text
plugins/ganpan-codex/skills/
  ganpan-triage/{SKILL.md,references/,agents/openai.yaml}
  ganpan-work-issue/{SKILL.md,references/,agents/openai.yaml}
  ganpan-review-queue/{SKILL.md,references/,agents/openai.yaml}
  ganpan-qa-check/{SKILL.md,references/,agents/openai.yaml}
  ganpan-setup/{SKILL.md,references/,agents/openai.yaml}
```

The target install output is:

```text
.agents/skills/
  ganpan-triage/{SKILL.md,references/,agents/openai.yaml}
  ganpan-work-issue/{SKILL.md,references/,agents/openai.yaml}
  ganpan-review-queue/{SKILL.md,references/,agents/openai.yaml}
  ganpan-qa-check/{SKILL.md,references/,agents/openai.yaml}
  ganpan-setup/{SKILL.md,references/,agents/openai.yaml}
```

Each skill must:

- include valid YAML frontmatter with `name` and `description`;
- include `agents/openai.yaml` UI metadata unless implementation-time validation proves it is unavailable or inappropriate for repo-local skills;
- keep `SKILL.md` concise and put long procedural details in `references/`;
- avoid `${CLAUDE_PLUGIN_ROOT}`, `/loop`, `/goal`, and Claude slash-command assumptions;
- point to `.ganpan/orchestration.json` for new Codex installs while documenting `.claude` fallback;
- refer to skill-bundled references/scripts through paths that are valid from the installed skill package, preferably skill-local `references/` and `scripts/`, and avoid assuming the source checkout exists;
- not require `PLUGIN_ROOT` or `PLUGIN_DATA` from normal skill instructions unless implementation-time validation proves those variables are available in that execution context; those variables are documented for plugin hook commands, not as a general replacement for skill-local references;
- preserve all untrusted-input warnings and lane gates.

Custom prompts are not the primary distribution path. They may appear only as documentation examples.

## 7. Installer Contract

`install.sh` accepts:

```bash
./install.sh <target-repo-path>
./install.sh <target-repo-path> --target claude
./install.sh <target-repo-path> --target codex
./install.sh <target-repo-path> --target both
./install.sh <target-repo-path> --force
```

Default behavior must remain compatible with the existing Claude/copy-in path.

### 7.1 Claude Target

Claude target behavior remains existing copy-in behavior:

- scripts to `scripts/orchestration/`;
- commands to `.claude/commands/`;
- config template according to §5: create `.claude/orchestration.json` only when neither `.ganpan/orchestration.json` nor `.claude/orchestration.json` exists;
- labels and issue template to `.github/` only if absent;
- conventions block to `CLAUDE.md` once, guarded by sentinel.

### 7.2 Codex Target

Codex target behavior:

- skills to `.agents/skills/ganpan-*`;
- conventions block to `AGENTS.md` once, guarded by sentinel;
- config template according to §5: create `.ganpan/orchestration.json` only when neither `.ganpan/orchestration.json` nor `.claude/orchestration.json` exists;
- labels and issue template to `.github/` only if absent;
- never write `.claude/commands/`;
- never rewrite existing `.claude/` files.

### 7.3 Both Target

Both target installs Claude and Codex surfaces while copying shared assets only once. It must not duplicate labels, issue templates, or config side effects.

Both target follows the config contract in §5. It creates `.ganpan/orchestration.json` for new installs and does not create `.claude/orchestration.json` when it is absent. If a legacy `.claude/orchestration.json` already exists and `.ganpan/orchestration.json` does not, both target leaves it in place as the selected fallback and prints the migration recommendation. If both files exist, `.ganpan/orchestration.json` wins and setup/doctor must warn if they diverge.

### 7.4 Idempotency

All public install paths must be safe to re-run. Existing user-owned files are not clobbered unless `--force` is explicitly used where documented. Phase 1 installs skills by copying canonical files with version sentinels; sentinel-less destination skill files are treated as user-owned and skipped unless `--force` is used. Future generation is allowed only if it preserves the same idempotency and upgrade semantics.

## 8. CLI Runner Contract

The Phase 2 runner is a deterministic primitive runner, not an autonomous coding agent.

Candidate interface:

```bash
ganpan setup owner/repo --bot bot-login [--target claude|codex|both]
ganpan doctor --json
ganpan lane triage next --json
ganpan lane triage mark-ready <issue>
ganpan lane triage mark-blocked <issue> --reason-file <path>
ganpan lane work-issue claim --json
ganpan lane work-issue mark-in-review <issue> --pr <number>
ganpan lane review-queue list --json
ganpan lane review-queue request-rework <issue> --pr <number> --reason-file <path>
ganpan lane qa-check list --json
ganpan lane review-queue mark-qa <issue> --pr <number>
ganpan lane qa-check mark-done <issue> --evidence-file <path>
ganpan lane qa-check record-failure <issue> --summary-file <path>
ganpan lane qa-check mark-blocked <issue> --reason-file <path>
ganpan loop triage --every 10m
ganpan loop review-queue --every 5m
```

State-changing primitives must be lane-scoped. Do not expose a generic `transition <issue> --to <status>` command.

`ganpan setup` must not become a second installer with subtly different behavior. If it writes target-repo files, it must use the same target/config/idempotency contract as `install.sh`; otherwise it should be limited to GitHub/bootstrap setup and documented as such.

Required guards:

- `triage mark-ready` requires current `status:triage` and moves only to `status:agent-ready`.
- `triage mark-blocked` requires a reason and moves only `status:triage -> status:blocked`.
- `work-issue mark-in-review` verifies the PR exists, is open, and is associated with the issue branch or linked issue before moving `status:in-progress -> status:in-review`.
- `review-queue request-rework` writes a bot-authored `rework-requested:` marker and moves only `status:in-review -> status:in-progress`.
- `review-queue mark-qa` verifies the PR is merged before `status:in-review -> status:qa`.
- `qa-check mark-done` requires an evidence file or summary path, moves only `status:qa -> status:done`, and closes the issue (`gh issue close <n> --reason completed`).
- `qa-check record-failure` reads only bot-authored `qa-fail-count:` markers, increments the count, and follows the existing QA failure policy: first failure creates/links a regression issue and moves `status:qa -> status:in-progress`; second and later failures move `status:qa -> status:blocked`. On first failure, create the regression issue before mutating the original issue labels; the original issue comment should include both the new `qa-fail-count:` value and the linked regression issue number so the operation can be audited and retried safely.
- `qa-check mark-blocked` requires a reason and moves only from `status:qa` for non-retryable QA blockers.
- all rework/block paths preserve bot-authored marker filtering.
- invalid transitions fail closed and leave labels unchanged.

Runner output intended for adapters must support machine-readable `--json`. JSON output and errors must not include full environment dumps or token values.

## 9. Codex Plugin Packaging Contract

Phase 3 packages the Codex adapter as a plugin from `plugins/ganpan-codex/`.

The plugin manifest lives at:

```text
plugins/ganpan-codex/.codex-plugin/plugin.json
```

It must use the current Codex plugin manifest schema at implementation time. Expected fields include semver `version`, `name`, `description`, `author`, `skills`, and `interface` metadata, but implementation must validate against the active schema and omit rejected fields.

Do not include hooks, MCP, or app manifest entries unless Ganpan actually ships those components in the Codex plugin. If hooks are introduced later, they must follow Codex hook trust rules and use hook-specific path/environment contracts; they are not required for the Phase 3 skill package.

Marketplace/distribution:

- local testing may use `~/.agents/plugins/marketplace.json`;
- repo/team distribution from this repo may use `.agents/plugins/marketplace.json`;
- intended plugin source path is `./plugins/ganpan-codex`;
- do not publish until `codex plugin marketplace add <path-to-marketplace-root>`, `codex plugin marketplace list`, and the current Codex plugin install/enable flow prove marketplace-root resolution and plugin loading work.
- public docs must distinguish repo/team marketplace distribution from official Plugin Directory publication; do not claim official Plugin Directory availability until that publishing path is actually open and validated for Ganpan.

Runtime path contract:

- plugin manifest component paths must be `./`-prefixed and relative to the plugin root;
- skill instructions should resolve their own references through skill-local `references/` and `scripts/` paths, or another installed-plugin path verified by a live packaged install;
- repo-local Phase 1 skills may use target-repo relative paths for target repo files, but packaged Phase 3 skills must not assume they are running from the Ganpan source checkout;
- `PLUGIN_ROOT` and `PLUGIN_DATA` may be used only where Codex documents them for the current component type, currently hook commands; do not use them as the primary skill reference mechanism without live validation.

After reinstalling a local plugin during development, a fresh Codex thread/session is required before declaring updated skills available.

## 10. Auth And Secret Handling

Ganpan requires `gh`, `git`, `jq`, `yq`, repository write access, and GitHub auth.

Minimum GitHub permission contract:

- Issues read/write for labels, comments, assignees, and issue creation;
- Pull requests read/write for PR lookup and PR creation;
- Contents read/write for branches and commits created by coder lanes;
- Projects read/write only when `project.number` is configured; when it is `null`, project sync is a no-op and Projects permission is not required for core operation.

Surface-specific support:

- **Claude Code:** existing plugin/copy-in setup remains supported.
- **Codex CLI / IDE:** supported in Phase 1 when local shell PATH and local `gh` auth or exported `GH_TOKEN` are available.
- **Codex app / cloud-like environments:** do not claim public support until secret provisioning, workspace setup, shell PATH, and `gh` behavior are verified.

Secret handling rules:

- never print token values;
- never dump full environment variables;
- dry-run/doctor may report auth presence and coarse status only;
- generated issue comments and PR bodies must not include secrets;
- tests should include fixtures that would fail if `GH_TOKEN` appears in output.

## 11. Testing Contract

Required tests by phase:

### Phase 1

- config discovery order: `$ORCH_CONFIG`, `.ganpan`, `.claude`;
- installer config matrix for existing `.ganpan` only, existing `.claude` only, both matching, and both diverging;
- both-config divergence warning;
- Claude command snippets no longer hardcode `.claude/orchestration.json` when reading config;
- `detect-test-cmd.sh` uses `ORCH_CONFIG_PATH`;
- Codex skill frontmatter validation;
- Codex `agents/openai.yaml` metadata validation or documented omission;
- Codex skill reference paths resolve from installed `.agents/skills/ganpan-*` directories;
- no Claude-only tokens in Codex artifacts;
- `install.sh --target codex` temp-repo install;
- `install.sh --target both` temp-repo install;
- installer idempotency against existing `AGENTS.md`, `.ganpan/orchestration.json`, labels, and issue template;
- setup/dry-run output does not print token values.

### Phase 2

- runner argument parsing;
- runner JSON output shape;
- invalid transitions fail closed;
- required evidence/reason files are enforced for state-changing commands that need human-readable audit context;
- `work-issue mark-in-review` requires a valid PR;
- merged PR required for `in-review -> qa`;
- `qa-check record-failure` follows first-failure rework and repeated-failure block policy;
- first-failure regression issue creation is ordered before original issue label mutation and records an auditable regression issue link;
- user-authored rework/QA markers are ignored;
- doctor/dry-run secret safety.

### Phase 3

- Codex plugin manifest validation;
- marketplace install/list smoke test;
- plugin-packaged skills can resolve bundled lane references from the installed package without requiring the Ganpan source checkout;
- plugin-packaged skills do not rely on `PLUGIN_ROOT`/`PLUGIN_DATA` unless a live packaged install proves those variables are available for the relevant component type;
- reinstall flow requires fresh session/thread note in docs;
- package includes skills, shared lane references, assets, and runner integration.

Existing bats tests for the orchestration engine must remain green throughout.

## 12. Documentation Contract

README and SETUP docs must present a support matrix:

| Surface | Phase | Status | Primary UX |
|---|---:|---|---|
| Claude Code plugin | existing | first-class | `/ganpan:*` commands |
| Copy-in install | existing | first-class fallback | `.claude/commands` + scripts |
| Codex skills | Phase 1 | MVP then first-class | `.agents/skills/ganpan-*` |
| CLI runner | Phase 2 | shared deterministic primitive interface | `ganpan lane ...` |
| Codex plugin | Phase 3 | public distribution | Codex plugin install |

Docs must split setup into common GitHub setup plus surface-specific setup. They must explicitly document unsupported or verification-pending surfaces, especially Codex app/cloud execution if GitHub auth, shell PATH, or `gh` availability has not been proven.

Docs must also define what "public distribution" means for each phase. Phase 1 is public source/install documentation for repo-local skills, Phase 2 is a public runner interface, and Phase 3 is a public repo/team Codex marketplace path unless official Plugin Directory publication has been validated.

## 13. Open Questions

- What exact Codex plugin manifest fields are required at implementation time, and which fields does the active validator reject?
- When, if ever, should generated adapter files replace copied files with source version/hash sentinels?
- Should the CLI runner be pure Bash for minimum dependency footprint, or a small typed CLI for better UX and testing?
- Should `.claude/orchestration.json` eventually be migrated to `.ganpan/orchestration.json` for Claude users, or supported indefinitely as a legacy path?
- What versioning scheme should align Claude plugin, Codex plugin, core engine, and copy-in installer releases?
- What is the minimum supported Codex surface for public claims: CLI only, CLI+IDE, or CLI+IDE+app after cloud auth verification?
