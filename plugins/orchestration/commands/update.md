---
description: Advisory — show installed vs latest ganpan version and the exact update steps (never changes your repo).
---

You are running the **advisory** `/ganpan:update`. It is **read-only**: it reports the install mode, the installed vs latest ganpan version, and the exact steps for the user to run. It never updates anything itself.

Run the advisory and show its output verbatim:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/orchestration/update-info.sh
```

Then check for label drift — an upgrade can add a status label that an existing install never received, because labels are bootstrapped only once at setup (#81):

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/orchestration/labels-check.sh
```

It is read-only and exits 1 on drift, naming the missing labels. Show its output verbatim too; a non-zero exit here is a finding to report, not an error to retry.

Then, in one or two sentences, tell the user whether an update is available and that they must run the printed step themselves (plugin installs update via `/plugin`; copy-in installs re-run `install.sh … --force`). If `labels-check.sh` reported `DRIFT`, add that they should re-run `bootstrap-labels.sh .github/labels.yml` **after** updating — it is idempotent, so it is safe either way. Do **not** run `install.sh`, `/plugin`, `bootstrap-labels.sh`, or any update action on their behalf.
