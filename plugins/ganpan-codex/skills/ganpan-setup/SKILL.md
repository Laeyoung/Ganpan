---
name: ganpan-setup
description: Set up Ganpan conventions, config, labels, and human security checklist for a target repository.
---

# Ganpan Setup

Use this skill from the target repository root.

1. Read `references/setup.md`.
2. Verify prerequisites: `gh`, `git`, `jq`, and `yq`.
3. Prefer `.ganpan/orchestration.json` for new Codex installs. Legacy `.claude/orchestration.json` remains a fallback.
4. Bootstrap labels and issue templates only from repo-owned files.
5. Print human security steps; do not create tokens or change branch protection yourself.

Do not print token values or full environment output.
