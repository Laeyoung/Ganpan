#!/usr/bin/env bash
# claim.sh — atomically claim one status:agent-ready issue.
# exit 0 (prints issue#)
#      1 no candidates / pre-mutation list failure (nothing mutated; clean)
#      2 clean lost race OR clean rollback to status:agent-ready (issue is back in the queue or
#        legitimately owned by another claimant — a caller may safely retry on the next tick)
#      3 UNCONFIRMED claim: the claim comment write succeeded but never became visible, so the
#        issue is left status:in-progress with a server-side token for reclaim.sh to recover.
#        Distinct from exit 2 so callers do NOT treat the issue as available or retry-claim it.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$DIR/lib.sh"
load_config
require_bot_actor || exit 1

BACKOFF="${CLAIM_BACKOFF_SECS:-3}"
RETRIES="${CLAIM_RETRIES:-3}"

# 1. candidate selection: top-N by createdAt, random pick
candidates=$(gh issue list --label status:agent-ready --json number,createdAt --limit 1000 --repo "$REPO") \
  || { log ERROR "issue list failed"; exit 1; }
n=$(echo "$candidates" | jq 'length')
[ "$n" -eq 0 ] && { log INFO "no agent-ready candidates"; exit 1; }
top=$(echo "$candidates" | jq --argjson k "$CANDIDATE_N" 'sort_by(.createdAt)[:$k] | map(.number)')
topn=$(echo "$top" | jq 'length')
# candidateN: 0 makes the top-N slice empty even with candidates present; guard before the
# modulo so we exit with the clean "no candidates" contract (1) instead of a div-by-zero crash.
[ "$topn" -eq 0 ] && { log INFO "no candidates after top-N slice (candidateN=$CANDIDATE_N)"; exit 1; }
pick_idx=$(( RANDOM % topn ))
issue=$(echo "$top" | jq -r ".[$pick_idx]")

# 2. mark in-progress + assignee + claim comment.
# The claim comment IS the lock token; if it can't be written we must roll the label back
# to status:agent-ready, otherwise the issue is stuck in-progress with no token (reclaim
# skips token-less in-progress issues, so it would never recover). Assignee is cosmetic
# (the later check is presence-only), so a failure there does not block the claim.
# `gh issue edit`/`gh issue comment` print the resource URL to stdout on success, so every
# mutating call below is redirected to /dev/null — this script's stdout is its return value
# (the issue number at the end, captured via ISSUE=$(claim.sh)); a leaked URL would corrupt it.
# Errors still surface on stderr, and state is re-read via `gh issue view` regardless.
token="${CLAIM_TOKEN_OVERRIDE:-$(claim_token)}"
gh issue edit "$issue" --add-label status:in-progress --remove-label status:agent-ready --repo "$REPO" >/dev/null \
  || { log ERROR "mark in-progress failed on #$issue"; exit 2; }
gh issue edit "$issue" --add-assignee "$BOT" --repo "$REPO" >/dev/null || log WARN "add-assignee failed on #$issue (continuing)"
gh issue comment "$issue" --body "claim: $token" --repo "$REPO" >/dev/null || {
  log ERROR "claim comment failed on #$issue, rolling back label"
  gh issue edit "$issue" --add-label status:agent-ready --remove-label status:in-progress --repo "$REPO" >/dev/null || true
  exit 2
}

# 3. re-read with backoff until our claim comment is visible
view=""
seen=0
for _ in $(seq 1 "$RETRIES"); do
  sleep "$BACKOFF"
  view=$(gh issue view "$issue" --json labels,assignees,comments --repo "$REPO")
  if echo "$view" | jq -e --arg t "$token" \
      '.comments[] | select(.body == ("claim: " + $t))' >/dev/null; then
    seen=1; break
  fi
done
# our claim comment never became visible → UNCONFIRMED. The line-33 write returned success, so
# the token exists server-side; we just can't confirm it within the retry budget. Leave the
# issue status:in-progress (do NOT roll back: rolling back to agent-ready while the token exists
# server-side would let a later claimer race a now-visible ghost token) and exit 3 so the caller
# can distinguish this from a clean lost race. reclaim.sh recovers the issue after the timeout.
[ "$seen" -eq 1 ] || { log ERROR "claim comment not visible after $RETRIES retries on #$issue (unconfirmed; leaving for reclaim)"; exit 3; }

# ensure in-progress is present (re-add if a transient race removed it)
if ! echo "$view" | jq -e '.labels[] | select(.name=="status:in-progress")' >/dev/null; then
  gh issue edit "$issue" --add-label status:in-progress --repo "$REPO" >/dev/null
fi

# 4. tie-break on distinct claim tokens (single bot ⇒ assignee count can't discriminate).
# Only bot-authored claim comments count — any GitHub user can post "claim: …", so an
# unfiltered count would let an outsider force a false race loss or steer the winner.
# Resolve the race BEFORE the assignee re-add/rollback below: the winner is decided purely
# by token, so a loser must release here regardless of assignee state, and — crucially — a
# winner must not self-roll-back over a transient add-assignee failure for a claim it already won.
ntok=$(echo "$view" | jq --arg b "$BOT" '[.comments[] | select(.author.login==$b and (.body|startswith("claim: "))) | .body] | unique | length')
if [ "$ntok" -ge 2 ]; then
  winner=$(echo "$view" | jq -r --arg b "$BOT" '[.comments[] | select(.author.login==$b and (.body|startswith("claim: "))) | (.body|sub("^claim: ";""))] | unique | sort | .[0]')
  if [ "$winner" != "$token" ]; then
    # we lost: delete our own claim comment, release assignee, return 2
    cid=$(echo "$view" | jq -r --arg b "$BOT" --arg t "$token" 'first(.comments[] | select(.author.login==$b and .body==("claim: "+$t)) | .id) // empty')
    [ -n "$cid" ] && gh api --method DELETE "/repos/$REPO/issues/comments/$cid" >/dev/null 2>&1 || true
    gh issue edit "$issue" --remove-assignee "$BOT" --repo "$REPO" >/dev/null || true
    log INFO "lost claim race on #$issue (winner=$winner)"
    exit 2
  fi
fi

# 5. spec §5.2 step 3 (adapted): verify the bot is among the assignees. We deliberately do
# NOT enforce the spec's literal "exactly 1 assignee" — under the single-bot model the
# authoritative race discriminator is the claim-token count (above; see "Single-bot claim
# discriminator" in the plan header), and a human may legitimately co-assign an issue, so
# an exactly-1 check would cause false losses.
# The initial add-assignee (above) is best-effort and may have transiently failed, leaving the
# bot off the assignee list. We are past the tie-break, so we know we won this claim. Rather than
# strand the (otherwise confirmed) claim in-progress, try one re-add; if that also fails, roll the
# issue back cleanly to status:agent-ready — delete our (visible) claim comment and reset the
# label — so the next claimer finds it clean (exit 2).
if ! echo "$view" | jq -e --arg b "$BOT" '.assignees[]? | select(.login==$b)' >/dev/null; then
  if ! gh issue edit "$issue" --add-assignee "$BOT" --repo "$REPO" >/dev/null; then
    log ERROR "bot not an assignee on #$issue and re-add failed, rolling back to agent-ready"
    cid=$(echo "$view" | jq -r --arg b "$BOT" --arg t "$token" 'first(.comments[] | select(.author.login==$b and .body==("claim: "+$t)) | .id) // empty')
    [ -n "$cid" ] && gh api --method DELETE "/repos/$REPO/issues/comments/$cid" >/dev/null 2>&1 || true
    gh issue edit "$issue" --add-label status:agent-ready --remove-label status:in-progress --repo "$REPO" >/dev/null || true
    exit 2
  fi
fi

echo "$issue"
