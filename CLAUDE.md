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
- `plugins/orchestration/commands/` — Claude lane commands (triage, work-issue, review-queue, qa-check, orch-setup).
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
