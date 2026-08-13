# Removed the dead `SCRIPT_DIR` export that warned under zsh (#86)

- **Date:** 2026-08-13
- **Issue / PR:** #86
- **Type:** fix

## What changed
Deleted lines 5–6 of `plugins/orchestration/scripts/orchestration/lib.sh`:

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPT_DIR
```

Replaced them with a comment recording *why* they must not come back. Added three bats
cases to `tests/orchestration/lib.bats`: zsh sourcing emits nothing on stderr, zsh sourcing
still yields working helpers, and `lib.sh` defines no `SCRIPT_DIR` (both by grep and by
observing it unset after a bash source). The zsh cases `skip` where zsh is absent.
Bumped the plugin 1.15.0 → 1.15.1.

## Why
`BASH_SOURCE` does not exist in zsh, and `lib.sh` arms `set -euo pipefail` on line 3 for the
**sourcing** shell — so the reference warned regardless of the caller's own options:

```
$ zsh -c 'source .../lib.sh; echo "[$SCRIPT_DIR]"'
lib.sh:5: BASH_SOURCE[0]: parameter not set
[/Users/…/ganpan]        # cwd — the wrong value, silently exported
```

Functional impact was zero (all 16 engine scripts are `#!/usr/bin/env bash`, and nothing
read the variable), but the lane commands instruct agents to `source .../lib.sh`, so under a
zsh operator shell every lane start left an error-looking line on stderr. That noise has a
real cost: in the 2026-08-13 `/run-all` sweep the Reviewer lane read this warning and
misdiagnosed it as "real breakage for anyone sourcing under `set -u`" (it is unrelated to the
caller's `set -u`). Removing the line removes both the noise and the bogus exported value.

## Key decisions
- **Delete rather than guard with `${BASH_SOURCE[0]:-$0}`.** `SCRIPT_DIR` was dead code:
  `grep -rn SCRIPT_DIR` over the whole repo returns only the two definition lines in `lib.sh`
  plus historical `docs/superpowers/` specs and plans. Every engine script already computes
  its own `DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"` before sourcing `lib.sh`.
  Guarding would keep dead code alive and still export a wrong-under-zsh path.
- **Leave a do-not-reintroduce comment plus a grep-based test**, not just the deletion. The
  variable was originally part of the design (`docs/superpowers/specs/2026-06-09-…` §5.1) and
  a future reader could restore it from those docs without knowing the cost.
- **Patch, not minor.** `SCRIPT_DIR` was exported, so removing it is technically observable —
  but nothing in ganpan or its install surfaces reads it, and it carried a wrong value in the
  one shell where its absence could be noticed. Treated as the bug fix the issue filed it as.
- **Did not rewrite the historical specs/plans** that still describe `SCRIPT_DIR`. Those record
  the design as it was at the time; `docs/log/` is where what-actually-shipped lives.

## Alternatives considered (not chosen)
- **`${BASH_SOURCE[0]:-$0}` guard** — the issue's own second choice; keeps dead code.
- **Drop `set -euo pipefail` from `lib.sh`** so the caller's options govern. Far larger blast
  radius: every script that sources it relies on those options being armed.
- **Add `emulate -L bash` / a zsh branch.** Complexity for a variable nobody reads.
- **Document "run lanes under bash" instead of fixing it.** Pushes an avoidable constraint onto
  every operator, and the misdiagnosis this caused shows the noise is not free.
