# `npx skills add Laeyoung/Ganpan` install surface

- **Date:** 2026-09-29
- **Issue / PR:** — / —
- **Type:** feat
- **Version:** 1.15.1 → 1.16.0 (feat → minor)

## What changed
- `bin/ganpan.mjs` + `package.json`: zero-dependency Node CLI run as
  `npx -y github:Laeyoung/Ganpan#vX.Y.Z`. `init` delegates to `install.sh`
  (default `--target codex`, bash/jq preflight, refuses a ganpan checkout);
  `validate` is an offline check of config (placeholders, `owner/name`,
  `$ORCH_CONFIG` resolved against the target dir), engine presence/sentinel drift
  (warn) and `labels.yml`.
- `ganpan-setup` skill bootstraps the engine via the pinned `npx … init`, only
  *prints* `init --force` on drift, and ends with `validate`; the four lane skills
  hard-stop when `scripts/orchestration/lib.sh` is missing.
- `scripts/release.sh`: guarded `vX.Y.Z` tagger (read-only guards incl. canonical
  remote and HEAD == remote/main; push-failure recovery). `.gitignore` un-ignores it.
- Tests: `tests/cli.bats`, `tests/release.bats`, discovery/pin/preflight guards in
  `tests/codex-skills.bats`. CI runs node, shellchecks `release.sh`, validates `package.json`.
- Docs: README 방법 E, release playbook/checklist tag step, CLAUDE.md.

## Why
An external brief asked for `npx skills add Laeyoung/Ganpan -g`. The skills CLI
already discovered the six skills, but it copies only skill directories — every
lane sources `scripts/orchestration/lib.sh`, so skills installed this way failed on
any repo without the engine.

## Key decisions
- **Adapt the brief instead of following it literally** — it described an unrelated
  "AI-agent signboard (`/ganpan/start.md`)" spec; the user chose to reinterpret it for
  the orchestration toolkit. Its `references/spec.md` was dropped.
- **No root `SKILL.md`, no `skills/` symlinks** — a shallower `SKILL.md` shadows nested
  ones; symlinks break on Windows clones. Rely on the recursive fallback and guard its
  preconditions on git-tracked files.
- **`init` delegates to `install.sh`** — one tested copy/sentinel/never-clobber
  implementation instead of a Node rewrite.
- **Pin the bootstrap to a tag** — reproducible installs, and a broken `main` never
  executes on fresh repos. This introduced tags, which are additive to the
  merge-to-`main` release model.
- **Skills never self-run `--force`; lanes never bootstrap** — a skill has no real
  confirmation gate, least of all when unattended.
- **Version stays single-sourced** — the CLI reads `plugin.json`; `package.json` and
  the pin are test-enforced copies.

## Alternatives considered (not chosen)
- Declaring the skills in `.claude-plugin/marketplace.json` — it is also the Claude
  plugin marketplace; it would register the Codex skills as Claude plugin skills.
- Bootstrapping from `main` (`npx github:Laeyoung/Ganpan init`) — mutable,
  non-reproducible, supply-chain exposure.
- Publishing to the npm registry — unnecessary for `npx github:`; kept `private: true`.
- Lanes checking engine staleness themselves — duplicates `ganpan-update`.
