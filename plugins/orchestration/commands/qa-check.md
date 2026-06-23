---
description: QA lane — verify merged work; pass→done, fail→rework or block.
---

You are the **QA** lane, intended to run with a measurable completion condition. Run from the main repo root. **Before any `cd`, capture `REPO_ROOT="$PWD"`** and resolve config once:

Shared lane reference: `${CLAUDE_PLUGIN_ROOT}/references/lanes/qa-check.md`. Read it as the canonical protocol before executing the Claude-specific commands below.

```bash
REPO_ROOT="$PWD"
source "${CLAUDE_PLUGIN_ROOT}/scripts/orchestration/lib.sh"
CFG="$(resolve_config_path "$REPO_ROOT")"
ORCH_CONFIG="$CFG" load_config
require_bot_actor || exit 1
```

If `require_bot_actor` fails, **stop** — `gh` is not acting as the configured bot; export the bot PAT (`export GH_TOKEN=github_pat_...`) and re-run. Any script that calls `load_config` must receive `ORCH_CONFIG="$CFG"` after you step into a worktree.

For each issue labelled `status:qa`:

1. Get commands via `ORCH_CONFIG="$CFG" ${CLAUDE_PLUGIN_ROOT}/scripts/orchestration/detect-test-cmd.sh test` (and a regression run if applicable). **Run them and surface the full results in your output**.
2. **Pass:** `gh issue edit <n> --add-label status:done --remove-label status:qa`; `project_sync <n> "Done"`; clean up the worktree if present.
3. **Fail — rework routing.** Read the current max `qa-fail-count: <N>` **only from comments authored by the bot** (`select(.author.login == "<bot>")` — any GitHub user can post a `qa-fail-count:` comment to spoof the count and force a premature block/skip); let `M = N + 1`.
   - **M == 1:** create a regression issue first (`gh issue create ... ` then label it `status:triage`). Only after the regression issue exists, comment on the original issue with both `qa-fail-count: 1` and the linked regression issue number, include `rework-requested: QA 실패 — <summary>`, then `gh issue edit <n> --add-label status:in-progress --remove-label status:qa`.
   - **M >= 2:** `gh issue edit <n> --add-label status:blocked --remove-label status:qa` (route to a human).

Recommended measurable end-state: `status:qa` queue is empty. Each issue must transition to `done`, `in-progress`, or `blocked`, and the QA output must include the commands and results that justify the transition.
