# npx surface follow-ups: version-pin guard, validate read errors, tag refspec, host target

- **Date:** 2026-10-06
- **Issue / PR:** — / (this PR)
- **Type:** fix
- **Version:** 1.16.0 → 1.16.1 (fix → patch)

## What changed
The deferred minors from the PR #90 final review:
- **Version-pin guard:** a new `tests/codex-skills.bats` case requires every `vX.Y.Z` in
  `ganpan-setup/SKILL.md` *and* every `github:Laeyoung/Ganpan#vX.Y.Z` in `README.md` to equal
  `plugin.json`. Before this, the README pins and the prose mentions ("pins ganpan vX", "ref vX
  cannot be found") were unguarded and would have gone stale on the next bump.
- **`ganpan validate` read errors:** a `scripts/orchestration/lib.sh` that is not a regular file
  is now a `FAIL` (previously an uncaught `EISDIR` stack trace). A config that cannot be read
  reports `cannot read config: <path> (<code>)` instead of "config is not valid JSON".
- **`scripts/release.sh`** pushes `refs/tags/vX.Y.Z` rather than the bare tag name, so a branch
  that is also named `vX.Y.Z` no longer makes the push ambiguous. The dry-run output and the
  playbook show the same refspec.
- **`ganpan-setup` host → `--target` mapping:** Claude Code → `claude`; Antigravity →
  `antigravity`; Codex, Cursor and other `AGENTS.md` readers → `codex`; mixed hosts → `both`/`all`.
  The default `codex` writes `AGENTS.md`, which Claude Code does not read.

## Why
These were real but low-impact gaps that the #90 review deferred so as not to widen that PR.
Bundling them gives one patch release (and one `release.sh` tag) instead of four.

## Key decisions
- **Guard every version mention in the setup skill, not only the npx pins.** The prose versions
  instruct the agent, so a stale one misleads it just as much as a stale pin.
- **Read errors and parse errors are separate FAILs.** The fix for "permissions/EISDIR" is
  different from the fix for "bad JSON", so the message should say which one happened.
- **The skill names the host → target mapping rather than auto-detecting the host.** An agent
  knows which host it is running in; the CLI does not.

## Alternatives considered (not chosen)
- Removing the version from the README (writing `#vX.Y.Z`) — copy-pasteable commands are more
  useful, and the test now keeps them current.
- Defaulting `init` to `--target claude` — that would break the Codex/Cursor majority that
  `npx skills` targets; the mapping in the skill covers Claude Code instead.
