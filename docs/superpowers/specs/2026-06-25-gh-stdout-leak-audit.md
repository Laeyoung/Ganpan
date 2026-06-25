# Spec: Audit engine scripts for gh-stdout leaks; codify keep-stdout-clean convention

- **Issue:** #29 (follow-up to #4 / PR #28)
- **Date:** 2026-06-25
- **Type:** docs + fix + test

## Problem

PR #28 (#4) fixed a real corruption bug: `claim.sh` is captured as
`ISSUE=$(claim.sh)`, but its internal `gh issue edit`/`gh issue comment`
calls print the **resource URL to stdout on success** even non-interactively.
Those URLs leaked into the captured value, so `ISSUE` could become
`"https://github.com/...\n42"` instead of `42`. The fix redirected every
mutating `gh` call in `claim.sh` to `>/dev/null`.

This is a **bug class**, not a one-off: any engine script that is captured via
`$(…)` for its return value, yet internally makes a mutating `gh` call
(`gh issue edit|comment|create`, `gh pr create|merge`, `gh label create`,
`gh project item-edit`, `gh api --method POST|PUT|PATCH|DELETE`), can leak
that command's success output into the captured value and silently corrupt it.

Three things are missing:
1. A **systematic audit** confirming no other captured script leaks today.
2. A **documented convention** so future scripts don't reintroduce the class.
3. **Regression tests** (the `GH_EMIT_WRITE_URL` pattern, currently only in
   `claim.bats`) extended to the other scripts that exercise the convention.

## Audit findings (as of this spec)

Scripts captured via `$(…)` for their return value (the only ones where a
stdout leak corrupts a value), and their status:

| Script | Captured as | Mutating `gh`? | Leak risk |
|---|---|---|---|
| `claim.sh` | `ISSUE=$(…)` | yes — all `>/dev/null` | **clean** (PR #28) |
| `auto-merge.sh` | `AM=$(…)` | `gh pr merge` captured into `merge_out=$(… 2>&1)` | **clean** |
| `unblock-check.sh` | `case "$(…)"` | none (read-only `gh issue view`) | **clean** |
| `trusted-answers.sh` | `ANSWERS=$(…)` | none (read-only `gh api …/comments`) | **clean** |
| `decision-resolve.sh` | `… \| jq` | none (no `gh`) | **clean** |
| `followup-dedup.sh` | `DECISION=$(…)` | none (read-only `gh issue view`) | **clean** |

**Conclusion: every currently-captured script is already clean.** The PR #28
fix plus `auto-merge.sh`'s pre-existing `merge_out=$(… 2>&1)` isolation cover
all live capture sites.

Scripts that make mutating `gh` calls to **bare stdout** but are **not**
currently captured (latent — safe today, but a future `$()` capture would
reintroduce the bug):

| Script / line | Call | Notes |
|---|---|---|
| `reclaim.sh:49-56` | `gh issue edit` / `gh issue comment` | run for exit code only (cron/loop); output ignored today |
| `lib.sh:121` (`project_sync`) | `gh project item-edit` | called as a function, not in `$()` |
| `bootstrap-labels.sh:19` | `gh label create` | **out of scope** — its stdout is intentional human-facing setup progress, not a return value |

## Goals

1. **Future-proof the two latent leaks** so the convention holds uniformly:
   redirect the mutating `gh` calls in `reclaim.sh:49-56` and
   `lib.sh:121` to `>/dev/null` (preserving their exit-status semantics and
   `|| log WARN` branches; `stderr` stays open for genuine errors).
2. **Codify the convention** in the repo's developer rules (root `CLAUDE.md`
   Gotchas) so it is enforced going forward.
3. **Extend regression coverage** of the `GH_EMIT_WRITE_URL` pattern to the
   scripts that meaningfully exercise the convention:
   - `auto-merge.sh` — lock in that its `$()`-captured stdout stays a clean
     token even when `gh pr merge` leaks a URL.
   - `reclaim.sh` — lock in that no write URL reaches stdout after the fix.

## Non-goals

- Changing `bootstrap-labels.sh` — its stdout is deliberate human-facing
  setup progress, not a captured return value. (Documented as the explicit
  exception so the convention is unambiguous.)
- Changing the runtime contract of any script (exit codes, return tokens,
  argument shapes). This is a stdout-hygiene change only.
- Re-architecting how lanes capture script output.

## Constraints

- **Never rename engine internals** (`scripts/orchestration/`,
  `orchestration.json`, the `ganpan-orchestration` sentinel) — deployed
  runtime contract (CLAUDE.md Gotchas).
- Preserve every script's existing exit code and stdout return token exactly;
  only suppress incidental success output of mutating `gh` writes.
- `>/dev/null` (stdout only), **not** `>/dev/null 2>&1`, on calls whose
  failure must still surface via `|| log WARN`/`||`-chains — stderr must stay
  open so genuine errors are visible. (Exception: the existing
  `gh api --method DELETE … >/dev/null 2>&1 || true` best-effort cleanups in
  `claim.sh` are already correct and unchanged.)
- Tests use `bats`; the fake `gh` stub already supports `GH_EMIT_WRITE_URL`
  (`tests/orchestration/helpers/gh-stub.sh`). No new test infrastructure.
- Shipped artifacts under `plugins/` change → bump
  `plugins/orchestration/.claude-plugin/plugin.json` (fix → patch).

## Acceptance criteria

1. `reclaim.sh` and `lib.sh` `project_sync` redirect their mutating `gh`
   write stdout to `>/dev/null`; their exit-status and `|| log WARN` branches
   are unchanged. `shellcheck` passes on both.
2. Root `CLAUDE.md` documents the keep-stdout-clean convention: engine
   scripts whose stdout is a captured return value must send mutating `gh`
   success output to `/dev/null` (or stderr); names the `bootstrap-labels.sh`
   human-facing-output exception.
3. `tests/orchestration/auto-merge.bats` gains a test asserting the captured
   stdout is exactly the expected token (e.g. `merged`) under
   `GH_EMIT_WRITE_URL=1` — no `STUB-URL` leaks.
4. `tests/orchestration/reclaim.bats` gains a test asserting no `STUB-URL`
   reaches stdout under `GH_EMIT_WRITE_URL=1` for both the open-PR
   (`→ blocked`) and no-PR (`→ agent-ready`) reclaim branches.
5. Full suite green: `bats tests/*.bats tests/orchestration/*.bats`.
6. `plugins/orchestration/.claude-plugin/plugin.json` version bumped (patch).
7. A `docs/log/` entry records the audit outcome, the fixes, and the
   rejected alternatives.
