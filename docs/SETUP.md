# Ganpan orchestration — one-time setup

## Prerequisites
`gh`, `git`, `jq`, `yq`, `bats` (for tests). Verify: `command -v gh jq yq git bats`.

## Install (plugin — recommended)
1. `/plugin marketplace add Laeyoung/Ganpan`
2. Install the `ganpan` plugin (from the `laeyoung` marketplace).
3. In the target repo, run `/orch-setup owner/repo` — it checks prerequisites,
   writes `.claude/orchestration.json`, installs `.github/labels.yml` + the issue
   template, merges the CLAUDE.md conventions, and bootstraps labels.
4. Complete the human checklist `/orch-setup` prints (bot PAT, collaborator,
   branch protection).

## Install (copy-in — alternative)
Run `./install.sh <target-repo-path>` from a ganpan checkout. By default this
installs the Claude copy-in surface. Then complete the same human checklist
below.

## Install (Codex repo-local skills — Phase 1 MVP)
Run:

```bash
./install.sh <target-repo-path> --target codex
```

This installs `.agents/skills/ganpan-*`, `AGENTS.md` conventions,
`scripts/orchestration/*.sh`, GitHub labels/templates, and a new
`.ganpan/orchestration.json` only when no existing Ganpan config exists. If the
target already has only `.claude/orchestration.json`, Ganpan keeps using that
legacy fallback and does not silently create a second config.

To install both Claude and Codex surfaces:

```bash
./install.sh <target-repo-path> --target both
```

New `--target both` installs create `.ganpan/orchestration.json` and do not
create `.claude/orchestration.json` unless a legacy config already exists.

For detailed Codex operation, see [CODEX_RUNBOOK.md](CODEX_RUNBOOK.md).

### Upgrading a copy-in install
`install.sh` re-run upgrades files whose version sentinel differs. **v1 files
predate the sentinel**, so the first upgrade off a v1 copy must use
`./install.sh <target> --force` (overwrite + stamp regardless), or delete the
old generated surface files first. Subsequent upgrades are automatic.

## Steps
1. **Bot account + Fine-grained PAT.** Permissions on the target repo only: Contents RW, Pull requests RW, Issues RW, Projects RW. Expiry 90d. Export `GH_TOKEN=github_pat_...` (do not use `--with-token`). Use HTTPS (`gh auth` over ssh breaks fine-grained tokens).
2. **Add the bot as a collaborator** on the target repo.
3. **Config:** discovery order is `$ORCH_CONFIG`, `.ganpan/orchestration.json`, then `.claude/orchestration.json`. `/orch-setup` (Claude plugin) writes the Claude config path. `install.sh --target codex` writes `.ganpan/orchestration.json` for new installs. `install.sh` only drops a **template** if no config exists — you must then manually edit it to set `repo`, `bot`, and (optionally) `project.number`.
4. **Labels** are bootstrapped by `/orch-setup`. For the copy-in path run `scripts/orchestration/bootstrap-labels.sh .github/labels.yml`.
5. **(Optional) GitHub Project:** create it, set `project.number`; otherwise leave `null` (sync becomes a no-op).
6. **Branch protection on `main`:** require 1 human review (or CODEOWNERS), no force-push, no direct push, **include administrators**, restrict review dismissal. Bot token must **not** be admin.
7. **Issue template** is already at `.github/ISSUE_TEMPLATE/task.yml` (auto-labels new issues `status:triage`).
8. **Worktree dependency strategy.** Decide how per-issue worktrees share dependencies (e.g. symlink `node_modules`/`.venv` from the main checkout vs reinstall per worktree). For Node, symlinking the gitignored `node_modules` into each `wt-issue-*` avoids re-install; pick the equivalent for the target repo's toolchain (spec §7.4 step 7 / §12 — repo-specific, decide here).

## Run the lanes (separate terminals)
- Triager: `/loop 10m /triage`
- Coder:   `/loop /work-issue`
- Reviewer:`/loop 5m /review-queue`
- QA:      `/goal` wrapping `/qa-check` (see `.claude/commands/qa-check.md`)

For Codex repo-local skills, invoke the matching skill in the target repo:
`ganpan-triage`, `ganpan-work-issue`, `ganpan-review-queue`, or
`ganpan-qa-check`. Codex CLI/IDE support is the Phase 1 public surface; hosted
or cloud-like Codex execution should not be assumed until `gh`, PATH, workspace,
and secret provisioning behavior are verified for that environment.

## Support matrix

| Surface | Status | Primary UX |
|---|---|---|
| Claude Code plugin | first-class | `/ganpan:*` commands |
| Copy-in Claude install | first-class fallback | `.claude/commands` + scripts |
| Codex repo-local skills | Phase 1 MVP | `.agents/skills/ganpan-*` |
| CLI runner | planned | `ganpan lane ...` |
| Codex plugin | planned | Codex plugin install |

## Integration smoke test (manual)
1. Open an issue (gets `status:triage`).
2. Run `/triage` once → issue becomes `status:agent-ready`.
3. Run `/work-issue` once → issue `status:in-progress` then `status:in-review` with a PR.
4. Approve & merge the PR as a human → run `/review-queue` → issue `status:qa`.
5. Run `/qa-check` → issue `status:done` (or rework/blocked on failure).

## Known residual risks
- Bot token retains Projects:write (broader blast radius) — accepted trade-off for live board sync.
- Single bot identity → self-approval is blocked only by branch protection, not token separation.
- A bot with Contents:write can force-push/delete non-`main` branches.
