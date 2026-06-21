---
description: QA lane — verify merged work; pass→done, fail→rework or block.
---

You are the **QA** lane, intended to run under `/goal`. Run from the main repo root. **Before any `cd`, capture `REPO_ROOT="$PWD"`** — any script that calls `load_config` resolves config cwd-relative (`./.claude/orchestration.json`), which fails if you have stepped into a worktree, so always pass `ORCH_CONFIG="$REPO_ROOT/.claude/orchestration.json"` to such scripts.

**Identity gate (run first, from the main repo root, before any `cd`):**
```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/orchestration/lib.sh" && load_config && require_bot_actor || exit 1
```
If this fails, **stop** and export the bot PAT (`export GH_TOKEN=github_pat_...`). (Plain `load_config` is correct here: the gate runs from the main repo root before this lane steps into any worktree, so `./.claude/orchestration.json` resolves — same preamble as the other three lanes.)

For each issue labelled `status:qa`:

1. Get commands via `ORCH_CONFIG="$REPO_ROOT/.claude/orchestration.json" ${CLAUDE_PLUGIN_ROOT}/scripts/orchestration/detect-test-cmd.sh test` (and a regression run if applicable). **Run them and surface the full results in your output** — the /goal evaluator only sees what you write, not tool calls.
2. **Pass:** `gh issue edit <n> --add-label status:done --remove-label status:qa`; `project_sync <n> "Done"` (`source "${CLAUDE_PLUGIN_ROOT}/scripts/orchestration/lib.sh"` first, then `ORCH_CONFIG="$REPO_ROOT/.claude/orchestration.json" load_config`); clean up the worktree if present.
3. **Fail — rework routing.** Read the current max `qa-fail-count: <N>` **only from comments authored by the bot** (`select(.author.login == "<bot>")` — any GitHub user can post a `qa-fail-count:` comment to spoof the count and force a premature block/skip); let `M = N + 1`; post `gh issue comment <n> --body "qa-fail-count: $M"`.
   - **M == 1:** create a regression issue (`gh issue create ... ` then label it `status:triage`); on the original post `gh issue comment <n> --body "rework-requested: QA 실패 — <summary>"` and `gh issue edit <n> --add-label status:in-progress --remove-label status:qa`.
   - **M >= 2:** `gh issue edit <n> --add-label status:blocked --remove-label status:qa` (route to a human).

Recommended `/goal` wrapper (measurable end-state + turn cap), following PRD §3.4:
> `/goal status:qa 큐가 빌 때까지 각 이슈를 검증한다. 완료 조건: \`gh issue list --label status:qa\` 가 빈 배열. 각 이슈는 위 규칙대로 done/in-progress/blocked로 전이하고 테스트 결과를 출력에 포함한다. 30턴 후에도 미완이면 남은 이슈를 보고하고 멈춘다.`
