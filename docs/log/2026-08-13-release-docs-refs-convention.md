# Release docs follow the non-closing `Refs #<n>` convention (#78)

- **Date:** 2026-08-13
- **Issue / PR:** #78 / #81
- **Type:** docs
- **Version:** 1.13.0 → 1.13.1 (docs/fix → patch)

## What changed
`docs/RELEASE_CHECKLIST.md` (§4) and `docs/RELEASE_PLAYBOOK.md` (§5) still told
releasers to reference the issue with the auto-closing `Closes #<n>` keyword.
Both now say **non-closing `Refs #<n>`** and state the reason inline (QA owns the
terminal close; an auto-closing keyword closes the issue on merge and skips
`qa-check`).

The `#63` regression guard in `tests/codex-skills.bats` was extended twice:

- the two release docs joined the explicit no-`Closes #` / has-`Refs #` file lists;
- a new sweep asserts that **no** file under `docs/` outside `docs/log/` and
  `docs/superpowers/` contains `Closes #`, so a future doc cannot reintroduce it.

## Why
`#63` replaced the auto-closing keyword with `Refs #<n>` across the lane files
and `CLAUDE.md`, but the change never reached the release documentation — the
two surfaces a human reads while cutting a release. That left the repo
documenting two contradictory commit conventions, and a release cut from the old
instructions would auto-close issues at merge, silently skipping the QA lane.

## Key decisions
- **State the rationale inline in both docs, not just the keyword.** The
  original `#63` failure mode was a mechanical find-and-replace that people could
  undo without knowing why; a one-line "QA owns the terminal close" makes the
  constraint self-explaining at the point of use.
- **Add a directory-wide sweep, not just two more filenames.** The existing
  guard enumerates files, which is exactly why `#63` missed these two docs. The
  sweep closes the class of bug rather than the two instances.
- **Exclude `docs/log/` and `docs/superpowers/` from the sweep.** They are
  historical records that quote the old convention as history; rewriting them
  would falsify the record.
- **Patch bump (1.13.1).** Documentation-only correction of a stated convention,
  no behavior change in the shipped engine.

## Alternatives considered (not chosen)
- **Repo-wide grep guard (all `*.md`).** Rejected: it would fire on the spec and
  plan documents that legitimately discuss `Closes #`, forcing either a longer
  exclusion list or edits to historical files.
- **Drop the issue-reference footer from the release docs entirely** and point at
  `CLAUDE.md` as the single source. Rejected: the release checklist is used as a
  standalone runbook, and an unstated convention is what allowed the drift.
- **A `pre-commit` hook instead of a bats test.** Rejected: the repo's existing
  convention invariants all live in `tests/codex-skills.bats`, and hooks are not
  installed in CI or in contributors' checkouts.
