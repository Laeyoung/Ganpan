# Codex Runbook

This runbook explains how to install and run Ganpan from Codex using the Phase 1 repo-local skills path.

## Scope

Use this path when you want Codex CLI or a Codex IDE surface to operate Ganpan lanes from a target repository.

This is not the future Codex plugin distribution path. Phase 1 installs skills directly into the target repo under `.agents/skills/ganpan-*`.

## Prerequisites

Run these from your shell:

```bash
command -v gh git jq yq
gh auth status
```

Ganpan expects:

- `gh`, `git`, `jq`, and `yq` on PATH.
- GitHub CLI authenticated for the target repo.
- A bot GitHub account or bot login available in config.
- Repository permissions for Issues, Pull requests, and Contents read/write.
- Projects read/write only if `project.number` is not `null`.

For local Codex, credentials can come from local `gh` auth or an exported `GH_TOKEN`.

Do not paste token values into Codex prompts, GitHub issues, PR bodies, logs, or generated comments.

## Install

From a Ganpan checkout:

```bash
./install.sh /path/to/target-repo --target codex
```

For a repo that should support both Claude Code and Codex:

```bash
./install.sh /path/to/target-repo --target both
```

Antigravity CLI (agy) reads the same `.agents/skills/ganpan-*` payload — `--target antigravity` installs it identically, and this runbook applies unchanged.

The Codex target installs:

- `.agents/skills/ganpan-*`
- `AGENTS.md` with Ganpan conventions
- `scripts/orchestration/*.sh`
- `references/lanes/*.md`
- `.github/labels.yml`
- `.github/ISSUE_TEMPLATE/task.yml`
- `.ganpan/orchestration.json` only when no Ganpan config exists

If the target already has only `.claude/orchestration.json`, Ganpan uses that legacy fallback and does not create a second config automatically.

## Configure

Open the config path printed by `install.sh`.

For a new Codex install, this is usually:

```bash
.ganpan/orchestration.json
```

Set at least:

```json
{
  "repo": "owner/repo",
  "bot": "bot-login"
}
```

Config discovery order is:

1. `$ORCH_CONFIG`
2. `.ganpan/orchestration.json`
3. `.claude/orchestration.json`

If both `.ganpan/orchestration.json` and `.claude/orchestration.json` exist, `.ganpan/orchestration.json` wins. If they differ, reconcile them deliberately; Ganpan will not merge them.

## Bootstrap GitHub Labels

From the target repo:

```bash
scripts/orchestration/bootstrap-labels.sh .github/labels.yml
```

The issue template at `.github/ISSUE_TEMPLATE/task.yml` labels new tasks with `status:triage`.

## Human Security Checklist

Complete these before running autonomous lanes:

1. Create or choose the bot GitHub account.
2. Provision a fine-grained token for the target repo.
3. Give the token Contents, Pull requests, and Issues read/write.
4. Add Projects read/write only when `project.number` is configured.
5. Add the bot as a collaborator.
6. Protect `main`: require at least one human review, prevent force pushes, and do not make the bot an admin.
7. Decide how issue worktrees share dependencies, such as symlinking `node_modules` or using per-worktree installs.

Agents must never approve or merge PRs. A human owns the merge gate.

## Verify The Install

From the target repo:

```bash
test -f .agents/skills/ganpan-work-issue/SKILL.md
test -f .agents/skills/ganpan-work-issue/references/work-issue.md
test -f .agents/skills/ganpan-work-issue/agents/openai.yaml
test -x scripts/orchestration/detect-test-cmd.sh
```

Check config resolution:

```bash
bash -c 'source scripts/orchestration/lib.sh; load_config; echo "$ORCH_CONFIG_PATH|$REPO|$BOT"'
```

Check command detection:

```bash
scripts/orchestration/detect-test-cmd.sh test
scripts/orchestration/detect-test-cmd.sh build
scripts/orchestration/detect-test-cmd.sh lint
```

Empty output means Ganpan did not detect that command. Set an explicit command in config:

```json
{
  "commands": {
    "test": "npm test",
    "build": "npm run build",
    "lint": "npm run lint"
  }
}
```

## Run Lanes From Codex

Open Codex in the target repo. Ask Codex to use the installed Ganpan skill for the lane you want.

Recommended lane prompts:

```text
Use the ganpan-triage skill. Run one triage pass, then report which issues moved to agent-ready or blocked.
```

```text
Use the ganpan-work-issue skill. Claim one agent-ready issue, implement it in a worktree, run the detected checks, open a PR, and move the issue to in-review.
```

```text
Use the ganpan-review-queue skill. Review in-review PRs, request rework when needed, and only move merged PRs to qa. Do not approve or merge.
```

```text
Use the ganpan-qa-check skill. Verify qa issues, include command output evidence, and route each issue to done, in-progress, or blocked.
```

```text
Use the ganpan-setup skill. Check Ganpan prerequisites and report any missing setup without printing secrets.
```

## Operating Model

Run lanes in this order for a full smoke test:

1. Create a GitHub issue. It should start at `status:triage`.
2. Run `ganpan-triage`. The issue should move to `status:agent-ready` or `status:blocked`.
3. Run `ganpan-work-issue`. Codex should claim the issue, create `issue-<n>`, work in `wt-issue-<n>`, open a PR, and move the issue to `status:in-review`.
4. A human reviews and merges the PR.
5. Run `ganpan-review-queue`. The issue should move to `status:qa`.
6. Run `ganpan-qa-check`. The issue should move to `status:done`, or route to rework/block with evidence.

## Troubleshooting

### Codex does not see the skills

Confirm the files exist:

```bash
find .agents/skills -maxdepth 3 -type f | sort
```

Start a fresh Codex thread after installing or updating skills. Codex may not reload skill changes in an existing session.

### Config not found

Run:

```bash
bash -c 'source scripts/orchestration/lib.sh; resolve_config_path'
```

Create `.ganpan/orchestration.json`, or set `ORCH_CONFIG` to an explicit file path:

```bash
export ORCH_CONFIG=/path/to/orchestration.json
```

### GitHub commands fail

Check:

```bash
gh auth status
gh repo view owner/repo
```

Do not print token values while debugging. Confirm presence and scopes at a coarse level only.

### Labels are missing

Run:

```bash
scripts/orchestration/bootstrap-labels.sh .github/labels.yml
gh label list --repo "$(jq -r .repo .ganpan/orchestration.json 2>/dev/null || jq -r .repo .claude/orchestration.json)"
```

### Worktree commands fail

Confirm `worktreeBaseDir` in config points somewhere writable:

```bash
jq -r .worktreeBaseDir .ganpan/orchestration.json
```

The work issue lane captures `REPO_ROOT="$PWD"` before entering a worktree and passes the selected config through `ORCH_CONFIG`. Do not replace that with `git rev-parse --show-toplevel` from inside the worktree.

### Existing Claude installs

If only `.claude/orchestration.json` exists, Codex uses it as a legacy fallback. To migrate:

```bash
mkdir -p .ganpan
cp .claude/orchestration.json .ganpan/orchestration.json
```

Review both files before keeping both. If they differ, `.ganpan/orchestration.json` wins.

## Upgrade

Re-run the installer from a newer Ganpan checkout:

```bash
./install.sh /path/to/target-repo --target codex
```

Files with Ganpan version sentinels are updated when their version differs. User-owned files without sentinels are skipped unless you pass `--force`.

Use `--force` only after reviewing local edits:

```bash
./install.sh /path/to/target-repo --target codex --force
```

