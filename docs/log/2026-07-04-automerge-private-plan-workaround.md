# Auto-merge on Free-plan private repos (#72)

- **Date:** 2026-07-04
- **Issue / PR:** #72
- **Type:** fix

## What changed
Added an opt-in config flag `reviewer.autoMergePrivatePlanWorkaround` (default `false`)
loaded by `lib.sh` and honored by `auto-merge.sh`. When enabled, the branch-protection
probe's `403 "Upgrade to GitHub Pro or make this repository public…"` body — the exact
message GitHub returns for that endpoint on a **private** repo under the **Free** plan —
is treated as "base unprotected" instead of the usual inconclusive fail-closed. Every
other inconclusive probe (5xx, missing scope, any other 403) still fails closed.
Documented the constraint and the opt-in in the shipped `assets/CLAUDE.md` and
`docs/SETUP.md`; added regression tests and a `GH_API_ERR_MATCH`/`GH_API_ERR_BODY` stub
mechanism. Bumped plugin version 1.11.1 → 1.11.2.

## Why
The branch-protection API is a paid feature: on a private repo under GitHub Free it
always returns 403 regardless of whether protection exists, so a genuine 404 ("branch
not protected") is unreachable. `auto-merge.sh` fails closed on any non-404 probe (by
design), so `reviewer.autoMerge` was permanently stuck at `protect-check-failed` and
passing PRs sat in `in-review` forever (observed on `ainetwork-ai/recruit` PRs #15/#16).

## Key decisions
- **Keep it opt-in, default off** — no behavior change for any repo that does not set
  the flag; the existing fail-closed default is preserved.
- **Match the exact GitHub message, not any 403** — a repo that actually supports
  protection returns 200 (protected) or a real 404, never this string, so a genuine gate
  can never be bypassed. Other 403s (missing scope) stay fail-closed.
- **Log the bypass at WARN** — the one case where we proceed past a non-404 probe is
  surfaced, never silent.
- **Documented in shipped CLAUDE.md + SETUP** as the official path, offering the cheaper
  fixes first (make public / upgrade to Pro) before the workaround.

## Alternatives considered (not chosen)
- **Probe `gh api repos/:repo` for visibility/plan first and skip protection entirely on
  Free+private.** More "automatic," but the Free-plan owner-plan field is not reliably
  exposed to a fine-grained token, adds a second API call every tick, and would silently
  bypass the gate with no operator decision — worse than an explicit, logged opt-in.
- **Treat any 403 as unprotected when autoMerge is on.** Rejected: a 403 from a missing
  token scope on a repo that *does* have protection would then bypass a real gate.
- **Adopt the workaround unconditionally (no flag).** Rejected: it depends on a GitHub
  error-message string; making it opt-in confines that fragility to repos that knowingly
  accept it.
