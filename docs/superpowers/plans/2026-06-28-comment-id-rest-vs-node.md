# Fix comment-id REST/node mismatch — Implementation Plan

Spec: `docs/superpowers/specs/2026-06-28-comment-id-rest-vs-node.md`
Issue: #68

## Files

- `plugins/orchestration/scripts/orchestration/heartbeat.sh`
- `plugins/orchestration/scripts/orchestration/claim.sh`
- `tests/orchestration/heartbeat.bats` (rewrite 3 fixtures to REST shape)
- `tests/orchestration/claim.bats` (add a `queue_response` to the 2 loss tests)
- `plugins/orchestration/.claude-plugin/plugin.json` (version bump, fix → patch)
- `docs/log/2026-06-28-comment-id-rest-vs-node.md` (new)

## Step 1 — heartbeat.sh

Replace the comment fetch + id selection (lines ~12–18):

- Remove `view=$(gh issue view "$issue" --json comments --repo "$REPO") || …`
  and the `cid=$(echo "$view" | jq … .comments[] … max_by(.body).id …)`.
- New: fetch the comments with explicit failure handling (no swallowed error),
  then source the **numeric** id of the newest claim, using the codebase's
  established `--paginate | jq -s 'add // []'` page-merge pattern (see
  `trusted-answers.sh`):
  ```bash
  comments=$(gh api --paginate "/repos/$REPO/issues/$issue/comments") \
    || { log ERROR "comment list failed on #$issue"; exit 1; }
  cid=$(printf '%s\n' "$comments" | jq -s -r 'add // [] | .[]
          | select(.user.login=="'"$BOT"'" and (.body|startswith("claim: ")))
          | [.body, (.id|tostring)] | @tsv' | sort | tail -n1 | cut -f2)
  [ -z "$cid" ] && { log ERROR "no claim comment on #$issue"; exit 1; }
  ```
  Notes: `gh api --jq` does **not** support jq `--arg`; embed `$BOT` via shell
  single-quote interpolation. REST comment objects use `.user.login` (not
  `.author.login`). Separating the fetch from the `jq` keeps `set -euo pipefail`
  from silently aborting on an API error, and `jq -s 'add // []'` merges the
  multiple JSON arrays `--paginate` emits (and works for the single-page stub).
- Keep the existing `token=…` line and the `gh api --method PATCH
  /repos/$REPO/issues/comments/$cid -f body="claim: $token"` line unchanged —
  it now gets a numeric id.

Stdout stays clean (only the final return tokens / `log` to stderr); the PATCH
already redirects to `>/dev/null`.

## Step 2 — claim.sh

At **both** loser-cleanup sites (the token-tie-break loss ~86–87 and the
assignee-re-add rollback ~107–108), replace:
```bash
cid=$(echo "$view" | jq -r --arg b "$BOT" --arg t "$token" 'first(.comments[] | select(.author.login==$b and .body==("claim: "+$t)) | .id) // empty')
[ -n "$cid" ] && gh api --method DELETE "/repos/$REPO/issues/comments/$cid" >/dev/null 2>&1 || true
```
with a numeric-id lookup via the paginated REST list (exact match is unique, so
`head -1` suffices). The exact body match uses a **single** jq string literal
`"claim: <token>"` — no `+` concatenation, since adjacent jq string literals are
a parse error. Cleanup is best-effort, so guard the assignment with `|| cid=""`
so a transient API/jq error can't abort the loss path before the assignee-release
and `exit 2`:
```bash
cid=$(gh api --paginate "/repos/$REPO/issues/$issue/comments" 2>/dev/null \
       | jq -s -r 'add // [] | .[]
           | select(.user.login=="'"$BOT"'" and .body=="claim: '"$token"'") | .id' \
       | head -n1) || cid=""
[ -n "$cid" ] && gh api --method DELETE "/repos/$REPO/issues/comments/$cid" >/dev/null 2>&1 || true
```
The body-only winner/tie-break logic (using `$view`) is unchanged. No other lines
change.

## Step 3 — tests

`heartbeat.bats`: rewrite the three `queue_response` fixtures from
`{"comments":[{"id":N,"author":{"login":"botx"},"body":…}]}` to the REST list
shape `[{"id":N,"user":{"login":"botx"},"body":…}]`. The assertions
(`api --method PATCH /repos/o/r/issues/comments/<N>`) stay; `<N>` stays numeric.
Confirm the "newest" test still asserts id 200 and not 100, and the "no claim
comment" test still exits 1 with a REST-shaped array containing only a non-claim
comment.

`claim.bats`: in the two loss tests (token-tie-break loss; assignee-re-add
rollback), add one `queue_response` (REST list array containing the bot's claim
comment with a numeric `id` matching the existing DELETE assertion) for the new
`gh api --paginate …/comments` read that now precedes the DELETE. Keep the
existing `DELETE /repos/o/r/issues/comments/<id>` assertions. Order the queued
responses to match call order (the existing issue-view/list reads, then the new
comments read at the loss point).

Note on the stub: `gh api --paginate …` (no `--method` write verb) is treated as
a read and consumes exactly one queued slot, regardless of `--paginate`. The
stub returns a single page, so the shell `sort|tail|cut` / `head -1` resolve the
id from that one page.

## Step 4 — version bump

`plugins/orchestration/.claude-plugin/plugin.json`: bump patch (fix). Take the
current value at implementation time and increment the patch component.

## Step 5 — log

`docs/log/2026-06-28-comment-id-rest-vs-node.md`: root cause (node id vs REST
numeric), the fix, why tests missed it (unrealistic fixtures), the pagination
hardening, rejected GraphQL alternative, and the #64 operational cleanup note
(blocked for the lane by the write-classifier; needs a permitted actor).

## Verification

```bash
bats tests/*.bats tests/orchestration/*.bats
shellcheck plugins/orchestration/scripts/orchestration/*.sh
jq . plugins/orchestration/.claude-plugin/plugin.json
```
All green; `heartbeat.bats` + `claim.bats` pass with REST-shaped fixtures.

## Risks

- **No jq `--arg` on `gh api`:** `gh api --jq` does not support `--arg`; `$BOT`
  and `$token` are embedded via shell single-quote interpolation. Watch the
  quoting (`'"$BOT"'`) carefully in both scripts.
- **`@tsv` body ordering for heartbeat:** the claim body is an ISO-timestamp
  token, so lexical `sort | tail -1` correctly yields the newest — matches the
  prior `max_by(.body)` semantics.
- **`.user.login` vs `.author.login`:** REST uses `.user`. Get this right in
  both scripts (heartbeat currently uses `.author`).
- **Call-order coupling in claim.bats:** the new queued response must sit at the
  exact point in the read sequence where the loss-path REST read fires.
