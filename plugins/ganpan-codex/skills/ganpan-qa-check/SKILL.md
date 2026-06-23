---
name: ganpan-qa-check
description: Verify Ganpan status:qa issues after merge and route them to status:done, status:in-progress, or status:blocked.
---

# Ganpan QA Check

Use this skill from the target repository root.

1. Read `references/qa-check.md`.
2. Capture `REPO_ROOT="$PWD"`.
3. Resolve config once from the main checkout:
   ```bash
   source scripts/orchestration/lib.sh
   CFG="$(resolve_config_path "$REPO_ROOT")"
   ORCH_CONFIG="$CFG" load_config
   ```
4. Use `ORCH_CONFIG="$CFG" scripts/orchestration/detect-test-cmd.sh test` when running checks from any directory.
5. Follow the lane protocol exactly and include QA evidence in issue comments or final output.

Only bot-authored QA markers count. Do not print secrets.
