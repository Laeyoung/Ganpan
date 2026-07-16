#!/usr/bin/env bash
# auto-merge.sh <PR#> — opt-in reviewer auto-merge (issue #33).
#
# Merges a PR ONLY when ALL hold:
#   1. reviewer.autoMerge == true in config (default false), and
#   2. the PR's base branch is NOT protected — confirmed by a genuine 404 from the
#      protection API (any inconclusive probe fails CLOSED; the agent never bypasses
#      an active gate or guesses past a transient API failure), and
#      — EXCEPTION (opt-in, issue #72): on a PRIVATE repo under a GitHub plan without
#        branch protection (Free), `repos/:repo/branches/:base/protection` ALWAYS
#        returns a 403 ("Upgrade to GitHub Pro or make this repository public…")
#        regardless of protection state, so a genuine 404 is unreachable and autoMerge
#        would be permanently stuck at protect-check-failed. When (and ONLY when) the
#        operator sets reviewer.autoMergePrivatePlanWorkaround: true, that EXACT 403
#        message is treated as "unprotected" — safe because the feature being
#        unavailable means the branch cannot be protected. Every OTHER inconclusive
#        response (5xx, missing scope, rate-limit, any other 403) still fails CLOSED,
#        and a repo that actually supports protection never emits this message, so real
#        protection is never bypassed. Default off ⇒ no change for any other repo.
#   3. the PR is OPEN, mergeable, and mergeStateStatus == CLEAN
#      (conservative: any failing/pending check, conflict, or behind-base blocks).
#
# The caller (review-queue R-D) only invokes this once its own verdict is
# "proceed" (not rework/needs-decision/followup), so the reviewer-verdict gate is
# already satisfied upstream.
#
# stdout (the caller branches on this), exit 0 unless a hard error:
#   disabled             autoMerge flag off → caller requests a human merge as usual
#   protected            branch protection still on → caller posts the "disable protection" advisory
#   merged               PR was merged → caller transitions the issue to QA
#   not-ready: …         open/mergeable/clean not all satisfied → caller waits (next tick retries)
#   protect-check-failed (exit 2) protection probe inconclusive (NOT a clean 404 — e.g. 403
#                        missing token scope, 5xx, rate-limit, network) → caller must NOT merge
#   error                (exit 2) gh pr view failed → caller surfaces + retries next tick
#   merge-failed         (exit 2) the merge call failed (e.g. merge method disallowed by the
#                        repo, such as --merge on a squash-only repo) → caller surfaces it
# exit 1 actor gate failed | 2 operational error. On exit 2 the caller surfaces the failure
# and waits — it must NOT silently fall back to a human-merge request, which would mask it.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$DIR/lib.sh"
load_config

PR="${1:?PR number required}"
METHOD="${AUTO_MERGE_METHOD:---merge}"   # --merge | --squash | --rebase (override per-repo)

# 1. opt-in flag
[ "${REVIEWER_AUTO_MERGE:-false}" = "true" ] || { echo "disabled"; exit 0; }

# A real merge is a write — gate on the bot identity exactly like claim.sh.
require_bot_actor || exit 1

# 2. read the PR once: readiness fields AND the branch it actually targets, so the
# protection probe below checks the PR's real base rather than a hardcoded 'main'
# (a PR against a protected non-main base must not slip through an unprotected main).
view=$(gh pr view "$PR" --json state,mergeable,mergeStateStatus,baseRefName --repo "$REPO") || { echo "error"; exit 2; }
state=$(printf '%s' "$view" | jq -r '.state')
mergeable=$(printf '%s' "$view" | jq -r '.mergeable')
mss=$(printf '%s' "$view" | jq -r '.mergeStateStatus')
BASE="${AUTO_MERGE_BASE:-$(printf '%s' "$view" | jq -r '.baseRefName')}"

# 3. base-branch protection. A genuine 404 ("Branch not protected") is the ONLY
# signal that the human removed the gate. `gh api` exits non-zero on EVERY error
# status, so we must tell that 404 apart from a 403 (missing token scope), 5xx,
# rate-limit, or network blip: anything that is not a confirmed 404 fails CLOSED
# (protect-check-failed) instead of being mistaken for "unprotected" — guessing
# "unprotected" on a transient failure would bypass an active gate.
if prot=$(gh api "repos/$REPO/branches/$BASE/protection" 2>&1); then
  echo "protected"; exit 0
fi
if printf '%s\n' "$prot" | grep -qiE 'branch not protected|HTTP 404'; then
  : # genuine 404 → the human removed the gate; fall through to the readiness check.
elif [ "${REVIEWER_AUTO_MERGE_PRIVATE_PLAN_WORKAROUND:-false}" = "true" ] \
     && printf '%s\n' "$prot" | grep -qiF 'Upgrade to GitHub Pro or make this repository public'; then
  # Opt-in only (see header EXCEPTION): a Free-plan PRIVATE repo returns this EXACT 403
  # whether or not protection exists — but the feature being unavailable means the base
  # CANNOT be protected, so with the operator's explicit opt-in we treat it as unprotected.
  # A repo that supports protection never emits this string, so real gates stay unbypassed.
  log WARN "branch-protection API unavailable on '$BASE' (Free-plan private repo); autoMergePrivatePlanWorkaround=true → treating base as unprotected"
else
  log ERROR "branch-protection probe inconclusive for '$BASE' (not a 404): $prot"
  echo "protect-check-failed"; exit 2
fi

# 4. merge readiness — conservative: OPEN + MERGEABLE + CLEAN.
if [ "$state" != "OPEN" ] || [ "$mergeable" != "MERGEABLE" ] || [ "$mss" != "CLEAN" ]; then
  echo "not-ready: state=$state mergeable=$mergeable mergeState=$mss"; exit 0
fi

# 5. merge. On failure, surface the reason (e.g. a merge method the repo disallows,
# such as --merge on a squash-only repo) instead of swallowing it — otherwise
# auto-merge silently never completes with no pointer to the cause.
if merge_out=$(gh pr merge "$PR" "$METHOD" --repo "$REPO" 2>&1); then
  echo "merged"; exit 0
fi
log ERROR "gh pr merge failed on #$PR ($METHOD): $merge_out"
echo "merge-failed"; exit 2
