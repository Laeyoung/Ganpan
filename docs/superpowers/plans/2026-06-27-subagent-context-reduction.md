# Subagent-Dispatch for Lane Commands — Implementation Plan

Spec: `docs/superpowers/specs/2026-06-27-subagent-context-reduction.md`
Issue: #66

## Overview

Add a `## Dispatch (loop mode)` section to the top of each of the four standard
lane commands and move their existing body under a `## Lane procedure` heading.
The dispatch section spawns one foreground subagent (carrying the literal
`GANPAN_EXECUTE_INLINE`) that re-reads the command file and runs the
`## Lane procedure`; if the running agent's own prompt already carries
`GANPAN_EXECUTE_INLINE`, it skips dispatch and runs the procedure directly.
Update `run-all` to pass `GANPAN_EXECUTE_INLINE` in each lane agent's prompt.
Add a structural bats test, bump the version, log the change.

Files touched (all under `plugins/`):

- `plugins/orchestration/commands/triage.md`
- `plugins/orchestration/commands/work-issue.md`
- `plugins/orchestration/commands/review-queue.md`
- `plugins/orchestration/commands/qa-check.md`
- `plugins/orchestration/commands/run-all.md`
- `tests/dispatch-loop-mode.bats` (new)
- `plugins/orchestration/.claude-plugin/plugin.json` (version bump)
- `docs/log/2026-06-27-subagent-context-reduction.md` (new)

Not touched: `references/lanes/*.md`, `plugins/ganpan-codex/skills/**`,
`commands/*-deep.md`, `commands/orch-setup.md`, `commands/update.md`.

## Canonical dispatch-header template

Inserted **immediately after the command's front-matter and one-line title**,
before the existing first paragraph. `<lane>` and `<Lane summary format>` are
substituted per command. The header text is identical across the four commands
except those two substitutions.

````markdown
## Dispatch (loop mode)

**Run this first.** This command is designed to be looped (`/loop /ganpan:<lane>`).
To keep the **main session's** context small across ticks, the actual lane work
runs in a disposable subagent; the main session only prints a one-line summary.

- **If your task prompt contains the token `GANPAN_EXECUTE_INLINE`**, skip this
  whole section and execute the **`## Lane procedure`** below directly. (This is
  the path taken by the subagent spawned here, and by the `run-all` launcher —
  it is what prevents a third level of nesting.)
- **Otherwise** (you are the main/looped session), do exactly this and then end
  your turn:
  1. Resolve this command file's path and the install mode. **Use only the
     slash-form `${CLAUDE_PLUGIN_ROOT}/` token** (never the bare
     `${CLAUDE_PLUGIN_ROOT}`): `install.sh` rewrites `${CLAUDE_PLUGIN_ROOT}/` →
     `./` on copy-in, and `tests/install.bats` forbids a *bare* unsubstituted
     token in any command except `run-all.md`. A `[ -f ]` fallback gives correct
     behavior in both modes with no bare token, so **no `install.bats` change is
     needed**:
     ```bash
     REPO_ROOT="$PWD"
     # plugin mode: the env var is set and this slash-form path exists.
     # copy-in: sed already rewrote the next line to CMD_FILE="./commands/<lane>.md",
     # which does not exist (real path is .claude/commands), so the fallback fires.
     CMD_FILE="${CLAUDE_PLUGIN_ROOT}/commands/<lane>.md"
     if [ -f "$CMD_FILE" ]; then
       PLUGIN_ROOT="${CMD_FILE%/commands/<lane>.md}"; MODE=plugin
     else
       CMD_FILE="$REPO_ROOT/.claude/commands/<lane>.md"; PLUGIN_ROOT=""; MODE=copyin
     fi
     echo "MODE=$MODE CMD_FILE=$CMD_FILE PLUGIN_ROOT=$PLUGIN_ROOT"
     ```
  2. Spawn **one foreground subagent** (Agent tool, `run_in_background: false`)
     with a prompt built from this template (substitute the literal step-1
     values for `<REPO_ROOT>`, `<CMD_FILE>`, `<PLUGIN_ROOT>`):
     > "`GANPAN_EXECUTE_INLINE`. Run from the main repo root `<REPO_ROOT>`. Read
     > the file `<CMD_FILE>` with the Read tool and execute its **`## Lane
     > procedure`** section exactly, from start to finish. *(plugin mode only:)*
     > that file references scripts via `${CLAUDE_PLUGIN_ROOT}`, which is **not
     > set in your shell** — in every command you run, replace
     > `${CLAUDE_PLUGIN_ROOT}` with the literal `<PLUGIN_ROOT>`, including inside
     > any backgrounded subshell (e.g. the heartbeat loop). The procedure resolves
     > its own config (`resolve_config_path` / `load_config`) and passes
     > `ORCH_CONFIG` where needed — follow it as written. Do exactly one bounded
     > lane cycle as the procedure describes, then reply with **only** a single
     > summary line: `<Lane summary format>`. Never approve or merge a PR."
     >
     > In plugin mode include the `${CLAUDE_PLUGIN_ROOT}` substitution sentence;
     > in copy-in mode omit it (the file's paths are already `./`). Do **not** put
     > a config path in the prompt — the procedure resolves it itself (the
     > previous draft's `ORCH_CONFIG=<CFG>` clause was removed because the
     > subagent self-resolves config at procedure start).
  3. Print the subagent's summary line verbatim and end the turn. Do **not**
     also run the `## Lane procedure` yourself.

If the subagent dies mid-cycle, the claim lock is recovered by the existing
engine path (`reclaim.sh` after the heartbeat timeout + the Triager reclaim
sweep) — identical to a `run-all` lane agent dying. No extra handling here.
````

Per-lane summary formats (reuse `run-all`'s existing definitions):

- triage: `Triager: reclaimed <r>, unblocked <u>, classified <c> (ready <a>, blocked <b>).`
- work-issue: `Coder: <claimed #N and shipped PR #M | queue-empty | wip-exceed | claim-failed | claim-unconfirmed | api-fail>.`
- review-queue: `Reviewer: reviewed <n> (→qa <q>, →rework <w>, awaiting-merge <m>).`
- qa-check: `QA: verified <n> (pass <p>, rework <w>, blocked <b>).`

## Per-file steps

### 1. Each of the four command files

1. Insert the canonical dispatch header (substituted) right after the title.
2. Add a `## Lane procedure` heading directly above the existing
   "You are the **…** lane" paragraph / "Do exactly this" steps. Do **not**
   change the step contents.
3. Verify the body still reads correctly as a standalone procedure (the
   subagent reads from `## Lane procedure` onward).

Note: `work-issue.md`'s existing summary wording in `run-all` is
`Coder: completed <k> cycle(s); last <…>.` (multi-cycle). For the single-lane
dispatch we want one bounded cycle, so the dispatch header's summary format is
the single-cycle phrasing above. This does not change `run-all`'s own summary.

### 2. `run-all.md`

In the **shared preamble** inside step 3 (the quoted per-agent prompt that
begins "Run from the main repo root `<REPO_ROOT>`. Read your lane file …"), add
the literal `GANPAN_EXECUTE_INLINE` so each spawned lane agent runs its
`## Lane procedure` directly without re-dispatching. One sentence appended to
that preamble, e.g.: "Your prompt carries `GANPAN_EXECUTE_INLINE`, so when you
read your lane file, follow its `## Lane procedure` section directly and do
**not** perform the file's `## Dispatch (loop mode)` section." Keep
`run_in_background: true` and the existing background fan-out behavior. (Only the
four standard lanes gain a `## Dispatch (loop mode)` section; the sentence is
harmless for any lane file that lacks one.)

### 3. `tests/dispatch-loop-mode.bats` (new)

Structural regression guard (matches the existing grep-style bats tests). Assert:

- For each of `triage.md`, `work-issue.md`, `review-queue.md`, `qa-check.md`
  under `plugins/orchestration/commands/`:
  - contains the heading `## Dispatch (loop mode)`
  - contains the heading `## Lane procedure`
  - contains the literal `GANPAN_EXECUTE_INLINE`
- `run-all.md` contains the literal `GANPAN_EXECUTE_INLINE`.
- Negative guard: the out-of-scope commands `work-issue-deep.md`,
  `review-queue-deep.md`, `orch-setup.md`, and `update.md` do **not** contain
  `## Dispatch (loop mode)` (confirms the scope line wasn't accidentally
  crossed). (There is no `triage-deep`/`qa-check-deep` variant.)

Resolve the commands dir relative to `BATS_TEST_DIRNAME` like the sibling tests
do. Use plain `grep -q -- 'literal'` / `grep -qF`.

### 4. Version bump

`plugins/orchestration/.claude-plugin/plugin.json`: `1.11.0` → `1.12.0`
(feat → minor). This is the only version sentinel to bump.

### 5. Change log

`docs/log/2026-06-27-subagent-context-reduction.md` per `docs/log/README.md`:
what changed, key decisions (four-lane scope; modify-in-place; canonical token;
foreground; references/Codex untouched), rejected alternatives (separate wrapper
commands; including deep variants; behavioral test). Also record the separately
discovered **heartbeat 404 bug** (shipped `heartbeat.sh` PATCHes a GraphQL node
id against the REST comments endpoint) as an out-of-scope follow-up note.

## Verification

```bash
bats tests/*.bats tests/orchestration/*.bats
shellcheck plugins/orchestration/scripts/orchestration/*.sh
jq . .claude-plugin/marketplace.json plugins/orchestration/.claude-plugin/plugin.json
```

Expected: all green; `codex-skills.bats` still passes (references untouched);
the new `dispatch-loop-mode.bats` passes.

## Risks / mitigations

- **Double-nesting under run-all** — mitigated by the `GANPAN_EXECUTE_INLINE`
  guard in both the dispatch header and run-all's prompt.
- **Subagent can't find the command file in copy-in mode** — header resolves the
  path with a `[ -f ]` fallback that works in both modes using only the
  slash-form token (so `install.sh`'s sed handles copy-in and no bare token
  drifts into the copied files; `install.bats` needs no change).
- **Manual one-shot invocation** (`/ganpan:work-issue` without `/loop`) — still
  works: it simply dispatches one subagent and prints the summary, which is the
  intended behavior either way.
- **Scope creep into deep variants** — negative bats assertion guards it.
