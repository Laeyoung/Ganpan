#!/usr/bin/env bash
# reclaim.sh — revert orphaned status:in-progress issues. exit 0 swept | 1 api fail.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$DIR/lib.sh"
load_config

list=$(gh issue list --label status:in-progress --json number --limit 1000 --repo "$REPO") || exit 1
now=$(now_epoch)
timeout_secs=$(( RECLAIM_TIMEOUT_MIN * 60 ))

echo "$list" | jq -r '.[].number' | while read -r issue; do
  [ -z "$issue" ] && continue
  view=$(gh issue view "$issue" --json comments --repo "$REPO") || { log WARN "view #$issue failed"; continue; }

  # unresolved rework? (latest rework-requested with no later rework-resolved) → skip
  unresolved=$(echo "$view" | jq -r '
    [.comments[] | select(.body|startswith("rework-requested:") or startswith("rework-resolved:"))] as $m
    | ($m | length) as $len
    | if $len==0 then "no" else (if ($m[($len-1)].body|startswith("rework-requested:")) then "yes" else "no" end) end')
  if [ "$unresolved" = "yes" ]; then log INFO "#$issue unresolved rework, skip"; continue; fi

  token=$(echo "$view" | jq -r 'first(.comments[] | select(.body|startswith("claim: ")) | .body) // empty' | sed 's/^claim: //')
  [ -z "$token" ] && { log WARN "#$issue no claim token, skip"; continue; }
  iso="${token%%Z-*}Z"
  tepoch=$(iso_to_epoch "$iso" 2>/dev/null || echo 0)
  [ $(( now - tepoch )) -le "$timeout_secs" ] && continue   # still alive

  # timed out: check for open PR on branch issue-<n>
  prs=$(gh pr list --head "issue-$issue" --state open --json number --repo "$REPO" || echo '[]')
  if [ "$(echo "$prs" | jq 'length')" -gt 0 ]; then
    pr=$(echo "$prs" | jq -r '.[0].number')
    gh issue edit "$issue" --add-label status:blocked --remove-label status:in-progress --repo "$REPO"
    gh issue comment "$issue" --body "reclaimed: orphan lock, PR #$pr 존재 — 사람 확인 필요" --repo "$REPO"
    log INFO "#$issue → blocked (open PR #$pr)"
  else
    gh issue edit "$issue" --add-label status:agent-ready --remove-label status:in-progress --repo "$REPO"
    gh issue edit "$issue" --remove-assignee "$BOT" --repo "$REPO"
    gh issue comment "$issue" --body "reclaimed: orphan lock" --repo "$REPO"
    log INFO "#$issue → agent-ready"
  fi
done
