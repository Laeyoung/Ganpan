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
2. Check for label drift — an upgrade can add a status label an existing install never received, since labels are bootstrapped only once at setup (#81):
   ```bash
   scripts/orchestration/labels-check.sh
   ```
   Read-only; exits 1 on drift and names the missing labels. Show its output; a non-zero exit is a finding to report, not an error to retry.
3. Tell the user whether an update is available and that they run the printed step themselves (plugin: `/plugin`; copy-in: re-run `install.sh … --force`). On `DRIFT`, add that they should re-run `scripts/orchestration/bootstrap-labels.sh .github/labels.yml` after updating — it is idempotent, so it is safe either way. Never run the updater or the bootstrap for them.
