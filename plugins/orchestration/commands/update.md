---
description: Advisory — show installed vs latest ganpan version and the exact update steps (never changes your repo).
---

You are running the **advisory** `/ganpan:update`. It is **read-only**: it reports the install mode, the installed vs latest ganpan version, and the exact steps for the user to run. It never updates anything itself.

Run the advisory and show its output verbatim:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/orchestration/update-info.sh
```

Then, in one or two sentences, tell the user whether an update is available and that they must run the printed step themselves (plugin installs update via `/plugin`; copy-in installs re-run `install.sh … --force`). Do **not** run `install.sh`, `/plugin`, or any update action on their behalf.
