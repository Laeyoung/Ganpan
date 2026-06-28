# claim.sh / heartbeat.sh comment-id REST/GraphQL mismatch (Spec)

Issue: #68

## Problem

`heartbeat.sh` and `claim.sh` obtain a comment id from `gh issue view --json
comments` and then use it against the **REST** endpoint
`/repos/:repo/issues/comments/:id`. But `gh issue view --json comments` returns
each comment's **GraphQL node id** (e.g. `IC_kwDO…`), while that REST endpoint
requires the **numeric** `databaseId`. Every such call returns `HTTP 404`:

- **`heartbeat.sh`** (`PATCH`, line ~20): the claim-lock refresh silently fails.
  A long-running claim is never refreshed, so after `reclaim.timeoutMinutes` the
  lock looks stale and `reclaim.sh` can reset an actively-worked issue.
- **`claim.sh`** (`DELETE`, two loser-cleanup sites, lines ~87 and ~108): a
  claim-race loser cannot delete its own `claim:` comment, so orphaned claim
  comments accumulate on an issue. Because the tie-break selects the
  **lexicographically smallest (oldest) token** as the winner (line ~83), a
  single orphaned comment from a crashed session permanently wins every future
  race → the issue becomes **permanently unclaimable**.

This was observed live on issue #64: four orphaned `claim:` comments accrued
over two days, and every new claim attempt loses to the oldest ghost, so the
issue can no longer be claimed by any worker.

### Why the test suite did not catch it

The bats fixtures for these scripts use **numeric** comment ids
(`{"id":555,"author":{"login":"botx"},…}`) shaped like `gh issue view` output
but with a numeric id. Real `gh issue view --json comments` returns the comment's
**GraphQL node id** as `.id` (e.g. `IC_kwDO…`) — verified empirically on this
repo: a live `PATCH /repos/:repo/issues/comments/IC_kwDO…` returns `HTTP 404`.
So the fixtures are unrealistic and the REST mutation passes in tests while
404ing in production.

Because the fix changes the comment **source** (from `gh issue view` to the REST
list endpoint, which returns numeric `.id` and `.user.login`), the existing
`heartbeat.bats` fixtures (three tests) must be **rewritten** to the REST shape
(`{"id":<num>,"user":{"login":…},"body":…}`), not merely supplemented — under
the new code `.author.login`/`gh issue view` fixtures would yield an empty id and
fail. Likewise, each `claim.sh` loser-cleanup site adds one REST `gh api` GET
(which the stub counts as a read slot), so the two claim-loss tests must each
gain an extra `queue_response` for that read.

## Goal

Make both scripts target the comment with an id the REST endpoint accepts, so
the heartbeat refresh and the claim-loser cleanup actually succeed against real
`gh`. Add regression tests with realistic fixtures so the mismatch cannot
return.

## Constraints

1. **Keep the engine-script stdout contract** (CLAUDE.md): `claim.sh` and
   `heartbeat.sh` are captured via `$(…)` / asserted on stdout. Any added `gh`
   read/mutation must not leak to stdout — capture or redirect as the existing
   code does.
2. **Stay within the existing REST mutation style.** The codebase already uses
   `gh api --method PATCH|DELETE /repos/:repo/issues/comments/:id`. The fix
   sources the **numeric** id for that same call rather than switching to a new
   API surface — smallest, most consistent change.
3. **No behavior change other than the id source.** Winner selection, exit
   codes, rollback semantics, the actor gate, and the "newest bot claim is the
   live lock" rule are unchanged.
4. **Other comment-touching scripts are not affected** — verified by grep that
   none use a comment **id** against a REST/GraphQL *mutation*:
   `reclaim.sh` (reads `.author.login` + bodies), `followup-dedup.sh` (counts by
   body), `unblock-check.sh` (reads `.author.login` + `.createdAt`), and
   `trusted-answers.sh` (already reads the REST list endpoint with `.user.login`
   and never mutates a comment by id). So only `claim.sh` + `heartbeat.sh` are in
   scope.

## Design (summary; mechanics in the plan)

Source the comment id from the REST list endpoint, which returns the numeric
`databaseId` as `.id`:

The REST list endpoint returns comments **oldest-first**, so the comment of
interest may be on a later page on a heavily-commented issue. Both reads use
`gh api --paginate` so all pages are considered (the test stub returns a single
page, so this is transparent to tests).

- **`heartbeat.sh`** — replace the comment fetch `gh issue view "$issue" --json
  comments` with `gh api --paginate "/repos/$REPO/issues/$issue/comments"` (REST
  list). With `--paginate` (no `--slurp`), `gh` applies `--jq` per page and
  concatenates the lines, so emit one `body<TAB>id` line per bot claim comment
  and pick the **newest** (max body) in shell, preserving the existing "patch the
  newest bot claim" semantics:
  ```bash
  cid=$(gh api --paginate "/repos/$REPO/issues/$issue/comments" \
         --jq '.[] | select(.user.login=="'"$BOT"'" and (.body|startswith("claim: "))) | [.body, (.id|tostring)] | @tsv' \
        | sort | tail -n1 | cut -f2)
  ```
  The existing `PATCH /repos/$REPO/issues/comments/$cid` now receives a numeric
  id and succeeds. Empty `cid` (no claim comment) keeps the existing exit-1 path.
- **`claim.sh`** — the main `gh issue view --json labels,assignees,comments`
  fetch stays (used for labels/assignees and the body-only tie-break, none of
  which need a comment id). At each of the two loser-cleanup sites, resolve the
  numeric id with a targeted paginated REST read filtered by the bot login and
  the exact claim body (an exact match is unique, so `head -1` suffices), then
  `DELETE` it:
  ```bash
  cid=$(gh api --paginate "/repos/$REPO/issues/$issue/comments" \
         --jq '.[] | select(.user.login=="'"$BOT"'" and .body==("claim: "'"$token"'")) | .id' \
        | head -n1)
  [ -n "$cid" ] && gh api --method DELETE "/repos/$REPO/issues/comments/$cid" >/dev/null 2>&1 || true
  ```
  This adds one REST read only on the (rare) lost-race / rollback path.

Rejected alternative — GraphQL `updateIssueComment` / `deleteIssueComment`
mutations using the node id already in hand: avoids the extra REST read, and
since GraphQL mutations go through `gh api graphql --method POST` they would be
caught by the test stub's existing write-detection (no stub change needed). It
is rejected purely for **API-surface consistency**: the codebase already mutates
comments via `gh api --method PATCH|DELETE /repos/:repo/...`, so sourcing the
correct numeric id for that same call is the smaller, more uniform change.

## Acceptance criteria

1. `heartbeat.sh` issues `PATCH /repos/:repo/issues/comments/<numeric>` against
   the comment whose **numeric** id came from the REST list endpoint — verified
   by a test using a realistic REST-shaped fixture (numeric `id`, `user.login`).
2. A `claim.sh` race loser issues `DELETE /repos/:repo/issues/comments/<numeric>`
   for **its own** claim comment, with the numeric id sourced from the REST list
   endpoint — verified by tests (both loser-cleanup sites: the token-tie-break
   loss and the assignee-re-add rollback).
3. Existing exit codes / rollback behavior unchanged; the full `bats` suite and
   `shellcheck` pass. The three `heartbeat.bats` fixtures are rewritten to the
   REST shape and the two `claim.bats` loss tests each gain the extra
   `queue_response` for the new REST read.
4. Both reads use `gh api --paginate` so the target comment is found even when it
   is not on the first page of an issue's comments.
5. The version sentinel is bumped (fix → patch).
6. (Operational follow-up, outside the code change) the 4 orphaned claim
   comments already on #64 are cleared so it becomes claimable — noted in the
   PR; performed by a permitted actor.

## Non-goals

- Changing the winner-selection policy (oldest-token-wins). Whether oldest-wins
  vs newest-wins is the right race policy is a separate design question; this
  issue only restores the cleanup that prevents orphan accumulation.
- A general migration of all comment reads to REST. Only the two scripts that
  use a comment id against a REST mutation are touched.
