---
name: ganpan-setup
description: Set up Ganpan conventions, config, labels, and human security checklist for a target repository.
---

# Ganpan Setup

Use this skill from the target repository root. This skill pins ganpan **v1.16.0**.

1. Read `references/setup.md`.
2. Verify prerequisites: `gh`, `git`, `jq`, and `yq` — plus `node` (≥ 18) and `bash` for the engine installer.
3. Install or check the engine:
   - If `scripts/orchestration/lib.sh` is missing, install it (default `--target codex`: engine scripts, `.agents/skills/ganpan-*`, `AGENTS.md`, `.ganpan/orchestration.json` template, labels, issue template; pass `--target claude|antigravity|both|all` for other surfaces):
     ```bash
     npx -y github:Laeyoung/Ganpan#v1.16.0 init
     ```
   - If it exists but the version stamped on the last line of `lib.sh` is not `v1.16.0`, report the drift and give the user this command to run themselves — never run `--force` yourself; it overwrites sentinel-stamped engine files:
     ```bash
     npx -y github:Laeyoung/Ganpan#v1.16.0 init --force
     ```
     Then continue setup against the installed engine.
4. Prefer `.ganpan/orchestration.json` for new installs. Legacy `.claude/orchestration.json` remains a fallback.
5. Bootstrap labels and issue templates only from repo-owned files.
6. Check the result — each `FAIL` line names what is still missing (e.g. `repo`/`bot` placeholders):
   ```bash
   npx -y github:Laeyoung/Ganpan#v1.16.0 validate
   ```
7. Print human security steps; do not create tokens or change branch protection yourself.

Do not print token values or full environment output.
