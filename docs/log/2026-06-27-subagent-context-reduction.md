# Subagent-dispatch loop mode for standard lanes (#66)

- **Date:** 2026-06-27
- **Issue / PR:** #66 / (PR pending)
- **Type:** feat

## What changed

The four standard lane commands (`triage`, `work-issue`, `review-queue`,
`qa-check`) each gained a `## Dispatch (loop mode)` section above their existing
steps, which are now under a `## Lane procedure` heading. When the running agent
is the main/looped session, the dispatch header spawns **one foreground
subagent** (carrying the literal token `GANPAN_EXECUTE_INLINE`) that re-reads the
command file and executes the `## Lane procedure`, then replies with only the
lane's one-line summary; the main session prints that summary and ends the turn.
When the agent's own prompt already carries `GANPAN_EXECUTE_INLINE` (the spawned
subagent, and `run-all`'s lane agents), it skips dispatch and runs the procedure
directly — preventing a third nesting level.

`run-all.md`'s shared preamble now passes `GANPAN_EXECUTE_INLINE` to each lane
agent. A new `tests/dispatch-loop-mode.bats` structurally guards the pattern.
Plugin bumped 1.11.0 → 1.12.0.

Spec: `docs/superpowers/specs/2026-06-27-subagent-context-reduction.md`.
Plan: `docs/superpowers/plans/2026-06-27-subagent-context-reduction.md`.

## Why

Running a single lane via Claude Code `/loop` (e.g. `/loop /ganpan:work-issue`)
executed the whole lane inline in the main session every tick, so the main
context window grew without bound across iterations. `run-all` already solved
this for the multi-lane fan-out by spawning background agents; the single-lane
loop had no equivalent. Moving the heavy per-tick work (file reads, git/gh
commands, implementation, test output) into a disposable subagent leaves only
the command markdown plus a one-line summary in the main session each tick —
well under half the prior accumulation (issue #66's acceptance bar).

## Key decisions

- **Scope: four standard lanes only** (not the deep variants) — they are the
  ones meant to loop frequently; the deep variants are for occasional large
  issues and already orchestrate nested skills/agents, so wrapping them risks
  untested deep nesting. (User-confirmed via a scope question.)
- **Modify commands in place** (not new wrapper commands) — single source of
  truth, fewer files, and the canonical `## Lane procedure` body stays where the
  precise Claude-specific steps already live. (User-confirmed.)
- **Canonical literal `GANPAN_EXECUTE_INLINE`** as the inline guard — a subagent
  cannot self-detect "am I top-level", so the parent signals inline execution
  with one exact token used identically by the dispatch header, `run-all`, and
  the bats test. Avoids the "paraphrase silently breaks the guard" failure mode.
- **Foreground subagent for single-lane** (background stays for `run-all`) — a
  `/loop` tick should run one lane to completion and surface its summary before
  the next tick, keeping ticks sequential.
- **Slash-form `${CLAUDE_PLUGIN_ROOT}/` token everywhere in the header** (bash
  and prose) — `install.sh`'s sed rewrites only the slash form, and
  `install.bats` forbids any residual token (bare or not) outside `run-all.md`.
  A `[ -f ]` fallback resolves the command-file path correctly in both plugin
  and copy-in modes with zero residue, so **no `install.bats` change** was
  needed. (A first draft used a bare `${CLAUDE_PLUGIN_ROOT}` in a warning
  sentence; `install.bats` caught it — the test did its job.)
- **References and Codex skills untouched** — the dispatch pattern is
  Claude-`/loop`-specific and uses Claude's `Agent` tool; the canonical
  `references/lanes/*.md` stay the protocol summary, so `codex-skills.bats`
  remains valid.
- **Structural test scoped honestly** — it is a presence/regression guard
  (headings + token + no-bare-token); behavioral correctness of natural-language
  command prompts is not unit-testable and is validated operationally, mirroring
  the already-proven `run-all` pattern.

## Alternatives considered (not chosen)

- **Separate thin wrapper commands** (a generic loop launcher) — more files and
  a parallel surface to maintain; rejected in favor of in-place edits.
- **Include the deep variants** — broadest savings but real nested-spawn risk
  and poor fit (deep lanes are occasional, not looped).
- **Add the four lane files to `install.bats`'s exclude list** (the reviewer's
  first-suggested fix) — would weaken the path-drift guard; the slash-form +
  `[ -f ]` approach avoids needing any test change.
- **A behavioral/functional test of the dispatch decision** — the commands are
  LLM-executed prompts, not code paths; a true behavioral unit test isn't
  feasible, so a structural guard plus operational validation was chosen.
- **Passing `ORCH_CONFIG=<CFG>` into the subagent prompt** — removed as
  redundant/contradictory: the `## Lane procedure` already resolves its own
  config via `resolve_config_path`/`load_config`.

## Process deviation (noted for honesty)

The `/document-review-loop` and `/dev-review-loop` skills are ScheduleWakeup-
driven multi-turn loops. Running their full wake-based convergence inside this
already-`/loop`-driven deep lane would fragment the work across many scheduled
turns and tangle with the outer loop, so each review gate was honored as a
single parallel multi-agent pass (4 reviewers → fixes → a verification pass)
rather than the 2-consecutive-clean wake loop. The substance (independent
multi-dimension review with applied fixes) was preserved; spec and plan each
converged to a clean verification pass before implementation.

## Out-of-scope follow-up discovered

While running this lane, the shipped `scripts/orchestration/heartbeat.sh` was
observed to PATCH a **GraphQL node id** (`IC_…`, from `gh issue view --json
comments`) against the REST endpoint `/repos/:repo/issues/comments/:id`, which
expects the **numeric** `databaseId` — producing `HTTP 404` and a failed
heartbeat. This affects the live claim-lock refresh and is unrelated to #66
(one issue per branch); it should get its own issue/PR. Suggested fix: fetch the
numeric id via `gh api /repos/$REPO/issues/$n/comments` (REST) instead of
`gh issue view --json comments`, or PATCH via the GraphQL `updateIssueComment`
mutation.
