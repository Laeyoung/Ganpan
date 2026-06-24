# Add development-workflow & history guidance to CLAUDE.md (#35)

- **Date:** 2026-06-24
- **Issue / PR:** #35 / (this PR)
- **Type:** docs

## What changed
Added a "Development workflow & history" section to the repo-root `CLAUDE.md` and created the `docs/log/` directory (this README + this first entry). The new guidance tells contributors to: (1) check `docs/superpowers/` and `docs/log/` for prior history before starting work; (2) use the Superpowers plugin in Spec → Plan → implementation order for new features; (3) record every shipped change in `docs/log/`, including key decisions and rejected alternatives.

## Why
History of past decisions lived only in `docs/superpowers/` (specs/plans) and was easy to miss; there was no convention for recording *what actually shipped* and *why a given approach was chosen over alternatives*. Without that, later work risks relitigating settled decisions. The acceptance criterion is that an agent reading CLAUDE.md now knows to look in these paths for history.

## Key decisions
- **Placed the new section above the `<!-- orchestration-conventions -->` sentinel** in CLAUDE.md. `orch-setup` appends its conventions block *after* that sentinel and guards with `grep -qF` so it never regenerates; content above the sentinel is hand-authored and always preserved.
- **Edited the repo-root `CLAUDE.md`, not `assets/CLAUDE.md`.** This guidance is about developing *this* repo; `assets/CLAUDE.md` is shipped to target repos and would be the wrong surface. Consequently nothing under `plugins/` changed, so no `plugin.json` version bump is needed (the change never reaches installed plugin users).
- **Seeded `docs/log/` with a README template + this first entry** so the directory exists in git (git does not track empty dirs) and the entry format is fixed by example.

## Alternatives considered (not chosen)
- **Add the guidance below the sentinel / into `assets/CLAUDE.md`** — rejected: below-sentinel content is auto-managed by `orch-setup`, and `assets/CLAUDE.md` ships to users (wrong audience for repo-internal dev workflow).
- **Add a `.gitkeep` instead of a README** — rejected: a README both makes the directory exist and documents the log format, which a `.gitkeep` cannot.
- **Bump `plugin.json`** — rejected: no shipped plugin artifact changed, so a bump would be version churn with no user-facing delta.
