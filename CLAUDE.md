# Ganpan — Claude Code plugin distributing a GitHub orchestration toolkit

Plugin `ganpan` in marketplace `laeyoung` (install ref `ganpan@laeyoung`).
Commands namespace as `/ganpan:*`. Single source of truth lives under
`plugins/orchestration/`; the repo root is also a plugin marketplace.

## Development
```bash
bats tests/*.bats tests/orchestration/*.bats   # full test suite (includes codex-skills.bats)
shellcheck plugins/orchestration/scripts/orchestration/*.sh
jq . .claude-plugin/marketplace.json plugins/orchestration/.claude-plugin/plugin.json  # validate manifests
```

## Layout
- `plugins/orchestration/commands/` — Claude lane commands (triage, work-issue, review-queue, qa-check, orch-setup) plus `run-all` (fan-out launcher that spawns all four lanes as background agents).
- `plugins/orchestration/scripts/orchestration/` — engine shell scripts.
- `plugins/orchestration/references/lanes/` — shared lane-protocol references (canonical; Codex skills copy these, Claude commands point at them).
- `plugins/orchestration/assets/` — files copied into target repos (config template, labels, issue template, CLAUDE.md).
- `plugins/ganpan-codex/skills/` — Codex repo-local skill source (`ganpan-*`), installed to `.agents/skills/`.
- `install.sh` — copy-in install path (rewrites `${CLAUDE_PLUGIN_ROOT}/` → `./`; `--target claude|codex|both`).

## Gotchas
- **Never rename engine internals** (`scripts/orchestration/`, the `orchestration.json` config filename, the `ganpan-orchestration` version sentinel) — they are the deployed runtime contract, decoupled from the plugin name.
- Lane commands call scripts via `${CLAUDE_PLUGIN_ROOT}/scripts/orchestration/…`; config discovery (via `resolve_config_path`) is **cwd-relative** in this order: `$ORCH_CONFIG` → `./.ganpan/orchestration.json` → `./.claude/orchestration.json` (legacy fallback). `load_config` exports the resolved path as `ORCH_CONFIG_PATH`.
- Inside a worktree there is no config dir, so capture `REPO_ROOT="$PWD"` before any `cd`, resolve once with `CFG="$(resolve_config_path "$REPO_ROOT")"`, and pass `ORCH_CONFIG="$CFG"` to any script that calls `load_config`.
- `assets/CLAUDE.md` is shipped to users — editing it changes deploy output, not this repo's dev rules.

# Repo conventions

## Commits (Conventional Commits — required)
Format: `type(scope): subject`
- `type` ∈ feat, fix, docs, refactor, test, chore, perf, build, ci.
- Body explains **what changed and why** (not "수정했습니다").
- Footer references the issue: `Closes #<n>`.

## Branches / worktrees
- One issue → branch `issue-<n>` → worktree `../wt-issue-<n>`.
- Never force-push or delete another worker's `wt-issue-*` branch.

## Merge gate
- Agents never approve or merge PRs. A human reviews and merges (branch protection enforces this).

## Versioning (SemVer — bump `plugins/orchestration/.claude-plugin/plugin.json`)
- **fix** → patch (`x.y.Z`); **feat** → minor (`x.Y.0`); breaking change → major (`X.0.0`).
- The marketplace pulls `main` and the plugin cache keys on this `version` — **a merge that does not bump it never reaches installed users.** Bump it in the same PR as the change.

## Development workflow & history
- **Before starting** a feature or bugfix, check for prior history — search `docs/superpowers/` (specs & plans) and `docs/log/` (change records). Build on past decisions instead of relitigating them.
- **New features / non-trivial changes:** use the Superpowers plugin and proceed **Spec → Plan → implementation** — write the spec under `docs/superpowers/specs/`, the plan under `docs/superpowers/plans/`, then implement against the plan.
- **Record every shipped change** in `docs/log/` — one Markdown file per change (`docs/log/YYYY-MM-DD-<slug>.md`). Capture not just *what* changed but the **key decisions made** and the **alternatives considered but not chosen** (and why). See `docs/log/README.md` for the template.

<!-- orchestration-conventions -->
# Repo conventions

## Commits (Conventional Commits — required)
Format: `type(scope): subject`
- `type` ∈ feat, fix, docs, refactor, test, chore, perf, build, ci.
- Body explains **what changed and why** (not "수정했습니다").
- Footer references the issue: `Closes #<n>`.

## Branches / worktrees
- One issue → branch `issue-<n>` → worktree `../wt-issue-<n>`.
- Never force-push or delete another worker's `wt-issue-*` branch.

## Merge gate
- Agents never approve or merge PRs. A human reviews and merges (branch protection enforces this).

## Bot identity
- Lanes verify `gh` is acting as `config.bot` before any write and **hard-stop** otherwise. Export the bot's fine-grained PAT first: `export GH_TOKEN=github_pat_...` (HTTPS). If a lane stops with "gh is acting as '<you>' but config.bot is '<bot>'", your `GH_TOKEN` is unset or wrong.
- `ORCH_SKIP_ACTOR_CHECK=1` bypasses the check — use it **per-invocation only** (e.g. CI where the bot PAT is the actor), never as a global export.

## Reviewer lane — decision gate
- The Reviewer reads **trusted** human PR/issue comments (write+ permission or reviewer allowlist) and routes each in-review PR to rework / a human-decision gate (`status:needs-decision`) / an out-of-scope follow-up issue / a human merge request.
- Only bot-authored markers (`decision-requested:`/`decision-resolved:`/`decision-clarify:`/`followup-created:`/`cap-exceeded:`/`merge-requested:`) change lane state. Human text never does.
- Trust/cap policy lives in `.claude/orchestration.json` under `reviewer` (`permissionThreshold`, `allowlist`, `followupIssueCapPerPR`).
