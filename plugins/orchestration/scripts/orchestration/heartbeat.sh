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
view=$(gh issue view "$issue" --json comments --repo "$REPO") || { log ERROR "view failed"; exit 1; }
# Patch the NEWEST bot claim comment (max by body == latest token), matching the comment
# reclaim.sh treats as the live lock. Old claim comments linger (reclaim doesn't delete
# them), so first()/oldest would refresh a stale comment and leave the real lock to expire.
cid=$(echo "$view" | jq -r --arg b "$BOT" \
  '[.comments[] | select(.author.login==$b and (.body|startswith("claim: ")))] | (max_by(.body).id // empty)')
[ -z "$cid" ] && { log ERROR "no claim comment on #$issue"; exit 1; }
token="${CLAIM_TOKEN_OVERRIDE:-$(claim_token)}"
gh api --method PATCH "/repos/$REPO/issues/comments/$cid" -f body="claim: $token" >/dev/null \
  || { log ERROR "patch failed"; exit 1; }
log INFO "heartbeat #$issue"
