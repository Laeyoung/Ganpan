# Setup-time advisory for the Free-plan private-repo auto-merge trap (#80)

- **Date:** 2026-08-13
- **Issue / PR:** #80
- **Type:** feat

## What changed
Added `scripts/orchestration/visibility-check.sh` — a read-only script that reads
`gh api repos/:repo --jq .private` and, on a **private** repo, prints the Free-plan
branch-protection 403 trap (#72) together with the three fixes (make public / upgrade to
Pro-Team / opt in with `reviewer.autoMergePrivatePlanWorkaround: true`). `/ganpan:orch-setup`
now runs it at the top of step 5 so its output is part of the human checklist; the shared
lane reference `references/lanes/setup.md` (and its synced Codex copy) gained the same step.
Documented in `docs/SETUP.md` §6 and the README auto-merge section. 9 bats cases in
`tests/orchestration/visibility-check.bats`. Bumped the plugin 1.14.0 → 1.15.0.

`auto-merge.sh` is untouched — its fail-closed behavior and the opt-in flag's semantics are
exactly as shipped in #72.

## Why
On a private repo under GitHub Free, `repos/:repo/branches/:base/protection` always returns
`403 "Upgrade to GitHub Pro or make this repository public…"` regardless of protection state,
so `auto-merge.sh`'s genuine 404 is unreachable and it fails closed forever. The symptom —
passing PRs sitting in `status:in-review` indefinitely — gives no pointer to the cause, and
the opt-in escape hatch was only discoverable by reading `docs/SETUP.md` or the shipped
`assets/CLAUDE.md` after the fact. Surfacing it once, at setup, is where the operator can
still act on it cheaply.

## Key decisions
- **Visibility only, never plan detection.** `gh api repos/:repo --jq .private` is reliable
  under a fine-grained token; the owner-`plan` field is not. So the script advises on *every*
  private repo and says explicitly that the advisory is a no-op on a paid plan, rather than
  guessing and staying silent on a Free repo whose plan it could not read.
- **Advise even when `reviewer.autoMerge` is false.** Setup is a one-shot moment; the operator
  usually enables auto-merge later, by which point nobody re-runs setup. The advisory adds a
  parenthetical that nothing is stuck *today*, so it does not read as a live failure.
- **`ADVISORY` exits 1, and `orch-setup` calls it with `|| true`.** Keeps the exit-code family
  consistent with `labels-check.sh` (0 = nothing to act on, 1 = human action or inconclusive)
  while making it impossible for a private repo to look like a failed setup.
- **`OK` when the flag is already `true`.** A repo that already opted in has made the decision;
  repeating the warning on every setup re-run is noise.
- **Never flip the flag for the human.** Stated in the command, the reference, and the script's
  own output. The flag is the operator's explicit acceptance that a Free private repo cannot
  have branch protection — writing it automatically would be the silent gate bypass that #72
  deliberately rejected.
- **FAIL, not "assume public", on an unreadable or unexpected `.private`.** An inconclusive
  probe must not produce a confident "no trap here" — the same fail-closed instinct as
  `auto-merge.sh`, applied to advice instead of merges.

## Alternatives considered (not chosen)
- **Runtime detection inside `auto-merge.sh`** (probe visibility and skip the protection check
  on a private repo). This is exactly what #72 rejected as a silent gate bypass — see
  `docs/log/2026-07-04-automerge-private-plan-workaround.md`. It also adds an API call per tick.
- **Have `orch-setup` write `autoMergePrivatePlanWorkaround: true` when the repo is private.**
  Turns an operator decision into a default and would enable the bypass on paid private repos
  that never needed it.
- **Inline the `gh api` call in `orch-setup.md` instead of a script.** No bats coverage, and the
  Claude command and the Codex skill would drift; a script under `scripts/orchestration/` is
  picked up by `install.sh`'s glob for both surfaces.
- **Fold the check into `labels-check.sh`** so `/ganpan:update` reports it too. Conflates two
  unrelated diagnostics under one exit code; a separate script keeps `DRIFT` meaning drift.
