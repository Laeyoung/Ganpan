# Ganpan — Claude Code plugin distributing a GitHub orchestration toolkit

Plugin `ganpan` in marketplace `laeyoung` (install ref `ganpan@laeyoung`).
Commands namespace as `/ganpan:*`. Single source of truth lives under
`plugins/orchestration/`; the repo root is also a plugin marketplace.

## Development
```bash
bats tests/orchestration/ tests/install.bats   # full test suite
shellcheck plugins/orchestration/scripts/orchestration/*.sh
jq . .claude-plugin/marketplace.json plugins/orchestration/.claude-plugin/plugin.json  # validate manifests
```

## Layout
- `plugins/orchestration/commands/` — lane commands (triage, work-issue, review-queue, qa-check, orch-setup).
- `plugins/orchestration/scripts/orchestration/` — engine shell scripts.
- `plugins/orchestration/assets/` — files copied into target repos (config template, labels, issue template, CLAUDE.md).
- `install.sh` — copy-in install path (rewrites `${CLAUDE_PLUGIN_ROOT}/` → `./`).

## Gotchas
- **Never rename engine internals** (`scripts/orchestration/`, the `.claude/orchestration.json` config filename, the `ganpan-orchestration` version sentinel) — they are the deployed runtime contract, decoupled from the plugin name.
- Lane commands call scripts via `${CLAUDE_PLUGIN_ROOT}/scripts/orchestration/…`; config discovery is **cwd-relative** (`./.claude/orchestration.json`).
- Inside a worktree there is no `.claude/`, so pass `ORCH_CONFIG="$REPO_ROOT/.claude/orchestration.json"` to any script that calls `load_config` (capture `REPO_ROOT="$PWD"` before any `cd`).
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
