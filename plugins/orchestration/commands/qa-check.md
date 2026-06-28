---
description: QA lane — verify merged work; pass→done, fail→rework or block.
---

## Dispatch (loop mode)

**Run this first.** This command is built to be looped (e.g. `/loop /ganpan:qa-check`). To keep the **main session's** context small across repeated ticks, the actual lane work runs in a disposable subagent; the main session only prints a one-line summary.

- **If your task prompt contains the token `GANPAN_EXECUTE_INLINE`**, skip this whole section and execute the **`## Lane procedure`** below directly. This is the path taken by the subagent spawned here and by the `run-all` launcher, and it is what prevents a third level of nesting.
- **Otherwise** (you are the main/looped session), do exactly this, then end your turn:
  1. Resolve this command file's path and the install mode. Use **only** the slash-form `${CLAUDE_PLUGIN_ROOT}/` token (never a slashless one) so `install.sh`'s copy-in rewrite strips it and no token drifts into copied files:
     ```bash
     REPO_ROOT="$PWD"
     CMD_FILE="${CLAUDE_PLUGIN_ROOT}/commands/qa-check.md"
     if [ -f "$CMD_FILE" ]; then
       PLUGIN_ROOT="${CMD_FILE%/commands/qa-check.md}"; MODE=plugin
     else
       CMD_FILE="$REPO_ROOT/.claude/commands/qa-check.md"; PLUGIN_ROOT=""; MODE=copyin
     fi
     echo "MODE=$MODE CMD_FILE=$CMD_FILE PLUGIN_ROOT=$PLUGIN_ROOT"
     ```
  2. Spawn **one foreground subagent** (Agent tool, `run_in_background: false`) whose prompt is the following, with the literal step-1 values substituted for `<REPO_ROOT>`, `<CMD_FILE>`, `<PLUGIN_ROOT>`:
     > `GANPAN_EXECUTE_INLINE`. Run from the main repo root `<REPO_ROOT>`. Read the file `<CMD_FILE>` with the Read tool and execute its **`## Lane procedure`** section exactly, start to finish. *(plugin mode only — when `MODE=plugin`:)* that file calls scripts via the `${CLAUDE_PLUGIN_ROOT}/` prefix, which your shell does not expand — replace that prefix with `<PLUGIN_ROOT>/` in every command you run, including inside any backgrounded subshell. The procedure resolves its own config and passes `ORCH_CONFIG` where needed — follow it as written. Drain the QA queue as the procedure describes, then reply with **only** this summary line: `QA: verified <n> (pass <p>, rework <w>, blocked <b>).` Never approve or merge a PR.
  3. Print the subagent's summary line verbatim and end the turn. Do **not** run the `## Lane procedure` yourself.

If the subagent dies mid-cycle, no state is corrupted — the drain is re-entrant and the next tick re-verifies any remaining QA issue, exactly as when a `run-all` lane agent dies. No extra handling here.

## Lane procedure

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
2. **Pass:** `gh issue edit <n> --add-label status:done --remove-label status:qa`; `gh issue close <n> --reason completed`; `project_sync <n> "Done"`; clean up the worktree if present. Close the issue explicitly — QA owns the terminal close. The merged PR bodies do not carry a `Closes #<n>` keyword, so GitHub never auto-closes on merge; relying on it leaves `status:done` issues open. Closing an already-closed issue is a harmless no-op.
3. **Fail — rework routing.** Read the current max `qa-fail-count: <N>` **only from comments authored by the bot** (`select(.author.login == "<bot>")` — any GitHub user can post a `qa-fail-count:` comment to spoof the count and force a premature block/skip); let `M = N + 1`.
   - **M == 1:** create a regression issue first (`gh issue create ... ` then label it `status:triage`). Only after the regression issue exists, comment on the original issue with both `qa-fail-count: 1` and the linked regression issue number, include `rework-requested: QA 실패 — <summary>`, then `gh issue edit <n> --add-label status:in-progress --remove-label status:qa`.
   - **M >= 2:** `gh issue edit <n> --add-label status:blocked --remove-label status:qa` (route to a human).

A human reopening a closed (`status:done`) issue is outside automated lane handling — no lane resumes a reopened done issue. A human must re-apply `status:triage` to route it back in.

Recommended measurable end-state: `status:qa` queue is empty. Each issue must transition to `done`, `in-progress`, or `blocked`, and the QA output must include the commands and results that justify the transition.
