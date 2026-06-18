# Actor Identity Gate — Design Spec

**Date:** 2026-06-19
**Status:** Draft (pending review)
**Branch:** `fix-gt-token`
**Builds on:** `docs/superpowers/specs/2026-06-18-orchestration-plugin-design.md` (plugin + `/orch-setup`)

## 1. Goal

Guarantee that every orchestration write to GitHub is performed **as the configured bot account (`config.bot`)** — never silently as the human operator's personal `gh` login. Catch the misconfiguration at setup time (warning) and hard-block it at lane runtime (error), before any state is mutated.

## 2. Problem

The toolkit uses two independent notions of identity that nothing verifies are the same:

1. **Actor** — the credential `gh` resolves when running `gh issue …` / `gh api …`. Precedence: `GH_TOKEN` / `GITHUB_TOKEN` env var → `gh auth login` keychain credential.
2. **Configured bot** (`config.bot`, read in `lib.sh:14`) — used *only* to filter comments by author: `select(.author.login == $BOT)` in `claim.sh:62,68,70,73`, `heartbeat.sh:15`, `reclaim.sh:22,31,55`.

Nothing asserts `actor == config.bot`. The only auth gate is `gh auth status` (`orch-setup.md:12`), which passes for **any** authenticated account.

### Observed symptom

When an operator sets the toolkit up in a fresh repo and does **not** `export GH_TOKEN=github_pat_…`, `gh` falls back to the personal `gh auth login` account. All lane actions then run as that personal account instead of the bot — i.e. the toolkit "uses the logged-in user directly instead of the fine-grained PAT."

### Two failure modes this produces

- **F1 — Silent functional breakage.** Claim comments are authored by the personal login, but claim/heartbeat/reclaim match `author.login == $BOT`. Claims never match → claim-race tie-break, heartbeat patching, and reclaim recovery all break, with **no error surfaced** (the writes succeed; only the matching fails).
- **F2 — Merge-gate / security-model collapse.** The model in `CLAUDE.md` (and the `/orch-setup` checklist) assumes the bot is **not** an admin and that a human reviews+merges. If bot work executes under the operator's account — which is typically an admin/owner — that separation is void: the same identity that produces PRs can approve and merge them. This is the more serious failure.

## 3. Non-goals

- **Auto-deriving `config.bot` from the current `gh` identity.** Rejected: it would freeze the personal account in as the bot and re-create the exact trap. `config.bot` stays explicit.
- **Managing or validating PAT scopes** (Contents/PR/Issues/Projects RW). Out of scope; remains a human checklist item in `/orch-setup`.
- **Changing how config is discovered or how tokens are supplied.** We verify identity; we do not change the auth mechanism.

## 4. Design

### 4.1 Shared helper in `lib.sh`

Add a single source-of-truth gate, callable by any script after `load_config`:

```bash
# require_bot_actor — assert the gh actor matches config.bot before any write.
# Escape hatch: ORCH_SKIP_ACTOR_CHECK=1 (e.g. CI where the bot PAT *is* the actor
# and the extra API call is undesirable).
require_bot_actor() {
  [ "${ORCH_SKIP_ACTOR_CHECK:-}" = "1" ] && return 0
  local actor
  actor=$(gh api user --jq .login 2>/dev/null) \
    || { log ERROR "cannot resolve gh identity (gh authenticated?)"; return 1; }
  if [ "$actor" != "$BOT" ]; then
    log ERROR "gh is acting as '$actor' but config.bot is '$BOT'."
    log ERROR "Export the bot PAT first:  export GH_TOKEN=github_pat_...  (HTTPS, not ssh)"
    return 1
  fi
}
```

Design points:
- **One `gh api user` call per script invocation.** Acceptable: lanes already make many API calls, and failing loudly *before* mutating GitHub is worth one read.
- **Escape hatch `ORCH_SKIP_ACTOR_CHECK=1`** for environments where the actor is provably the bot (CI with the bot PAT injected) and the extra round-trip is unwanted.
- Lives in `lib.sh` so it is identical across lanes and travels with the plugin subtree.

### 4.2 Call sites — write-performing scripts only

Invoke `require_bot_actor` immediately after `load_config`, **before the first mutating `gh` call**, in scripts that write as the bot:

- `claim.sh` — writes labels, assignee, claim comment.
- `heartbeat.sh` — PATCHes the claim comment.
- `reclaim.sh` — edits labels / removes assignee.

Read-only paths are unaffected. The lane command markdown (`work-issue.md`, `triage.md`, `review-queue.md`, `qa-check.md`) inherits the gate transitively through the scripts they call; no separate check is added there unless a lane performs a bot write **without** going through one of the gated scripts (audit during implementation — e.g. inline `gh issue comment "rework-requested:"` in `review-queue.md`).

> Open implementation question: lanes that post comments inline (e.g. `rework-requested:` in `review-queue.md`) bypass the gated scripts. Resolve during implementation by either routing those through a gated helper or adding an explicit `require_bot_actor` preamble to the lane.

### 4.3 `/orch-setup` — warn, do not block

At setup time the bot PAT may legitimately not exist yet, so a hard failure is wrong. Strengthen step 1 (`orch-setup.md:9-13`) to surface the current actor and what is required:

```bash
gh auth status || { echo "gh not authenticated — run: GH_TOKEN=... or gh auth login"; exit 1; }
actor=$(gh api user --jq .login 2>/dev/null)
echo "ⓘ gh is currently acting as: ${actor:-<unknown>}"
echo "  After creating the bot PAT, run lanes with:  export GH_TOKEN=github_pat_..."
echo "  (must resolve to the bot account — NOT '${actor:-your personal login}')"
```

The existing manual-steps checklist (`orch-setup.md:43-46`) stays; this only makes the actor visible up front.

### 4.4 Docs

- `README.md:80` and `orch-setup.md:44`: reframe `export GH_TOKEN=github_pat_…` from a *recommendation* to a **runtime precondition** — state that lanes hard-stop at the actor gate if the actor ≠ bot.
- `assets/CLAUDE.md` (shipped to target repos): note the gate so downstream operators understand the stop message. (Editing this changes deploy output, per the repo gotcha — intended here.)

## 5. Behavior change summary

| Scenario | Before | After |
|---|---|---|
| Lane run, `GH_TOKEN`=bot PAT | works | works (gate passes) |
| Lane run, no `GH_TOKEN`, personal `gh login` ≠ bot | silently runs as human (F1/F2) | **hard error**, no GitHub mutation |
| Lane run in CI, `ORCH_SKIP_ACTOR_CHECK=1` | n/a | gate skipped, one fewer API call |
| `/orch-setup`, any auth | passes silently | passes, prints current actor + precondition |

## 6. Testing

Extend `tests/orchestration/` (bats):
- `require_bot_actor` returns 0 when `gh api user` login == `$BOT`.
- returns non-zero with a clear message when login ≠ `$BOT`.
- `ORCH_SKIP_ACTOR_CHECK=1` short-circuits to 0 without calling `gh`.
- `claim.sh` aborts **before** any `gh issue edit` when the gate fails (assert no mutation attempted — mock `gh`).

Mock `gh` via a stub on `PATH` (existing test pattern) so `gh api user` returns a controllable login.

## 7. Risks & mitigations

- **Extra API call per lane tick.** Mitigated by the cheap single `gh api user` read and the `ORCH_SKIP_ACTOR_CHECK` escape hatch.
- **`gh api user` differs from comment `author.login` casing.** GitHub logins are case-insensitive but echoed canonically; compare exact strings from the same API surface. If observed, normalize with `tr '[:upper:]' '[:lower:]'` on both sides.
- **Bot is a GitHub App, not a user.** App tokens don't resolve via `gh api user` the same way. Out of scope for v1 (toolkit targets a bot *user* + fine-grained PAT); note as a future consideration.

## 8. Out of scope / future

- GitHub App–based bots (vs. user PAT).
- Validating PAT scope/expiry programmatically.
- Caching the actor check across a `/loop` session to avoid per-tick calls.
