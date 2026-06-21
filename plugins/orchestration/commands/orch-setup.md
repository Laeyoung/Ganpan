---
description: One-time setup — write config, install labels/issue-template, bootstrap labels, then print the human checklist.
---

You are the **Setup** lane. Run from the **target repo root** (cwd = the repo you want to orchestrate). Optional argument: `owner/repo` (and a bot login). All source paths are absolute under `${CLAUDE_PLUGIN_ROOT}/assets/...` — never bare relative, because cwd is the target repo, not the plugin dir.

Do exactly this:

1. **Prerequisite check.** Verify tooling and auth; stop (do nothing else) if any is missing:
   ```bash
   command -v gh jq yq || { echo "missing prerequisite (need gh, jq, yq)"; exit 1; }
   gh auth status || { echo "gh not authenticated — run: GH_TOKEN=... or gh auth login"; exit 1; }
   actor=$(gh api user --jq .login 2>/dev/null)
   echo "ⓘ gh is currently acting as: ${actor:-<unknown>}"
   echo "  After creating the bot PAT, run lanes with:  export GH_TOKEN=github_pat_..."
   echo "  (must resolve to the bot account — NOT '${actor:-your personal login}')"
   ```
2. **Config (guarded — binary, per spec §3.4).** If `./.claude/orchestration.json` already exists, **leave it untouched and report**. Only when it is absent: copy the template and fill `repo`/`bot` (from the `owner/repo` argument or by asking) — both happen inside the same absent-branch, so an existing config is never rewritten:
   ```bash
   mkdir -p .claude
   if [ -f .claude/orchestration.json ]; then
     echo ".claude/orchestration.json exists — left untouched"
   else
     cp "${CLAUDE_PLUGIN_ROOT}/assets/orchestration.json" .claude/orchestration.json
     tmp=$(mktemp); jq --arg r "owner/repo" --arg b "bot-login" '.repo=$r | .bot=$b' \
       .claude/orchestration.json > "$tmp" && mv "$tmp" .claude/orchestration.json
     echo "wrote .claude/orchestration.json (repo=owner/repo bot=bot-login)"
   fi
   ```
3. **Assets (guarded "if absent").** Install labels + issue template only when the destination is absent, so a re-run never clobbers user customizations:
   ```bash
   mkdir -p .github/ISSUE_TEMPLATE
   [ -f .github/labels.yml ] || cp "${CLAUDE_PLUGIN_ROOT}/assets/labels.yml" .github/labels.yml
   [ -f .github/ISSUE_TEMPLATE/task.yml ] || cp "${CLAUDE_PLUGIN_ROOT}/assets/task.yml" .github/ISSUE_TEMPLATE/task.yml
   ```
   Merge the conventions block into `CLAUDE.md` once, guarded by a sentinel (do nothing if already present):
   ```bash
   SENT='<!-- orchestration-conventions -->'
   if [ ! -f CLAUDE.md ]; then printf '%s\n' "$SENT" > CLAUDE.md; cat "${CLAUDE_PLUGIN_ROOT}/assets/CLAUDE.md" >> CLAUDE.md;
   elif ! grep -qF "$SENT" CLAUDE.md; then printf '\n%s\n' "$SENT" >> CLAUDE.md; cat "${CLAUDE_PLUGIN_ROOT}/assets/CLAUDE.md" >> CLAUDE.md; fi
   ```
4. **Label bootstrap (always runs — NOT guarded).** This runs on every invocation so a re-run after an earlier auth failure still converges:
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/orchestration/bootstrap-labels.sh" .github/labels.yml \
     || { echo "setup incomplete — label bootstrap failed; fix gh auth and re-run /orch-setup"; exit 1; }
   ```
5. **Manual-steps checklist (print — do NOT attempt to automate).** Tell the human to:
   - Create a **bot account + fine-grained PAT** scoped to the target repo: Contents RW, Pull requests RW, Issues RW, Projects RW; export `GH_TOKEN=github_pat_...` (HTTPS, not ssh). **This is a runtime precondition, not a recommendation** — every lane verifies `gh` is acting as `config.bot` at startup and hard-stops on mismatch.
   - **Add the bot as a collaborator** on the repo.
   - **Branch protection on `main`:** require 1 human review (or CODEOWNERS), no force-push, include administrators; the bot must **not** be an admin.
6. **Verify (optional).** Confirm labels exist and echo the lane-run commands:
   ```bash
   gh label list --repo "$(jq -r .repo .claude/orchestration.json)" | grep -c '^status:' || true
   ```
   Then print: Triager `/loop 10m /triage` · Coder `/loop /work-issue` · Reviewer `/loop 5m /review-queue` · QA `/qa-check` (under `/goal`).

Never create the PAT or change branch protection yourself — those are human, security-sensitive actions.
