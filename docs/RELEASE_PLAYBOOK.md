# Ganpan release playbook

How a change reaches installed users, step by step. Pair this with
[`RELEASE_CHECKLIST.md`](./RELEASE_CHECKLIST.md) (the tick-box gate).

## The release model (read this first)

Ganpan has **no separate release artifact**. There are no git tags, no GitHub
Releases, and no build step. The release *is* the merge to `main`:

```
feature branch ──(bump plugin.json version)──▶ PR ──(human merge)──▶ main
                                                                       │
                        marketplace `laeyoung` pulls main ◀────────────┘
                                                                       │
                    installed users see the new version on `/plugin` ◀─┘
```

- The `laeyoung` marketplace `source` is `./plugins/orchestration`, resolved
  from the repo's `main` branch.
- Installed clients discover updates via `version-check.sh`, which reads
  `.version` from `plugins/orchestration/.claude-plugin/plugin.json` at
  `?ref=main`. **That `version` field on `main` is the released version.**
- Consequence: a merge that does not bump `version` is invisible to users, and
  a broken merge to `main` ships to everyone on their next `/plugin` update.
  Treat `main` as production.

## Step-by-step

### 1. Prepare the change on a branch
- Follow the normal workflow (issue → `issue-<n>` branch/worktree → implement).
- For non-trivial work, land the Spec/Plan under `docs/superpowers/` first.

### 2. Bump the version (same PR as the change)
Edit `plugins/orchestration/.claude-plugin/plugin.json`:
- `fix` → patch, `feat` → minor, breaking → major.
- Never touch engine-internal names or the `ganpan-orchestration` sentinel
  unless the runtime contract is intentionally changing.

### 3. Run the quality gates locally
```bash
bats tests/*.bats tests/orchestration/*.bats
shellcheck plugins/orchestration/scripts/orchestration/*.sh
jq . .claude-plugin/marketplace.json plugins/orchestration/.claude-plugin/plugin.json
```
All three must be clean. These are the same gates in the checklist §1.

### 4. Record the change
Add `docs/log/YYYY-MM-DD-<slug>.md` (what / why / alternatives-not-chosen) and
update `README.md` / `docs/SETUP.md` / `assets/CLAUDE.md` if user-facing.

### 5. Open the PR and let the lanes run
- Open the PR (`Closes #<n>`). The Reviewer lane may auto-merge only when its
  verdict is "proceed" **and** the PR is OPEN + mergeable + `mergeStateStatus == CLEAN`
  (this repo sets `reviewer.autoMerge: true` and `main` has no branch
  protection). Agents never *approve*.
- To re-impose a human merge gate: flip `reviewer.autoMerge` back to `false`
  **or** add branch protection on `main` (then `auto-merge.sh` returns
  `protected` and requests a human merge).

### 6. Merge to `main`
This is the release. After merge, verify the version is live:
```bash
gh api "repos/Laeyoung/Ganpan/contents/plugins/orchestration/.claude-plugin/plugin.json?ref=main" \
  -H "Accept: application/vnd.github.raw" | jq -r .version
```
The value returned is exactly what installed users' `version-check.sh` will
report as "latest."

### 7. Verify the release reached users
- Fresh checkout / scratch repo: `/plugin` → update `ganpan@laeyoung`; confirm
  the new version resolves and commands namespace as `/ganpan:*`.
- Copy-in path: `./install.sh <scratch-repo>` (and `--target codex` / `--target both` / `--target antigravity`)
  installs without error.
- Smoke-test one lane end-to-end against a throwaway issue.

## Rollback

There is no tag to revert to; roll back the same way you shipped:
1. `git revert` the offending merge commit on `main` (or a fast follow-up fix).
2. **Bump the version again** in the revert/fix PR — a rollback that keeps the
   same `version` will not propagate to clients whose cache already keys on it.
3. Merge, then re-run step 7 to confirm clients pick up the corrected version.

## Surfaces to keep in sync

| Surface | Ships via | Guarded by |
|---|---|---|
| Plugin (`ganpan@laeyoung`) | marketplace pull of `main` | `jq` manifest validation |
| Copy-in Claude | `./install.sh <target>` | `tests/install.bats` |
| Copy-in Codex | `./install.sh <target> --target codex` | `tests/codex-skills.bats` |
| Copy-in Antigravity | `./install.sh <target> --target antigravity` | `tests/antigravity.bats` |
| Config discovery | `$ORCH_CONFIG` → `.ganpan/` → `.claude/` (legacy) | `tests/orchestration/lib.bats` |

## Current release readiness

As of this document (see the accompanying `docs/log/` entry for the run):
`bats` = 204/204 passing, `shellcheck` = clean, manifests = valid. The toolkit
is at release-worthy quality; use the checklist above for each ship.
