# Release checklist + playbook (#73)

- **Date:** 2026-07-04
- **Issue / PR:** #73
- **Type:** docs

## What changed
Added two release-preparation documents and confirmed current release quality:
- `docs/RELEASE_CHECKLIST.md` — a copy-into-the-PR tick-box gate covering quality
  gates, the SemVer version bump, the four distribution surfaces, docs/changelog,
  and merge/post-merge verification.
- `docs/RELEASE_PLAYBOOK.md` — the step-by-step "how a change reaches users"
  narrative, including the release model, rollback, surface sync table, and a
  current-readiness note.

Quality was verified as part of the acceptance criteria ("출시 할만한 퀄리티
확인"): `bats tests/*.bats tests/orchestration/*.bats` = 204/204 passing,
`shellcheck plugins/orchestration/scripts/orchestration/*.sh` = clean, and both
manifests parse under `jq`.

## Why
Issue #73 asked to prepare for release: confirm the toolkit is release-worthy,
create a pre-release checklist, and write a release playbook. Ganpan had none of
these, and its release model is unusual enough (no tags, no GitHub Release, no
build — the release *is* the merge to `main` with a bumped `plugin.json`
version) that shipping without a written gate is error-prone.

## Key decisions
- **Centered both docs on the real release trigger** — `version-check.sh` reads
  `.version` from `plugin.json` at `?ref=main`, so the version field on `main`
  literally *is* the released version. Every step reinforces "bump version in the
  same PR; treat `main` as production."
- **Two documents, not one** — the checklist is the actionable per-release gate;
  the playbook is the explanatory reference. Keeping them separate lets the
  checklist stay terse enough to paste into a PR.
- **Post-merge verification uses the same `gh api …?ref=main` probe** that
  clients use, so "did it ship" is answered by the client's own source of truth.
- **Documented rollback re-bumps the version** — because the plugin cache keys on
  `version`, a revert that keeps the same version would not propagate.

## Alternatives considered (not chosen)
- **Introduce git tags / GitHub Releases** — rejected for this change: it would
  alter the release mechanism, not document it. #73 is about preparing to ship
  the current model, not redesigning distribution. Left as a possible future
  spec.
- **A single combined RELEASE.md** — rejected; a long doc discourages actually
  ticking boxes per release. Split into gate + reference.
- **Automating the checklist as a script** — out of scope for a docs task and
  would duplicate the existing `bats`/`shellcheck`/`jq` invocations; the
  checklist points at those instead.
