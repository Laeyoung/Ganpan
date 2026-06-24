#!/usr/bin/env bash
# reclaim.sh — revert orphaned status:in-progress issues. exit 0 swept | 1 api fail.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$DIR/lib.sh"
load_config
require_bot_actor || exit 1

list=$(gh issue list --label status:in-progress --json number --limit 1000 --repo "$REPO") || exit 1
now=$(now_epoch)
timeout_secs=$(( RECLAIM_TIMEOUT_MIN * 60 ))

# Process substitution (not a pipe) so the loop runs in the main shell: a pipe would
# put `while` in a subshell, masking set -e failures and the loop's real exit status.
while read -r issue; do
  [ -z "$issue" ] && continue
  view=$(gh issue view "$issue" --json comments --repo "$REPO") || { log WARN "view #$issue failed"; continue; }

  # State markers are trusted only from the bot — any user can post "rework-requested:" to
  # freeze an issue, "rework-resolved:" to unfreeze, or "claim:" to skew the timeout clock.
  # unresolved rework? (latest bot rework-requested with no later rework-resolved) → skip.
  # Use the shared bot_marker_pending helper so this stays in lockstep with the Coder lane's
  # resume check and the Reviewer gate logic — a divergent inline copy would risk drift.
  unresolved=$(echo "$view" | bot_marker_pending "rework-requested:" "rework-resolved:")
  if [ "$unresolved" = "yes" ]; then log INFO "#$issue unresolved rework, skip"; continue; fi

  # Pick the NEWEST bot claim token (lexicographic max == latest heartbeat, since the
  # token's leading ISO8601 is fixed-width). first()/oldest could be a stale comment left
  # by a crashed loser and would make a live, actively-heartbeating issue look timed out.
  token=$(echo "$view" | jq -r --arg b "$BOT" '[.comments[] | select(.author.login==$b and (.body|startswith("claim: "))) | .body] | max // empty' | sed 's/^claim: //')
  [ -z "$token" ] && { log WARN "#$issue no claim token, skip"; continue; }
  iso="${token%%Z-*}Z"
  tepoch=$(iso_to_epoch "$iso" 2>/dev/null || echo 0)
  # 0 == iso_to_epoch parse failure (malformed timestamp); skip rather than treat as
  # epoch-0 (which would look ~56 years stale and trigger a spurious reclaim).
  [ "$tepoch" -eq 0 ] && { log WARN "#$issue unparseable claim timestamp, skip"; continue; }
  [ $(( now - tepoch )) -le "$timeout_secs" ] && continue   # still alive

  # timed out: check for open PR on branch issue-<n>. On a transient API failure, SKIP
  # rather than assume no PR — assuming none could reset an issue that actually has an
  # open PR (losing the human-review routing). Next sweep retries.
  prs=$(gh pr list --head "issue-$issue" --state open --json number --repo "$REPO") \
    || { log WARN "#$issue pr-list failed, skip"; continue; }
  # Each branch is guarded so one issue's API failure logs and skips to the next issue
  # rather than aborting the whole sweep (we run in the main shell, so set -e would exit).
  if [ "$(echo "$prs" | jq 'length')" -gt 0 ]; then
    pr=$(echo "$prs" | jq -r '.[0].number')
    { gh issue edit "$issue" --add-label status:blocked --remove-label status:in-progress --repo "$REPO" \
      && gh issue comment "$issue" --body "reclaimed: orphan lock, PR #$pr 존재 — 사람 확인 필요" --repo "$REPO"; } \
      || { log WARN "#$issue reclaim→blocked failed, skip"; continue; }
    log INFO "#$issue → blocked (open PR #$pr)"
  else
    { gh issue edit "$issue" --add-label status:agent-ready --remove-label status:in-progress --repo "$REPO" \
      && gh issue edit "$issue" --remove-assignee "$BOT" --repo "$REPO" \
      && gh issue comment "$issue" --body "reclaimed: orphan lock" --repo "$REPO"; } \
      || { log WARN "#$issue reclaim→agent-ready failed, skip"; continue; }
    log INFO "#$issue → agent-ready"
  fi
done < <(echo "$list" | jq -r '.[].number')
