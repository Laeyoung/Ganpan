# Ganpan Codex Support Plan

> **For agentic workers:** implement this plan phase-by-phase. Keep Claude Code support first-class throughout; do not land a phase that regresses the existing Claude plugin, copy-in installer, or bats suite.

**Goal:** Extend Ganpan from a Claude Code-only plugin into a public, multi-surface agent orchestration toolkit that supports both Claude Code and Codex while sharing one tested GitHub-native orchestration core.

**Locked decisions:**
- **Rollout order:** Phase 1 = Codex Skill MVP (**A**), Phase 2 = CLI runner / platform-neutral execution (**C**), Phase 3 = Codex Plugin packaging (**B**).
- **Config strategy:** support both `.ganpan/orchestration.json` and legacy `.claude/orchestration.json`. New Codex installs should prefer `.ganpan/orchestration.json`; existing Claude installs continue to work unchanged.
- **Distribution target:** public distribution, not just personal local use.
- **Claude Code status:** Claude Code remains a first-class supported surface, with `/ganpan:*` plugin commands and copy-in install continuing to work.
- **Codex source path:** use `plugins/ganpan-codex/` as the canonical Codex adapter/plugin source. Do not make the existing `plugins/orchestration/` tree a dual Claude/Codex plugin root.
- **Codex installer path:** extend the existing `install.sh` with `--target claude|codex|both`; default remains Claude/copy-in compatible behavior until a breaking release explicitly changes it.

**Architecture:** Split Ganpan into a shared core plus surface-specific adapters. The shared core owns deterministic orchestration primitives: shell scripts, labels, issue templates, setup assets, config discovery, and tests. Claude Code and Codex each provide their own agent-facing command/skill/plugin packaging over the same core. Agent judgment remains in the adapters; the core should not pretend it can implement, review, or QA code without an agent.

```text
plugins/orchestration/                 # existing Claude plugin root and current core home
  scripts/orchestration/*.sh
  assets/{labels.yml,task.yml,orchestration.json,CLAUDE.md}
  .claude-plugin/plugin.json

plugins/orchestration/commands/        # existing Claude adapter
  /ganpan:* command prompts

plugins/ganpan-codex/                  # added in Phase 1/3
  .codex-plugin/plugin.json             # Phase 3
  skills/*/SKILL.md                     # Phase 1, packaged in Phase 3
  assets/AGENTS.md
  optional CLI runner integration

.agents/skills/                         # repo-local Codex Skill MVP install target in Phase 1
  ganpan-*/SKILL.md

.agents/plugins/marketplace.json        # repo/team Codex marketplace, Phase 3 if publishing from this repo
```

**Non-goals for the first pass:**
- Do not replace GitHub labels/Issues/PRs as the state machine.
- Do not remove the existing Claude Code marketplace/plugin path.
- Do not require a database, service, or daemon.
- Do not automate human-only security steps such as PAT creation or branch protection changes.
- Do not claim the Phase 2 CLI can perform coding, review, or QA judgment by itself. It can run deterministic primitives and prepare lane context; an agent still performs the task-specific reasoning.
- Do not add Codex custom prompts as the primary distribution path. Use skills for reusable Codex workflows; keep one-off prompts as documentation examples only.

---

## Cross-Phase Invariants

- **Single orchestration core:** claim, reclaim, heartbeat, WIP gate, test-command detection, project sync, and label bootstrap are implemented once and reused by Claude and Codex.
- **Single lane procedure source:** Claude command prompts and Codex skills must not drift into two independent copies of the lane protocol. Either generate them from shared lane reference files or keep a shared `references/lanes/*.md` source that both adapters import/point to.
- **No Claude-only leakage in Codex artifacts:** Codex skills/docs must not require `${CLAUDE_PLUGIN_ROOT}`, `/loop`, `/goal`, or `.claude/orchestration.json` as the only config path.
- **No Codex-only leakage in Claude artifacts:** Claude commands must keep the current `/ganpan:*` UX and plugin-root behavior.
- **Config discovery order:** scripts that load config should resolve in this order:
  1. `$ORCH_CONFIG`
  2. `./.ganpan/orchestration.json`
  3. `./.claude/orchestration.json`
- **Resolved config path:** `load_config` should export the actual config path it used, for example `ORCH_CONFIG_PATH`, and other scripts must read command overrides from that resolved path instead of recomputing a stale fallback.
- **Public distribution quality bar:** docs, install paths, versioning, tests, and upgrade behavior must be explicit enough for users outside this repo.
- **Installer idempotency:** public install paths must be safe to re-run. Do not clobber existing `.ganpan/orchestration.json`, `.claude/orchestration.json`, `AGENTS.md`, `CLAUDE.md`, label customizations, or issue templates unless a documented `--force` path is used.
- **Human merge gate:** all surfaces must keep the invariant that agents never approve or merge PRs.
- **Transition guardrails:** any runner command that changes GitHub labels must enforce allowed state transitions, bot-authored marker checks, and human-merge gates. Do not expose a generic `transition any-issue --to any-status` primitive for public use.
- **Prompt injection boundary:** issue titles, issue bodies, comments, PR descriptions, and diffs remain untrusted input across Claude and Codex.
- **Worktree config boundary:** any surface that `cd`s into `wt-issue-<n>` must capture the main checkout root before changing directories and pass `ORCH_CONFIG`/`ORCH_CONFIG_PATH` explicitly, because worktrees do not contain `.ganpan/` or `.claude/` by default.
- **Surface auth boundary:** Ganpan depends on `gh`, `git`, `jq`, `yq`, repository write access, and `GH_TOKEN`/GitHub auth. Each supported surface must document where those prerequisites live:
  - local Codex CLI / IDE: local shell PATH + local `gh` auth or exported `GH_TOKEN`;
  - Codex app / cloud-like environments: documented secret provisioning and workspace setup, or explicitly unsupported until verified;
  - Claude Code: existing plugin/copy-in setup remains supported.
- **Secret handling:** no command, dry-run, generated issue comment, PR body, setup output, or test fixture should print token values or environment dumps. Log auth presence and scopes only at a coarse level.

---

## Phase 1: Codex Skill MVP (A)

**Goal:** Make Ganpan usable from Codex as skills while reusing the existing shell engine. This phase proves the workflow in Codex without committing to final plugin packaging.

**Primary deliverable:** Codex skill bundle for the five lanes. Each skill is a directory with a required `SKILL.md` and YAML frontmatter (`name`, `description`). For the MVP, install repo-local copies under `.agents/skills/` so a target repo can use them without waiting for plugin packaging. Keep `SKILL.md` concise and move detailed lane references into `references/` if needed.
- `ganpan-triage`
- `ganpan-work-issue`
- `ganpan-review-queue`
- `ganpan-qa-check`
- `ganpan-setup`

**Implementation tasks:**
- [ ] Add a shared `resolve_config_path` helper in `lib.sh`; have `load_config` export `ORCH_CONFIG_PATH`.
- [ ] Add config discovery support for `.ganpan/orchestration.json` while preserving `.claude/orchestration.json`.
- [ ] Update `detect-test-cmd.sh` to read command overrides from `$ORCH_CONFIG_PATH`; the current script recomputes `cfg="${ORCH_CONFIG:-./.claude/orchestration.json}"`, which would miss `.ganpan/orchestration.json`.
- [ ] Add tests for config discovery order:
  - `$ORCH_CONFIG` wins.
  - `.ganpan/orchestration.json` is preferred for new installs.
  - `.claude/orchestration.json` remains a fallback.
- [ ] Add a regression test that `detect-test-cmd.sh` honors command overrides from `.ganpan/orchestration.json`.
- [ ] Create Codex skill files that mirror the existing Claude lane commands but remove Claude-specific assumptions:
  - replace `${CLAUDE_PLUGIN_ROOT}` with a Codex-compatible root strategy;
  - replace `/loop` and `/goal` language with explicit Codex task instructions;
  - avoid Codex custom prompts/slash-command files as the main distribution path;
  - require capturing `REPO_ROOT="$PWD"` before worktree changes;
  - use `ORCH_CONFIG="$REPO_ROOT/.ganpan/orchestration.json"` for new Codex installs, while documenting fallback to `.claude/orchestration.json`;
  - keep the untrusted-input warnings.
- [ ] Extract shared lane protocol references before duplicating prompts:
  - create shared reference files for triage, work-issue, review-queue, qa-check, and setup;
  - Claude commands and Codex skills should be thin wrappers over those references;
  - add a test or review checklist that lane status transitions remain identical across adapters.
- [ ] Add skill validation:
  - every skill has valid YAML frontmatter with `name` and `description`;
  - `SKILL.md` stays concise enough for progressive disclosure;
  - any long lane detail moves to `references/`;
  - validation runs in CI or in the documented release checklist.
- [ ] Add Codex-oriented setup instructions:
  - install prerequisites;
  - write `.ganpan/orchestration.json`;
  - install labels and issue template;
  - merge Ganpan conventions into `AGENTS.md` for Codex target repos;
  - print human-only security checklist.
- [ ] Create the Phase 1 canonical Codex adapter source at `plugins/ganpan-codex/skills/`.
- [ ] Install/copy skills into target repo `.agents/skills/ganpan-*` for immediate repo-local Codex use. No public marketplace claim until Phase 3.
- [ ] Extend `install.sh` with `--target claude|codex|both`:
  - preserve current behavior as the default Claude/copy-in install path;
  - `--target codex` performs Codex-only install and never writes `.claude/commands`;
  - `--target both` installs both surfaces without duplicating shared assets.
- [ ] In the Codex install path, copy:
  - skills to `.agents/skills/`;
  - Ganpan conventions to `AGENTS.md`;
  - config template to `.ganpan/orchestration.json`;
  - labels and issue template to `.github/`.
- [ ] Make the Codex installer re-runnable:
  - create `AGENTS.md` if absent, otherwise append a sentinel-guarded Ganpan block once;
  - create `.ganpan/orchestration.json` only if absent;
  - copy skills with version sentinels or another explicit upgrade strategy;
  - never rewrite existing `.claude/` files during a Codex-only install.
- [ ] Document Codex surface support for Phase 1:
  - local CLI and IDE are in scope;
  - Codex app/cloud is supported only after auth and shell prerequisite behavior is verified.
- [ ] Update docs to show Claude and Codex side by side without implying one is deprecated.
- [ ] Add lint/tests that check:
  - Codex skill artifacts do not contain Claude-only tokens;
  - Codex installer output does not clobber existing repo files on re-run;
  - setup/dry-run output does not print token values.

**Acceptance criteria:**
- Existing Claude tests still pass.
- A Codex CLI/IDE user can run each lane manually from a target repo using `.agents/skills/ganpan-*`.
- New Codex setup uses `.ganpan/orchestration.json`.
- Existing Claude setup using `.claude/orchestration.json` still works.
- README describes Codex support as MVP/skill-based, not final plugin distribution.
- `install.sh --target codex` is tested against a temporary target repo.
- `install.sh --target both` is tested against a temporary target repo and leaves both Claude and Codex surfaces usable.
- Re-running Codex setup is idempotent against a target repo with existing `AGENTS.md`, `.ganpan/orchestration.json`, `.github/labels.yml`, and `.github/ISSUE_TEMPLATE/task.yml`.

---

## Phase 2: Platform-Neutral CLI Runner (C)

**Goal:** Provide a stable deterministic execution surface independent of Claude Code slash commands or Codex skill invocation. This becomes the durable interface that both adapters can call for setup, queue inspection, status transitions, claim/reclaim/heartbeat, test command detection, and loop scheduling. It does not replace the agent reasoning required for implementation, code review, or QA interpretation.

**Primary deliverable:** a `ganpan` runner command or shell entrypoint that can execute orchestration primitives and prepare lane context once, and optionally loop deterministic checks with an interval.

**Candidate interface:**

```bash
ganpan setup owner/repo --bot bot-login
ganpan lane triage next
ganpan lane work-issue claim
ganpan lane review-queue list
ganpan lane qa-check list
ganpan lane review-queue mark-qa <issue> --pr <number>
ganpan lane qa-check mark-done <issue>
ganpan loop triage --every 10m
ganpan loop review-queue --every 5m
```

**Implementation tasks:**
- [ ] Decide whether the runner is Bash-only or a small portable CLI wrapper.
- [ ] Implement primitive entrypoints that call the existing engine and preserve current status transitions where the transition is deterministic.
- [ ] Implement state-changing primitives as lane-scoped commands, not a generic transition API:
  - `review-queue mark-qa` must verify the PR is merged before moving `in-review -> qa`;
  - `qa-check mark-done` must be called only after the agent has surfaced test results;
  - rework/block paths must keep bot-authored marker filtering.
- [ ] Keep agent-required work in Claude commands and Codex skills:
  - coding in `work-issue`;
  - review judgment in `review-queue`;
  - QA result interpretation in `qa-check`.
- [ ] Add deterministic exit codes for runner commands:
  - queue empty;
  - WIP exceeded;
  - lost claim race;
  - lane completed;
  - API/auth failure.
- [ ] Add tests for invalid transitions:
  - cannot move `agent-ready -> done`;
  - cannot move `in-review -> qa` without a merged PR;
  - cannot treat user-authored `rework-requested:` or `qa-fail-count:` comments as authoritative.
- [ ] Add machine-readable output for runner primitives, for example `--json`, so Claude commands and Codex skills do not parse human prose.
- [ ] Add a dry-run mode for public docs and setup verification:
  - check prerequisites;
  - show selected config path;
  - show repo/bot/project settings;
  - show GitHub auth status without printing secrets.
- [ ] Add primitive-level tests for secret safety:
  - `ganpan doctor`/dry-run must not print `GH_TOKEN`;
  - JSON output must not include full environment variables;
  - error messages should name missing prerequisites without dumping shell context.
- [ ] Move loop semantics out of Claude-only `/loop` docs and into runner docs.
- [ ] Update Claude commands to call or document the runner for deterministic primitives where appropriate while preserving existing plugin UX.
- [ ] Update Codex skills to prefer the runner once it exists.
- [ ] Ensure shared lane references remain the source of truth after runner adoption; do not fork separate Claude/Codex protocols.
- [ ] Add tests for runner argument parsing, config discovery, and no-op cases.

**Acceptance criteria:**
- Claude Code users can keep using `/ganpan:*`.
- Codex users can choose between skill-driven operation and direct runner invocation.
- Public docs have one canonical explanation of lane behavior, with Claude/Codex as adapters.
- Looping no longer depends on Claude Code-specific `/loop`.
- Invalid state transitions fail closed and leave GitHub labels unchanged.

---

## Phase 3: Codex Plugin Packaging (B)

**Goal:** Package Ganpan for public Codex distribution with the Codex-native install experience while keeping the skill and runner surfaces as reusable internals.

**Primary deliverable:** Codex plugin packaging that installs the Ganpan skills, setup assets, guidance, and optional runner integration.

**Implementation tasks:**
- [ ] Verify the current Codex plugin manifest schema against official Codex documentation before implementation.
- [ ] Add Codex plugin metadata:
  - `.codex-plugin/plugin.json` with strict semver, `name`, `version`, `description`, `author`, `skills`, and `interface` metadata;
  - omit manifest fields the validator rejects, even if older examples mention them.
- [ ] Add Codex marketplace/distribution files:
  - personal marketplace path for local testing: `~/.agents/plugins/marketplace.json`;
  - repo/team marketplace path for this repo if publishing from source: `.agents/plugins/marketplace.json`;
  - plugin source path is intended to be `./plugins/ganpan-codex`, but must be verified against Codex's current marketplace-root resolution before publishing; do not ship until `codex plugin marketplace add ./...` and `codex plugin list` prove it resolves correctly.
- [ ] Package the Phase 1 skills and Phase 2 runner as plugin assets.
- [ ] Package shared lane references in the plugin so Codex skills and future Claude prompt generation use the same protocol text.
- [ ] Add public install/upgrade docs for Codex plugin users.
- [ ] Add a Codex plugin validation step, using the current validator/scaffold flow available at implementation time.
- [ ] Add install/reinstall validation for local development:
  - install from the selected marketplace;
  - verify the plugin appears in `codex plugin list`;
  - start a fresh Codex thread/session before declaring updated skills available.
- [ ] Define versioning rules across:
  - core engine;
  - Claude plugin;
  - Codex plugin;
  - copy-in installer.
- [ ] Add packaging validation tests for both Claude and Codex manifests.
- [ ] Add release checklist for public distribution:
  - prerequisites;
  - GitHub token permissions;
  - branch protection requirements;
  - residual security risks;
  - upgrade path from Claude-only installs.

**Acceptance criteria:**
- Ganpan can be distributed publicly to Codex users.
- Claude Code plugin distribution remains intact.
- Copy-in install remains available for users who do not want either plugin system.
- Release docs clearly identify supported surfaces and maturity:
  - Claude Code plugin: first-class;
  - Codex skills/plugin: first-class after Phase 3;
  - CLI runner: shared deterministic primitive interface.

---

## Documentation Updates

- [ ] Change README framing from “Claude Code plugin” to “GitHub-native multi-agent orchestration toolkit for Claude Code and Codex.”
- [ ] Add a support matrix:

| Surface | Phase | Status | Primary UX |
|---|---:|---|---|
| Claude Code plugin | existing | first-class | `/ganpan:*` commands |
| Copy-in install | existing | first-class fallback | `.claude/commands` + scripts |
| Codex skills | Phase 1 | MVP then first-class | Codex skill invocation |
| CLI runner | Phase 2 | shared deterministic primitive interface | `ganpan lane ...` |
| Codex plugin | Phase 3 | public distribution | Codex plugin install |

- [ ] Split setup docs into common steps and surface-specific steps:
  - common GitHub setup;
  - Claude Code setup;
  - Codex skill setup;
  - CLI runner setup;
  - Codex plugin setup.
- [ ] Document Codex-specific surfaces:
  - `AGENTS.md` for durable repo guidance;
  - `.agents/skills/` for repo-local skills in Phase 1;
  - skill directories with required `SKILL.md`;
  - `.codex-plugin/plugin.json` for plugin packaging;
  - `.agents/plugins/marketplace.json` for repo/team marketplace distribution.
- [ ] Document unsupported or verification-pending surfaces explicitly, especially Codex app/cloud execution if GitHub auth, shell PATH, or `gh` availability has not been proven.
- [ ] Document installer idempotency and `--force` semantics for each surface.
- [ ] Document config path compatibility:
  - `.ganpan/orchestration.json` is the platform-neutral preferred path;
  - `.claude/orchestration.json` remains supported for existing Claude installs;
  - `$ORCH_CONFIG` is the explicit override.

---

## Open Questions Before Implementation

- [ ] What exact Codex plugin manifest fields are required at implementation time, and which fields does the active validator reject?
- [ ] Should repo-local Phase 1 skills be generated from canonical source files or copied verbatim with version sentinels during development?
- [ ] Should the CLI runner be pure Bash for minimum dependency footprint, or a small typed CLI for better UX and testing?
- [ ] Should `.claude/orchestration.json` eventually be migrated to `.ganpan/orchestration.json` for Claude users, or only supported indefinitely as a legacy path?
- [ ] What public versioning scheme should align Claude plugin, Codex plugin, and core engine releases?
- [ ] What is the minimum supported Codex surface for public claims: CLI only, CLI+IDE, or CLI+IDE+app after cloud auth verification?
