# Orchestration v1 — one-time setup

## Prerequisites
`gh`, `git`, `jq`, `yq`, `bats` (for tests). Verify: `command -v gh jq yq git bats`.

## Steps
1. **Bot account + Fine-grained PAT.** Permissions on the target repo only: Contents RW, Pull requests RW, Issues RW, Projects RW. Expiry 90d. Export `GH_TOKEN=github_pat_...` (do not use `--with-token`). Use HTTPS (`gh auth` over ssh breaks fine-grained tokens).
2. **Add the bot as a collaborator** on the target repo.
3. **Edit `.claude/orchestration.json`**: set `repo`, `bot`, and (optionally) `project.number`.
4. **Bootstrap labels:** `scripts/orchestration/bootstrap-labels.sh .github/labels.yml`.
5. **(Optional) GitHub Project:** create it, set `project.number`; otherwise leave `null` (sync becomes a no-op).
6. **Branch protection on `main`:** require 1 human review (or CODEOWNERS), no force-push, no direct push, **include administrators**, restrict review dismissal. Bot token must **not** be admin.
7. **Issue template** is already at `.github/ISSUE_TEMPLATE/task.yml` (auto-labels new issues `status:triage`).
8. **Worktree dependency strategy.** Decide how per-issue worktrees share dependencies (e.g. symlink `node_modules`/`.venv` from the main checkout vs reinstall per worktree). For Node, symlinking the gitignored `node_modules` into each `wt-issue-*` avoids re-install; pick the equivalent for the target repo's toolchain (spec §7.4 step 7 / §12 — repo-specific, decide here).

## Run the lanes (separate terminals)
- Triager: `/loop 10m /triage`
- Coder:   `/loop /work-issue`
- Reviewer:`/loop 5m /review-queue`
- QA:      `/goal` wrapping `/qa-check` (see `.claude/commands/qa-check.md`)

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
