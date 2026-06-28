# Fix comment-id REST/node-id mismatch in claim.sh & heartbeat.sh (#68)

- **Date:** 2026-06-28
- **Issue / PR:** #68 / (PR pending)
- **Type:** fix

## What changed

`heartbeat.sh` and `claim.sh` no longer source a comment id from `gh issue view
--json comments` (which returns the **GraphQL node id**, `IC_…`) for use against
the **REST** endpoint `/repos/:repo/issues/comments/:id` (which needs the
**numeric** `databaseId`). Both now read the comment from the REST list endpoint
`gh api --paginate /repos/:repo/issues/:n/comments` (numeric `.id`, author under
`.user.login`):

- `heartbeat.sh` — fetches the comments via REST (with explicit failure
  handling), selects the newest bot claim by body (`@tsv | sort | tail -1`), and
  PATCHes that numeric id.
- `claim.sh` — at both loser-cleanup sites (token tie-break loss; assignee-re-add
  rollback), resolves the numeric id of its own claim comment via the REST list
  and DELETEs it.

Tests: `heartbeat.bats` fixtures rewritten to the realistic REST shape; the two
`claim.bats` loss tests gained the extra `queue_response` for the new REST read.
Plugin bumped 1.11.0 → 1.11.1 (fix → patch).

Spec: `docs/superpowers/specs/2026-06-28-comment-id-rest-vs-node.md`.
Plan: `docs/superpowers/plans/2026-06-28-comment-id-rest-vs-node.md`.

## Why

Against real `gh`, every `PATCH`/`DELETE` on `/issues/comments/<node-id>`
returned `HTTP 404`:

- **heartbeat** silently failed to refresh the claim lock → `reclaim.sh` could
  reset an actively-worked issue after the timeout.
- **claim** loser-cleanup silently failed → orphaned `claim:` comments
  accumulated. Because the tie-break picks the **oldest** token as winner, one
  orphaned comment from a crashed session permanently wins every race, making
  the issue **unclaimable**. This was observed live on #64 (4 orphaned claim
  comments; every claim lost to the 2-day-old ghost), which is what stuck the
  Coder `/loop`.

## Key decisions

- **Source the numeric id from the REST list endpoint** rather than switching to
  GraphQL mutations — it matches the codebase's existing
  `gh api --method PATCH|DELETE /repos/:repo/...` style; smallest, most uniform
  change.
- **`--paginate` + `jq -s 'add // []'`** on both reads — the target comment may
  not be on page 1 of a busy issue (REST returns comments oldest-first; a
  just-posted loser comment is newest → last page). Mirrors the existing
  `trusted-answers.sh` page-merge pattern; transparent to the single-page test
  stub.
- **Separate the `gh api` fetch from the `jq`** in heartbeat (no `2>/dev/null`
  on the fetch) so `set -euo pipefail` surfaces an API failure as
  `log ERROR; exit 1` instead of a silent abort; `claim` cleanup is best-effort
  so it guards with `|| cid=""`.
- **Single jq string literal** `"claim: <token>"` for the exact match (embedded
  via shell interpolation, since `gh api --jq` has no jq `--arg`) — avoids the
  adjacent-string-literal jq parse error.
- **Realistic test fixtures** — the old fixtures used numeric ids in
  `gh issue view` shape, which masked the bug; rewriting them to REST shape makes
  the regression guard meaningful.
- **Version 1.11.1 off the 1.11.0 base.** PR #67 (issue #66) concurrently bumps
  to 1.12.0; whichever merges first, `plugin.json` will conflict and the version
  is reconciled at merge time (this fix becomes 1.12.1 if #67 lands first).

## Alternatives considered (not chosen)

- **GraphQL `updateIssueComment`/`deleteIssueComment` with the node id in hand**
  — avoids the extra REST read and (via `gh api graphql --method POST`) needs no
  test-stub change, but introduces a second API surface; rejected for REST
  consistency.
- **`?per_page=100` without pagination** — simpler but silently wrong past 100
  comments (and the loser's newest comment sorts last); `--paginate` is correct.
- **Hand-deleting #64's orphaned comments from this lane** — attempted, but the
  write-classifier blocked deleting external/older claim comments. Left as an
  operational follow-up for a permitted actor (see below).

## Operational follow-up

Issue **#64** still carries 4 orphaned `claim:` comments and remains unclaimable
until they are removed. Clearing them (REST `DELETE` by numeric id) is a one-time
cleanup for a permitted actor; the code fix here prevents recurrence but does not
retroactively clean existing orphans.
