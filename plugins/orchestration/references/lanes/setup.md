# Ganpan Setup Lane

Run from the target repository root.

1. Verify prerequisites:
   ```bash
   command -v gh git jq yq
   gh auth status
   ```
2. Ensure a config exists. New Codex installs use `.ganpan/orchestration.json`. If only `.claude/orchestration.json` exists, use it as a legacy fallback and recommend deliberate migration.
3. Install `.github/labels.yml` and `.github/ISSUE_TEMPLATE/task.yml` only when absent.
4. Merge Ganpan conventions into the agent instructions file once — `CLAUDE.md` for the Claude Code surface, `AGENTS.md` for the Codex surface.
5. Bootstrap labels:
   ```bash
   scripts/orchestration/bootstrap-labels.sh .github/labels.yml
   ```
6. Tell the human to create a bot account, provision a fine-grained GitHub token with required repo permissions, add the bot as collaborator, and enforce branch protection requiring human review.

Never create secrets, print token values, or change branch protection automatically.
