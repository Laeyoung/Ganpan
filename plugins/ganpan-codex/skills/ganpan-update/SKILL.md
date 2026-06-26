---
name: ganpan-update
description: Advisory — report installed vs latest ganpan version and the exact per-mode update steps. Read-only; never performs the update.
---

# Ganpan Update (advisory)

Use this skill from the target repository root. It is **read-only** — it reports versions and the steps to update, and never performs the update.

1. Run the advisory and show its output:
   ```bash
   scripts/orchestration/update-info.sh
   ```
2. Tell the user whether an update is available and that they run the printed step themselves (plugin: `/plugin`; copy-in: re-run `install.sh … --force`). Never run the updater for them.
