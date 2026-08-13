# Label drift detection for existing installs (#81)

- **Date:** 2026-08-13
- **Issue / PR:** #81 / #85
- **Type:** fix + feat
- **Version:** 1.13.0 → 1.14.0 (new engine script + new advisory step → minor)

## What changed

**Immediate.** `status:needs-decision` did not exist on `Laeyoung/Ganpan` — the only
one of the eight labels in `assets/labels.yml` missing from the repo. Re-ran
`bootstrap-labels.sh`; the other seven already matched the asset's colour and
description exactly, so the run created one label and was a no-op for the rest.

**Structural.** New `plugins/orchestration/scripts/orchestration/labels-check.sh`:
read-only drift detector comparing the names in `labels.yml` against
`gh label list` on `config.repo`. Exit 0 in sync; exit 1 on drift, naming the
missing labels and pointing at the idempotent bootstrap re-run. An API failure is
reported as **inconclusive**, explicitly not as drift.

Wired into the upgrade path — where new labels actually arrive — and setup:
- `/ganpan:update` + the `ganpan-update` Codex skill run it as an advisory step
- `/ganpan:orch-setup` step 6 replaces a bare `grep -c '^status:'` count with it
- `references/lanes/setup.md` (+ its Codex copy) gain a verify step
- `docs/SETUP.md` §4 and `README.md` (upgrade note) state the re-run rule

**Regression guards.** New `tests/orchestration/labels-check.bats` (9 tests).
`tests/orchestration/bootstrap-labels.bats` no longer hardcodes `8`: the count is
derived from `labels.yml`, plus a new test asserting each name in the asset is
bootstrapped **by name**. The `gh` stub learned to answer `label list` as a read.

## Why

Labels are bootstrapped exactly once, at `/orch-setup`. A repo installed before a
label was added to `labels.yml` never receives it, and nothing detects the gap —
it surfaces only when a lane's `--add-label` write fails mid-run. Here the
Reviewer's human-decision gate (R-B) would have failed on
`gh issue edit --add-label status:needs-decision`; it stayed latent only because
the `status:in-review` queue happened to be empty.

## Key decisions

- **Detect, don't auto-heal.** `labels-check.sh` never writes. Label creation is a
  repo-configuration change the operator should make deliberately, and an
  auto-creating check called from a read-only advisory (`/ganpan:update` is
  documented as never changing the repo) would violate that contract.
- **Hook the check to the upgrade path, not to lane start.** The gap is created by
  upgrading, so that is where the report belongs. Checking at every lane tick
  would add a `gh label list` call to every claim/review cycle for a condition
  that changes only on upgrade.
- **Not actor-gated.** Same rationale as `bootstrap-labels.sh` (spec §4.3): labels
  are repo config, this may run at setup before the bot PAT exists, and it is
  read-only so there is no write to misattribute.
- **`--limit 1000`.** The `gh label list` default page size is 30; a repo with more
  labels than one page would have labels reported as missing. Same fix class as
  `wip-check.sh`.
- **API failure ≠ drift.** A failed listing prints "Inconclusive" and never the
  word DRIFT, so an operator does not re-bootstrap on the strength of a network
  blip.
- **Derive the bootstrap test's expectation from `labels.yml`.** The frozen literal
  `8` is the same shape of bug as the issue itself: an asset gained a label and
  nothing downstream noticed. The by-name assertion catches the case a count
  cannot (one name created twice, another skipped).

## Alternatives considered (not chosen)

- **Have each lane self-heal by creating a missing label on demand.** Rejected:
  every lane would need write-on-read behaviour, and a typo'd label name in a lane
  would silently create a junk label instead of failing loudly.
- **Run the drift check at lane startup and warn.** Rejected as the primary hook
  for the per-tick API cost above; the issue's AC accepts either that or the
  documented idempotent re-run, and the upgrade advisory covers the real trigger.
  A lane-start check remains a possible future addition.
- **Version the label set and store the applied version in the repo.** Rejected as
  over-engineered: comparing the two live sets is simpler, needs no state, and
  cannot go stale.
- **Have `install.sh` bootstrap labels on upgrade.** Rejected: `install.sh` copies
  files and must stay usable without a GitHub token or network.
