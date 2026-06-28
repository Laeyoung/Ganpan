#!/usr/bin/env bash
# heartbeat.sh <issue#> — refresh the claim: comment's timestamp in place.
# exit 0 ok | 1 api fail / no claim comment.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$DIR/lib.sh"
load_config
require_bot_actor || exit 1

issue="${1:?issue number required}"
# Source the comment id from the REST list endpoint, which returns the NUMERIC
# databaseId as `.id`. `gh issue view --json comments` returns the GraphQL node id
# (IC_…) instead, which the REST PATCH endpoint below rejects with HTTP 404 (#68).
# REST comment objects key the author under `.user.login` (not `.author.login`).
# `--paginate` (the claim comment may not be on page 1 of a busy issue) emits one
# JSON array per page; `jq -s 'add // []'` merges them (and is a no-op for the
# single page returned in tests). Patch the NEWEST bot claim comment (max by body
# == latest token), matching the comment reclaim.sh treats as the live lock — old
# claim comments may linger, so the oldest would refresh a stale comment.
comments=$(gh api --paginate "/repos/$REPO/issues/$issue/comments") \
  || { log ERROR "comment list failed on #$issue"; exit 1; }
cid=$(printf '%s\n' "$comments" | jq -s -r 'add // [] | .[]
        | select(.user.login=="'"$BOT"'" and (.body|startswith("claim: ")))
        | [.body, (.id|tostring)] | @tsv' | sort | tail -n1 | cut -f2)
[ -z "$cid" ] && { log ERROR "no claim comment on #$issue"; exit 1; }
token="${CLAIM_TOKEN_OVERRIDE:-$(claim_token)}"
gh api --method PATCH "/repos/$REPO/issues/comments/$cid" -f body="claim: $token" >/dev/null \
  || { log ERROR "patch failed"; exit 1; }
log INFO "heartbeat #$issue"
