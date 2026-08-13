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
7. Tell the human to create a bot account, provision a fine-grained GitHub token with required repo permissions, add the bot as collaborator, and enforce branch protection requiring human review.

Never create secrets, print token values, or change branch protection automatically.
