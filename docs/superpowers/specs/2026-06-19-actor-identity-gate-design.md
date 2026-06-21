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
2. **Configured bot** (`config.bot`, read in `lib.sh:14`) — used *only* to match the bot's own activity by login. Two distinct uses: the **comment-author** filter `select(.author.login == $BOT)` (`claim.sh:68,70,73`, `heartbeat.sh:15`, `reclaim.sh:22,31`) and the **assignee** filter `select(.login == $BOT)` (`claim.sh:62`). Bot writes are also addressed by `$BOT` for `--add-assignee`/`--remove-assignee` (`claim.sh:31,75`, `reclaim.sh:55`).

Nothing asserts `actor == config.bot`. The only auth gate is `gh auth status` (`orch-setup.md:12`), which passes for **any** authenticated account.

### Observed symptom

When an operator sets the toolkit up in a fresh repo and does **not** `export GH_TOKEN=github_pat_…`, `gh` falls back to the personal `gh auth login` account. All lane actions then run as that personal account instead of the bot — i.e. the toolkit "uses the logged-in user directly instead of the fine-grained PAT."

### Two failure modes this produces

- **F1 — Silent false-win, then broken recovery.** In the common (and most dangerous) misconfiguration — the operator's personal account, which is a repo collaborator/admin — a `claim.sh` run by the wrong actor still *succeeds*: the visibility check (`claim.sh:44-50`) matches on comment **body** only (not author), `--add-assignee "$BOT"` (line 31) succeeds because the actor has assignee-write permission so the assignee read-back at line 62 passes, and the tie-break (`claim.sh:68`, author-filtered) counts **zero** bot-authored tokens so it never fires — the script exits 0 and prints the issue number as a clean win. The damage surfaces later: `heartbeat.sh:15` (`author.login == $BOT`) finds no comment to patch and **exits 1**, and `reclaim.sh` can neither see nor reset the claim. Net effect is a falsely-claimed issue with no working heartbeat/reclaim — corruption, not a loud failure at claim time. (Edge case: a wrong actor *without* permission to assign `$BOT` fails the line-31 add silently (`log WARN … continuing`), then line 62's assignee read-back finds no `$BOT` and **exits 2** — a loud failure rather than a false-win. Either way the gate is the correct fix; the silent-corruption path is the one that motivates hard-blocking.)
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
  # Guard empty BOT: jq -er in load_config rejects null but NOT an empty JSON
  # string, so config.bot="" yields BOT="". Without this, an empty actor would
  # compare equal ([ "" != "" ] is false) and the gate would pass silently.
  [ -n "$BOT" ] || { log ERROR "config.bot is empty"; return 1; }
  local actor
  actor=$(gh api user --jq .login 2>/dev/null) \
    || { log ERROR "cannot resolve gh identity (gh authenticated?)"; return 1; }
  [ -n "$actor" ] || { log ERROR "gh api user returned empty login"; return 1; }
  if [ "$actor" != "$BOT" ]; then
    log ERROR "gh is acting as '$actor' but config.bot is '$BOT'."
    log ERROR "Export the bot PAT first:  export GH_TOKEN=github_pat_...  (HTTPS, not ssh)"
    return 1
  fi
}
```

Design points:
- **One `gh api user` call per script invocation.** Acceptable: lanes already make many API calls, and failing loudly *before* mutating GitHub is worth one read. See §7 for the `/loop` per-tick cost analysis.
- **Empty-value guards.** Both `$BOT` and `$actor` are asserted non-empty so a misconfigured (`""`) or unresolvable identity fails closed rather than passing the `[ "$a" != "$b" ]` comparison by accident.
- **Escape hatch `ORCH_SKIP_ACTOR_CHECK=1`** for environments where the actor is provably the bot (CI with the bot PAT injected) and the extra round-trip is unwanted. **Must be set per-invocation, never exported globally** (see §7) — a stray global export silently disables the gate and reintroduces F1/F2.
- Lives in `lib.sh` so it is identical across lanes and travels with the plugin subtree.

### 4.2 Call sites — full bot-write audit

A repo-wide grep for `gh issue (comment|edit|create)`, `gh pr create`, `gh label create`, and `gh api --method` shows bot writes are **not** confined to the engine scripts — the lane command markdown issues many writes inline. Every one of them runs as the resolved actor, so each is in scope. Gate placement: call `require_bot_actor` **after `load_config`** and **before the first state-mutating `gh` call**. All three engine scripts run a read-only `gh` call before their first write (`claim.sh:14` `gh issue list` → write at :29; `heartbeat.sh:11` `gh issue view` → write at :19; `reclaim.sh:9` `gh issue list` → writes at :49ff), so "after `load_config`" places the gate before any mutation in every case. Gating one read-only call later is harmless (no state changes); what matters is that no *write* precedes it.

| Write site | Writes | Gating |
|---|---|---|
| `claim.sh:29,31,32,75` | labels, assignee, claim comment | **engine** — add `require_bot_actor` after `load_config` |
| `heartbeat.sh:19` | PATCH claim comment | **engine** — add `require_bot_actor` after `load_config` |
| `reclaim.sh:49-56` | labels, remove assignee | **engine** — add `require_bot_actor` after `load_config` |
| `bootstrap-labels.sh:16` | `gh label create --force` | **see §4.3** — runs under `/orch-setup` (PAT may not exist yet); warn, do not hard-block |
| `triage.md:12` | label edits + clarifying-question comment | **lane** — add `require_bot_actor` preamble |
| `review-queue.md:16,17` | label edits, `rework-requested:` comment | **lane** — add `require_bot_actor` preamble |
| `work-issue.md:34,36` | `gh pr create`, label edits, `rework-resolved:` comment | **lane** — add `require_bot_actor` preamble |
| `qa-check.md:10,11,12,13` | label edits, `qa-fail-count:`/`rework-requested:` comments, `gh issue create` | **lane** — add `require_bot_actor` preamble |

**Engine scripts** call the helper directly. **Lane commands** that write inline (without routing through an engine script) gate via the bash preamble each lane *already* establishes for `project_sync` — they `source "${CLAUDE_PLUGIN_ROOT}/scripts/orchestration/lib.sh"` and `load_config`, after which a single added line

```bash
require_bot_actor || exit 1
```

placed before the lane's first write closes the gap. Because the gate is one line appended to an existing, already-duplicated preamble (not new boilerplate), the drift risk is minimal; there is **no** separate sourced snippet file — adding such a file would mean lanes source *two* files instead of one, with no benefit over the single line. Read-only lanes/paths (e.g. `wip-check.sh`, `detect-test-cmd.sh`, listing/viewing) are unaffected.

> Resolved (was an open question): the gate is **not** transitively inherited — `triage.md`, `review-queue.md`, `work-issue.md`, and `qa-check.md` each perform bot writes that never pass through `claim/heartbeat/reclaim`, so each needs its own explicit `require_bot_actor || exit 1` line in its existing `lib.sh`/`load_config` preamble.

### 4.2.1 `WORKER_ID` interaction

`WORKER_ID` is built as `"${BOT}-$(hostname)-$$-$RANDOM"` (`lib.sh:24`) and embedded in every claim-token body. Note this encodes the **configured** `$BOT`, while the comment's `author.login` is the **actual** actor — so under the F1 mismatch a token body can look bot-like while being author-mismatched. The gate makes this moot going forward (writes can't happen as the wrong actor). For **pre-existing** mismatched claim comments authored before this gate ships: `reclaim.sh`'s author filter already ignores them (they are not `author.login == $BOT`), so they neither block nor get reset — they are inert orphans. Implementation note: no automated cleanup is specified; if such comments exist they must be deleted manually. This is acceptable because the gate prevents new ones.

### 4.3 `/orch-setup` — warn, do not block

At setup time the bot PAT may legitimately not exist yet, so a hard failure is wrong. Strengthen step 1 (`orch-setup.md:9-13`) to surface the current actor and what is required:

```bash
gh auth status || { echo "gh not authenticated — run: GH_TOKEN=... or gh auth login"; exit 1; }
actor=$(gh api user --jq .login 2>/dev/null)
echo "ⓘ gh is currently acting as: ${actor:-<unknown>}"
echo "  After creating the bot PAT, run lanes with:  export GH_TOKEN=github_pat_..."
echo "  (must resolve to the bot account — NOT '${actor:-your personal login}')"
```

The existing manual-steps checklist (`orch-setup.md:43`ff, the bot-PAT and collaborator/branch-protection bullets) stays; this only makes the actor visible up front.

**`bootstrap-labels.sh` (§4.2 table):** it is invoked by `/orch-setup` step 4, when the bot account/PAT legitimately may not exist yet, so it follows this same warn-don't-block policy — it does **not** call `require_bot_actor`. Labels are repo-config, not bot activity, and are intentionally created by whoever runs setup (often the human operator). This keeps the gate scoped to *orchestration runtime* writes (claim/heartbeat/reclaim + the four lanes), not one-time setup.

### 4.4 Docs

- `README.md:80` and `orch-setup.md:44`: reframe `export GH_TOKEN=github_pat_…` from a *recommendation* to a **runtime precondition** — state that lanes hard-stop at the actor gate if the actor ≠ bot.
- `assets/CLAUDE.md` (shipped to target repos): note the gate so downstream operators understand the stop message, and document `ORCH_SKIP_ACTOR_CHECK=1` as a **per-invocation** escape hatch only (never a global export — see §7). (Editing this changes deploy output, per the repo gotcha — intended here.)

## 5. Behavior change summary

| Scenario | Before | After |
|---|---|---|
| Lane run, `GH_TOKEN`=bot PAT | works | works (gate passes) |
| Lane run, no `GH_TOKEN`, personal `gh login` ≠ bot | silently runs as human (F1/F2) | **hard error**, no GitHub mutation |
| Lane run in CI, `ORCH_SKIP_ACTOR_CHECK=1` | n/a | gate skipped, one fewer API call |
| `/orch-setup`, any auth | passes silently | passes, prints current actor + precondition |

## 6. Testing

**Prerequisite — extend `gh-stub.sh`.** The current stub deliberately omits `gh api` from its read-emitting `case` (it treats `gh api` as write-only — PATCH/DELETE — to avoid consuming a queued-response slot and desyncing the read index). So `gh api user --jq .login` returns **empty** under the stub today, and the gate cases below cannot pass as-is. Add a dedicated branch that echoes a configurable login **without** touching the `.idx` queue counter. Insert it as a **separate, standalone `case … esac` block** *above* the existing queue-emitting `case` (do **not** add the pattern to the existing `case "${1:-} ${2:-}"` — that case matches only two words, so `"api user "*` with its trailing space would never fire there):

```bash
# in gh-stub.sh, as its own block BEFORE the existing queue-emitting case.
# Three-word expansion so "api user "* matches `gh api user --jq .login`
# (after gh-stub strips argv[0], $1=api $2=user $3=--jq).
case "${1:-} ${2:-} ${3:-}" in
  "api user "*) echo "${GH_STUB_LOGIN-bot-login}"; exit "${GH_EXIT:-0}" ;;
esac
```

Tests then set `GH_STUB_LOGIN` to control the actor. Note the `-` (not `:-`) default: it substitutes `bot-login` only when `GH_STUB_LOGIN` is **unset**, so a test that sets `GH_STUB_LOGIN=""` gets an empty login back — which is exactly how the "empty login" gate case (below) is exercised. (`:-` would substitute the default on empty too, making that case untestable.) This keeps the read-response queue index intact (the stub's existing invariant).

Then use the existing harness: `setup_gh_stub` (from `helpers/common.bash`) copies `helpers/gh-stub.sh` onto `PATH`. `require_bot_actor` reads `$BOT` from `load_config`, so each case must establish a config (the existing `lib.bats` config fixtures) before calling it. New/extended cases:

`lib.bats` (the helper itself):
- `require_bot_actor` returns 0 when `gh api user` login == `$BOT`.
- returns non-zero with a clear message when login ≠ `$BOT`.
- returns non-zero when `$BOT` is empty (empty-string config) — the §4.1 guard.
- returns non-zero when `gh api user` prints an empty login.
- `ORCH_SKIP_ACTOR_CHECK=1` short-circuits to 0 **without** calling `gh`. The function returns at its first line, before reaching the `gh api user` call, so the stub binary is never executed for `api user` and `$GH_CALLS` records no such entry — that absence is the assertion. (The stub's unconditional `echo "$*" >> "$GH_CALLS"` logs only calls that actually reach the stub; a call the function never makes is never logged.)

Gate coverage for **all three** engine scripts (not just `claim.sh`): in `claim.bats`, `heartbeat.bats`, and `reclaim.bats`, add a case asserting the script aborts non-zero on actor mismatch **before** any mutating `gh` call (assert the stub recorded zero `gh issue edit` / `gh api --method PATCH` / `gh issue comment` invocations). Omitting heartbeat/reclaim would leave two of the three gated scripts without regression coverage.

Lane-preamble gating (§4.2) is markdown, not directly bats-testable; verify by inspection during review.

## 7. Risks & mitigations

- **Per-tick API cost under `/loop`.** Each lane tick can run `claim.sh` + `heartbeat.sh` + `reclaim.sh` → up to 3 extra `gh api user` calls/tick. GitHub's **primary** REST limit for authenticated requests is ~5000/hr; the **secondary** limits are per-minute (≈900 points/min for REST). Three `api user` reads per tick at the documented cadences (Triager `/loop 10m`, Reviewer `/loop 5m`, Coder `/loop`) sit far under both. Worst case is a Coder looping with no delay — there the per-issue work dwarfs one cheap `api user` read, and operators who still want it gone use `ORCH_SKIP_ACTOR_CHECK=1` with a verified bot PAT. Cross-tick caching (§8) remains the longer-term optimization but is not required for correctness.
- **`ORCH_SKIP_ACTOR_CHECK` re-introduces the bug if abused.** A globally-exported `ORCH_SKIP_ACTOR_CHECK=1` (in `.bashrc`, a CI org secret, etc.) silently disables the gate everywhere → F1/F2 return. Mitigation: the §4.1 comment and the docs (§4.4) state it must be set **per-invocation only** (e.g. `ORCH_SKIP_ACTOR_CHECK=1 some-lane`), never exported. Considered failing the gate if the var is exported-and-actor-mismatched, but that is unenforceable from bash; documentation is the mitigation.
- **`gh api user` vs comment `author.login` casing.** GitHub logins are case-insensitive but echoed canonically, so comparing exact strings from the same API surface is normally safe. **Coupling caveat:** if a casing discrepancy is ever observed and normalization is applied, it must be confined to the §4.1 gate comparison — the downstream `select(.author.login == $BOT)` filters (claim/heartbeat/reclaim) consume the **raw config `$BOT`**, so lower-casing `$BOT` only in the gate would not desync them, but lower-casing the stored config value would. Rule: never mutate the config `$BOT`; normalize only locally inside `require_bot_actor` if needed.
- **Bot is a GitHub App, not a user.** App tokens don't resolve via `gh api user` the same way. Out of scope for v1 (toolkit targets a bot *user* + fine-grained PAT); note as a future consideration (§8).

## 7.1 Backward compatibility & pre-merge verification

- **No behavior change for correctly-configured users** (§5 row 1): operators already exporting the bot PAT pass the gate unchanged. No migration step is required; the only newly-failing case is the already-broken misconfiguration this spec targets.
- **Pre-merge gate (per `CLAUDE.md`):** before the human merges, the branch must pass `bats tests/orchestration/ tests/install.bats` (including the new gate cases) and `shellcheck plugins/orchestration/scripts/orchestration/*.sh` (covers the new `require_bot_actor` function). Agents do not merge — a human reviews and merges behind branch protection.

## 8. Out of scope / future

- GitHub App–based bots (vs. user PAT).
- Validating PAT scope/expiry programmatically.
- Caching the actor check across a `/loop` session to avoid per-tick calls.
