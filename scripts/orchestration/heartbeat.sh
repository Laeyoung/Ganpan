#!/usr/bin/env bash
# heartbeat.sh <issue#> — refresh the claim: comment's timestamp in place.
# exit 0 ok | 1 api fail / no claim comment.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$DIR/lib.sh"
load_config

issue="${1:?issue number required}"
view=$(gh issue view "$issue" --json comments --repo "$REPO") || { log ERROR "view failed"; exit 1; }
cid=$(echo "$view" | jq -r --arg b "$BOT" \
  'first(.comments[] | select(.author.login==$b and (.body|startswith("claim: "))) | .id) // empty')
[ -z "$cid" ] && { log ERROR "no claim comment on #$issue"; exit 1; }
token="${CLAIM_TOKEN_OVERRIDE:-$(claim_token)}"
gh api --method PATCH "/repos/$REPO/issues/comments/$cid" -f body="claim: $token" >/dev/null \
  || { log ERROR "patch failed"; exit 1; }
log INFO "heartbeat #$issue"
