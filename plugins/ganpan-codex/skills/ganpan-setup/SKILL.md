---
name: ganpan-setup
description: Set up Ganpan conventions, config, labels, and human security checklist for a target repository.
---

# Ganpan Setup

Use this skill from the target repository root. This skill pins ganpan **v1.17.0**.

1. Read `references/setup.md`.
2. Verify prerequisites: `gh`, `git`, `jq`, and `yq` — plus `node` (≥ 18) and `bash` for the engine installer.
3. Install or check the engine:
   - First pick the target for the agent host you are running in, so the repo gets conventions that host reads:
     - Claude Code → `--target claude` (`CLAUDE.md` conventions + `.claude/commands`; Claude Code does not read `AGENTS.md`)
     - Antigravity → `--target antigravity`
     - Codex, Cursor and other `AGENTS.md` readers → `--target codex` (the default)
     - Several hosts in one repo → `--target both` (Claude + Codex) or `--target all`
   - If `scripts/orchestration/lib.sh` is missing, install it (engine scripts, the target's skills/commands and conventions file, `.ganpan/orchestration.json` template, labels, issue template):
     ```bash
     npx -y github:Laeyoung/Ganpan#v1.17.0 init --target <target>
     ```
   - If it exists but the version stamped on the last line of `lib.sh` is not `v1.17.0`, report the drift and give the user this command to run themselves — never run `--force` yourself; it overwrites sentinel-stamped engine files:
     ```bash
     npx -y github:Laeyoung/Ganpan#v1.17.0 init --force
     ```
     Then continue setup against the installed engine.
   - If `npx` fails because the ref `v1.17.0` cannot be found, v1.17.0 is not tagged yet (the tag is pushed by the maintainer's release step after the merge). Report that, ask the user to retry later or install from a ganpan checkout with `./install.sh <repo> --target codex`, and stop. Do not fall back to `main` or another unpinned ref.
4. Prefer `.ganpan/orchestration.json` for new installs. Legacy `.claude/orchestration.json` remains a fallback.
5. Bootstrap labels and issue templates only from repo-owned files.
6. Check the result — each `FAIL` line names what is still missing (e.g. `repo`/`bot` placeholders):
   ```bash
   npx -y github:Laeyoung/Ganpan#v1.17.0 validate
   ```
7. Print human security steps; do not create tokens or change branch protection yourself.

Do not print token values or full environment output.
