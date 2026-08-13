# Ganpan Setup Lane

Run from the target repository root.

1. Verify prerequisites:
   ```bash
   command -v gh git jq yq
   gh auth status
   ```
2. Ensure a config exists. New Codex installs use `.ganpan/orchestration.json`. If only `.claude/orchestration.json` exists, use it as a legacy fallback and recommend deliberate migration.
3. Install `.github/labels.yml` and `.github/ISSUE_TEMPLATE/task.yml` only when absent.
4. Merge Ganpan conventions into the agent instructions file once — `CLAUDE.md` for the Claude Code surface, `AGENTS.md` for the Codex and Antigravity surfaces.
5. Bootstrap labels:
   ```bash
   scripts/orchestration/bootstrap-labels.sh .github/labels.yml
   ```
   This is idempotent (`gh label create --force` = create-or-update; it never deletes or renames), so it is safe to re-run. **Re-run it after every ganpan upgrade** — labels are bootstrapped only at setup, so a repo installed before a label was added never receives it, and the gap surfaces only when a lane's label write fails mid-run (#81).
6. Verify the label set matches the definitions (read-only; exits 1 and names the missing labels on drift):
   ```bash
   scripts/orchestration/labels-check.sh
   ```
7. Surface the private-repo auto-merge advisory before printing the human checklist (read-only; exit 1 means the advisory applies, **not** that setup failed):
   ```bash
   scripts/orchestration/visibility-check.sh || true
   ```
   On a public repo it prints `OK`. On a private repo it prints an `ADVISORY`: under GitHub Free the branch-protection API always returns `403 "Upgrade to GitHub Pro or make this repository public…"`, so `auto-merge.sh` fails closed forever and passing PRs sit in `status:in-review` (#72). Relay its output verbatim — including the three fixes (make public / upgrade to Pro/Team / opt in with `reviewer.autoMergePrivatePlanWorkaround: true`). Never set that flag on the human's behalf; it is their explicit acceptance that a Free private repo cannot have branch protection.
8. Tell the human to create a bot account, provision a fine-grained GitHub token with required repo permissions, add the bot as collaborator, and enforce branch protection requiring human review.

Never create secrets, print token values, or change branch protection automatically.
