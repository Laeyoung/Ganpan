# Subagent-Dispatch for Lane Commands — Context-Window Reduction (Spec)

Issue: #66 — "Subagent를 이용해서 Context Window 사용량 개선"

## Problem

Running a single Ganpan lane command repeatedly under Claude Code's `/loop`
(e.g. `/loop /ganpan:work-issue`) accumulates context in the **main session**
on every tick. Each tick the lane procedure executes *inline* in the main
agent: it reads several files, runs many `gh`/`git`/script commands, and (for
the Coder lane) implements code. All of those tool calls and their outputs land
in the main context window and are never reclaimed, so a long-running loop's
main context grows unbounded.

The multi-lane launcher `run-all` already avoids this for the fan-out case: it
spawns each lane as a background `Agent`, so the heavy work happens in a
disposable subagent context and the main session only sees a one-line summary.
The single-lane loop path has no such wrapper — it is the unaddressed case.

## Goal

Make each of the four standard lane commands keep the **main-session** context
footprint per `/loop` tick small by delegating the lane's execution to a single
disposable subagent and surfacing only a compact summary line back to the main
session.

In scope (four standard, frequently-looped lanes):

- `triage`
- `work-issue`
- `review-queue`
- `qa-check`

Explicitly **out of scope**:

- The deep variants (`work-issue-deep`, `review-queue-deep`). They are for
  occasional large issues, not high-frequency loops, and they already spawn
  nested skills (`/superpowers:*`, `/dev-review-loop`); wrapping them in another
  subagent risks nested-spawn limits. They keep running inline.
- The Codex skills (`plugins/ganpan-codex/skills/ganpan-*`). `/loop` is a
  Claude Code feature and the subagent-dispatch pattern uses Claude's `Agent`
  tool; Codex has a different execution model. The canonical lane references
  (`references/lanes/*.md`) are therefore **not** changed, so the Codex mirror
  and `tests/codex-skills.bats` stay valid.

## Constraints

1. **Single source of truth for lane logic.** The detailed, Claude-specific
   executable steps stay in each command file (the references are high-level
   protocol summaries and lack the exact script paths / jq queries). The
   subagent must execute *those* steps — we do not fork them into a second
   place.
2. **`run-all` must keep working without double-nesting.** `run-all` already
   spawns a per-lane agent that reads the command file and follows it. Once the
   command file gains a dispatch header, that agent must execute the steps
   *inline* rather than spawning a further nested subagent.
3. **The orchestration safety contract is unchanged.** Claim lock, heartbeat
   (start/stop within the lane's own lifetime), WIP gate, actor gate, worktree
   handling, label transitions, and the "never merge/approve" rule all behave
   exactly as today — they simply run inside the subagent, exactly as they
   already do under `run-all`.
4. **Both install modes work.** Plugin install (`${CLAUDE_PLUGIN_ROOT}` set) and
   copy-in install (`install.sh`, paths rewritten to `./`, files under
   `.claude/commands/`). The dispatch header must not hardcode a single path.
5. **Idle ticks stay cheap and safe.** A queue-empty tick must still end the
   turn quickly; dispatching a subagent that immediately discovers an empty
   queue and returns is acceptable overhead.

## Design (summary; full mechanics in the plan)

Each in-scope command file is split into two clearly delimited sections:

- **Dispatch header (runs in the main session).** If the agent's task prompt
  carries an explicit *execute-inline* directive, it skips dispatch and runs the
  Lane procedure directly. Otherwise it spawns exactly **one** foreground
  subagent whose prompt tells it to read this same command file and execute the
  "Lane procedure" section, then reply with **only** the lane's summary line.
  The main agent prints that summary and ends the turn.
- **Lane procedure.** The existing numbered steps, unchanged in substance.

`run-all` is updated to include the execute-inline directive in each lane
agent's prompt, so its spawned agents run the procedure directly (no extra
nesting level).

The execute-inline directive is a plain phrase passed in the Agent prompt — no
new env var or script is required. A subagent cannot reliably self-detect
"am I top-level", so detection is inverted: the *parent* (the main `/loop`
session via the dispatch header, or `run-all`) decides and signals inline
execution explicitly.

## Acceptance criteria

1. Running the same in-scope lane command 5× (e.g. via `/loop`) accumulates
   **≤ 1/2** the main-session context of the pre-change inline behavior. The
   dominant per-tick cost (multi-file reads, many command outputs, code
   implementation) moves into the subagent; the main session retains only the
   command text plus one summary line per tick.
2. Each of the four in-scope command files contains a dispatch header that (a)
   spawns a single subagent in the default path and (b) has an explicit
   execute-inline guard.
3. `run-all` passes the execute-inline directive to every lane agent it spawns,
   so no lane double-nests.
4. The canonical references (`references/lanes/*.md`) and the Codex skills are
   unchanged; `tests/codex-skills.bats` still passes.
5. A structural test asserts criteria 2 and 3 (the dispatch header is present in
   each of the four commands and the inline directive is present in `run-all`).
6. `bats tests/*.bats tests/orchestration/*.bats` and `shellcheck` pass; the
   plugin version is bumped (feat → minor).

## Non-goals

- Measuring the exact token reduction programmatically (the harness does not
  expose per-turn token counts to the command). Criterion 1 is established by
  construction — the heavy work provably moves off the main session — and is
  documented in the change log, not asserted by an automated token meter.
- Changing lane *behavior*, summary content, or the safety contract.
