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
spawns each lane as a **background** `Agent` (`run_in_background: true`) and
returns without waiting, so the heavy work happens in a disposable subagent
context and the main session only sees a one-line summary. The single-lane loop
path has no such wrapper — it is the unaddressed case.

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

- The deep variants (`work-issue-deep`, `review-queue-deep`). The primary
  reason is fit: they are for occasional large issues, not high-frequency loops,
  so their per-tick context cost is dominated by the (legitimate) issue work
  rather than redundant loop overhead. Secondarily, they already orchestrate
  nested skills (`/superpowers:*`, `/dev-review-loop`) that spawn their own
  agent teams; wrapping the whole lane in a further subagent is a conservative
  thing to avoid (deep nesting of agent spawns is untested here). They keep
  running inline.
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

Each in-scope command file gains a top **"Dispatch (loop mode)"** section above
the existing steps, and the existing steps are placed under a heading named
exactly **`## Lane procedure`** so the subagent has an unambiguous section to
execute.

### The execute-inline directive (canonical literal)

Detection is inverted: a subagent cannot reliably self-detect "am I
top-level", so the *parent* decides and signals inline execution explicitly.
The signal is one canonical literal string, used identically in the dispatch
header's subagent prompt, in `run-all`'s lane prompts, and in the structural
test:

```
GANPAN_EXECUTE_INLINE
```

The guard is a literal substring match for `GANPAN_EXECUTE_INLINE` in the
agent's own task prompt — not a paraphrase. This removes the "slight wording
variation silently breaks the guard" failure mode: every parent emits the exact
token and the guard greps for the exact token.

### Dispatch header (runs in the main session)

1. If the agent's task prompt contains `GANPAN_EXECUTE_INLINE`, **skip the
   dispatch** and run the `## Lane procedure` directly. (This is the path taken
   by the subagent the header spawns, and by `run-all`'s lane agents — it is
   what prevents a third nesting level.)
2. Otherwise, resolve the **install mode and this command file's absolute path**
   using the *same* detection `run-all` already performs in its step 1:
   - plugin mode (`${CLAUDE_PLUGIN_ROOT}` set): command file is
     `${CLAUDE_PLUGIN_ROOT}/commands/<lane>.md`; the subagent prompt must also
     carry the literal `PLUGIN_ROOT` value and instruct the subagent to
     substitute `${CLAUDE_PLUGIN_ROOT}` → that literal in every command it runs
     (the subagent's shell does not inherit the env var) — identical to
     `run-all`'s shared preamble.
   - copy-in mode (`${CLAUDE_PLUGIN_ROOT}` unset): command file is
     `$REPO_ROOT/.claude/commands/<lane>.md`; its script paths are already
     rewritten to `./`, so no substitution is needed.
3. Spawn exactly **one foreground** subagent (`run_in_background` **false**)
   whose prompt: (a) carries `GANPAN_EXECUTE_INLINE`, (b) names the resolved
   command-file path to Read, (c) tells it to execute that file's
   `## Lane procedure` section from the main repo root, and (d) asks it to reply
   with **only** the lane's one-line summary (the same per-lane summary format
   `run-all` already defines). The main agent prints that summary and ends the
   turn.

Foreground (blocking) is deliberate for the single-lane loop: each `/loop` tick
should run one lane to completion and surface its summary before the next tick,
so ticks stay sequential and never stack. (`run-all` stays background because it
fans out four lanes at once and must return promptly; the two are independent
choices.)

### `run-all` update

`run-all` adds `GANPAN_EXECUTE_INLINE` to each lane agent's prompt so those
agents run the `## Lane procedure` directly with no extra nesting. `run-all`
keeps spawning them as **background** agents — unchanged.

### Crash recovery is unchanged

If the foreground subagent dies after starting its heartbeat but before
stopping it, the situation is identical to today's `run-all` lane agent dying
mid-cycle: the stale claim is recovered by the existing engine path
(`reclaim.sh` after the heartbeat timeout, plus the Triager's reclaim sweep).
No new recovery mechanism is introduced; the safety contract is genuinely
unchanged because the heartbeat still starts and stops *inside* the lane
execution, exactly as under `run-all`.

### Why this meets the ≥1/2 goal (what stays in the main session)

The per-tick main-session footprint is bounded to: the command markdown
injected by `/loop`, the small install-mode-detection Bash block, the single
`Agent` spawn call, and the one-line summary reply. Everything that dominates
inline cost today — the resume-check / WIP / claim command outputs on an idle
tick, and on a claiming tick the multi-file reads, the full implementation, and
the test/build output — moves into the subagent's disposable context. The
residual fixed cost (the markdown text) does not grow with the work performed,
so across realistic loops (which periodically claim and do real work) the
main-session accumulation is far below half of the inline baseline.

## Acceptance criteria

1. **(Design / by construction — see "Why this meets the ≥1/2 goal".)** Running
   the same in-scope lane command 5× (e.g. via `/loop`) accumulates well under
   **1/2** the main-session context of the pre-change inline behavior, because
   the dominant per-tick cost (multi-file reads, many command outputs, code
   implementation) moves into the subagent and only the command text plus a
   one-line summary remains in the main session per tick. This is a structural
   property of the design, established by enumerating what stays in the main
   session, not by an automated token meter (see Non-goals).
2. Each of the four in-scope command files contains a `## Dispatch (loop mode)`
   section that (a) spawns a single subagent in the default path and (b) guards
   on the literal `GANPAN_EXECUTE_INLINE` to run inline instead, plus a
   `## Lane procedure` heading the subagent executes.
3. `run-all` passes the literal `GANPAN_EXECUTE_INLINE` to every lane agent it
   spawns, so no lane double-nests.
4. The canonical references (`references/lanes/*.md`) and the Codex skills are
   unchanged; `tests/codex-skills.bats` still passes.
5. A structural bats test asserts criteria 2 and 3 by grepping for these
   **canonical markers**:
   - in each of the four in-scope command files: the heading
     `## Dispatch (loop mode)`, the heading `## Lane procedure`, and the literal
     `GANPAN_EXECUTE_INLINE`;
   - in `run-all`: the literal `GANPAN_EXECUTE_INLINE`.

   **This test is a regression guard against the pattern being removed or a lane
   being missed — it confirms the markers are present, not that the LLM-executed
   dispatch logic behaves correctly.** Behavioral correctness of natural-language
   command prompts is not unit-testable here and is verified operationally (the
   design mirrors the already-proven `run-all` pattern). To reduce the "inverted
   guard" risk the reviewers flagged, the header is written so the
   `GANPAN_EXECUTE_INLINE` branch is the *inline* path and its absence is the
   *dispatch* path, matching `run-all`'s usage; the presence of the
   `## Dispatch (loop mode)` heading is the canonical marker that the dispatch
   instruction exists.
6. `bats tests/*.bats tests/orchestration/*.bats` and `shellcheck` pass; the
   plugin version is bumped (feat → minor).

## Non-goals

- Measuring the exact token reduction programmatically (the harness does not
  expose per-turn token counts to the command). Criterion 1 is established by
  construction — the enumeration above shows the heavy work moves off the main
  session — and is documented in the change log, not asserted by an automated
  token meter. AC1 is therefore deliberately a *design* criterion, not a gated
  test; AC5 is the automated gate (presence of the pattern), and the two do not
  conflict because they assert different things.
- A behavioral/functional test of the LLM dispatch decision. The commands are
  natural-language prompts executed by an agent, not code paths; the structural
  test (AC5) guards their content, operational use validates their behavior.
- Changing lane *behavior*, summary content, or the safety contract.
