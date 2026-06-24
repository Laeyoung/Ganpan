#!/usr/bin/env bash
# auto-merge.sh <PR#> — opt-in reviewer auto-merge (issue #33).
#
# Merges a PR ONLY when ALL hold:
#   1. reviewer.autoMerge == true in config (default false), and
#   2. the base branch is NOT protected (the human must have removed branch
#      protection — the agent never bypasses an active gate), and
#   3. the PR is OPEN, mergeable, and mergeStateStatus == CLEAN
#      (conservative: any failing/pending check, conflict, or behind-base blocks).
#
# The caller (review-queue R-D) only invokes this once its own verdict is
# "proceed" (not rework/needs-decision/followup), so the reviewer-verdict gate is
# already satisfied upstream.
#
# stdout (the caller branches on this), exit 0 unless a hard error:
#   disabled      autoMerge flag off → caller requests a human merge as usual
#   protected     branch protection still on → caller posts the "disable protection" advisory
#   merged        PR was merged → caller transitions the issue to QA
#   not-ready: …  open/mergeable/clean not all satisfied → caller waits (next tick retries)
# exit 1 actor gate failed | 2 API/merge error (caller falls back to human-merge request).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$DIR/lib.sh"
load_config

PR="${1:?PR number required}"
BASE="${AUTO_MERGE_BASE:-main}"
METHOD="${AUTO_MERGE_METHOD:---merge}"   # --merge | --squash | --rebase

# 1. opt-in flag
[ "${REVIEWER_AUTO_MERGE:-false}" = "true" ] || { echo "disabled"; exit 0; }

# A real merge is a write — gate on the bot identity exactly like claim.sh.
require_bot_actor || exit 1

# 2. base-branch protection. `gh api …/protection` returns 200 when protection
# exists, 404 (non-zero exit) when it does not. We merge ONLY on the 404 case:
# the human must have explicitly removed the gate.
if gh api "repos/$REPO/branches/$BASE/protection" >/dev/null 2>&1; then
  echo "protected"; exit 0
fi

# 3. merge readiness — conservative: OPEN + MERGEABLE + CLEAN.
view=$(gh pr view "$PR" --json state,mergeable,mergeStateStatus --repo "$REPO") || { echo "error"; exit 2; }
state=$(printf '%s' "$view" | jq -r '.state')
mergeable=$(printf '%s' "$view" | jq -r '.mergeable')
mss=$(printf '%s' "$view" | jq -r '.mergeStateStatus')
if [ "$state" != "OPEN" ] || [ "$mergeable" != "MERGEABLE" ] || [ "$mss" != "CLEAN" ]; then
  echo "not-ready: state=$state mergeable=$mergeable mergeState=$mss"; exit 0
fi

# 4. merge.
if gh pr merge "$PR" "$METHOD" --repo "$REPO" >/dev/null 2>&1; then
  echo "merged"; exit 0
fi
echo "merge-failed"; exit 2
