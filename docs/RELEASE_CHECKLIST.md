# Ganpan pre-release checklist

Copy this into the release PR/issue and tick every box before merging to `main`.
Ganpan has **no build artifact, git tag, or GitHub Release step** — the release
*is* the merge to `main` with a bumped `plugin.json` version (see
[`RELEASE_PLAYBOOK.md`](./RELEASE_PLAYBOOK.md)). So this checklist is the only
gate between "works on my branch" and "shipped to every installed user."

> Why this matters: the `laeyoung` marketplace pulls `main`, and the plugin
> cache keys on `plugins/orchestration/.claude-plugin/plugin.json` `version`.
> A merge that does not bump `version` **never reaches installed users**, and a
> broken merge to `main` ships to everyone on their next `/plugin` update.

## 1. Quality gates (all must be green on the release branch)

- [ ] **Tests pass:** `bats tests/*.bats tests/orchestration/*.bats` — 0 failures.
- [ ] **Lint clean:** `shellcheck plugins/orchestration/scripts/orchestration/*.sh` — exit 0.
- [ ] **Manifests valid:** `jq . .claude-plugin/marketplace.json plugins/orchestration/.claude-plugin/plugin.json` — both parse.
- [ ] New/changed behavior has a test (captured-stdout + mutating scripts use the `GH_EMIT_WRITE_URL` stub pattern — see `tests/orchestration/helpers/gh-stub.sh`).

## 2. Version bump (SemVer — the release trigger)

- [ ] `plugins/orchestration/.claude-plugin/plugin.json` `version` is bumped in **this same PR**:
  - `fix` → patch (`x.y.Z`)
  - `feat` → minor (`x.Y.0`)
  - breaking change → major (`X.0.0`)
- [ ] The bump matches the highest-severity change in the PR (a PR with any `feat` is at least a minor bump).
- [ ] The `ganpan-orchestration` version sentinel and engine-internal names (`scripts/orchestration/`, `orchestration.json` config filename) are **unchanged** unless this is a deliberate, documented runtime-contract change.

## 3. Distribution surfaces still install

Ganpan ships four surfaces; a release must not break any of them.

- [ ] **Plugin** (`ganpan@laeyoung`): marketplace manifest points at `./plugins/orchestration` and parses (covered by §1).
- [ ] **Copy-in Claude** (`./install.sh <target>`): install path rewrites `${CLAUDE_PLUGIN_ROOT}/` → `./` (covered by `tests/install.bats`).
- [ ] **Copy-in Codex** (`./install.sh <target> --target codex`): installs `.agents/skills/ganpan-*` (covered by `tests/codex-skills.bats`).
- [ ] **Config discovery** unchanged: `$ORCH_CONFIG` → `./.ganpan/orchestration.json` → `./.claude/orchestration.json` (legacy).

## 4. Docs & changelog

- [ ] Shipped `assets/CLAUDE.md`, `README.md`, and `docs/SETUP.md` reflect any user-facing change (assets/CLAUDE.md is deploy output, not dev rules).
- [ ] A change record exists under `docs/log/YYYY-MM-DD-<slug>.md` capturing *what*, *why*, and *alternatives not chosen*.
- [ ] Conventional-commit history on the branch is clean (`type(scope): subject`, `Closes #<n>`).

## 5. Merge & post-merge verification

- [ ] Merge to `main` (human action per the merge gate; agents never approve/merge).
- [ ] Confirm the released version is now live on `main`:
      `gh api "repos/Laeyoung/Ganpan/contents/plugins/orchestration/.claude-plugin/plugin.json?ref=main" -H "Accept: application/vnd.github.raw" | jq -r .version`
      — this is the exact value `version-check.sh` reports to installed users.
- [ ] In a fresh checkout / test repo, run `/plugin` → update `ganpan@laeyoung` and confirm the new version resolves.
- [ ] Smoke-test one lane end-to-end (`/ganpan:triage` or `/ganpan:work-issue`) against a scratch issue.
