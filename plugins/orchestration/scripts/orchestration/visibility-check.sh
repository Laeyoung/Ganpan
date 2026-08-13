#!/usr/bin/env bash
# visibility-check.sh — read-only setup-time advisory for the Free-plan private-repo
# auto-merge trap (issue #80; the trap itself is #72). READ-ONLY: mutates nothing.
#
# Why this exists: `repos/:repo/branches/:base/protection` is a paid feature. On a
# PRIVATE repo under GitHub Free it ALWAYS returns 403 ("Upgrade to GitHub Pro or make
# this repository public…") whether or not protection exists, so auto-merge.sh's genuine
# 404 ("branch not protected") is unreachable and it fails CLOSED forever — passing PRs
# sit in `status:in-review` with no obvious cause. auto-merge.sh's fail-closed behavior is
# deliberate and unchanged; this script only surfaces the trap ONCE, at /ganpan:orch-setup,
# so the operator learns about the opt-in before it bites them in production.
#
# Deliberately NOT plan detection: the owner-plan field is not reliably exposed to a
# fine-grained token, so we key off visibility alone and let the human confirm the plan.
# Public repos get no advisory (protection works there regardless of plan).
#
# Deliberately NOT gated with require_bot_actor — same rationale as labels-check.sh /
# bootstrap-labels.sh: this runs at setup time, possibly before the bot PAT exists, and
# it is read-only so there is no write to attribute to the wrong actor.
#
# stdout is HUMAN-FACING setup output (like bootstrap-labels.sh / labels-check.sh), not a
# captured return value — no caller wraps this in $(…), and it must never be made one.
#
# exit 0: nothing for the human to act on (public repo, or private with the opt-in already set).
# exit 1: ADVISORY applies (private repo), or the check was inconclusive (FAIL).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$DIR/lib.sh"
load_config || {
  # May be invoked from a repo that was never set up; load_config only logs to stderr,
  # so say it on stdout rather than exiting with a bare non-zero.
  echo "ganpan visibility-check: FAIL — no usable ganpan config (see the error above). Run /ganpan:orch-setup first."
  exit 1
}

private=$(gh api "repos/$REPO" --jq '.private' 2>/dev/null) || {
  echo "ganpan visibility-check: FAIL — could not read visibility of $REPO (API error, or the token lacks repo read access)."
  echo "  Inconclusive, not proof of anything — re-run once the API is reachable."
  exit 1
}

case "$private" in
  false)
    echo "ganpan visibility-check: OK — $REPO is public, so the branch-protection API works normally."
    echo "  The Free-plan 403 trap (#72) cannot occur here; reviewer.autoMerge needs no workaround."
    exit 0
    ;;
  true) ;;
  *)
    echo "ganpan visibility-check: FAIL — unexpected visibility value '$private' for $REPO."
    echo "  Expected the boolean .private from 'gh api repos/$REPO'. Inconclusive; re-run."
    exit 1
    ;;
esac

if [ "${REVIEWER_AUTO_MERGE_PRIVATE_PLAN_WORKAROUND:-false}" = "true" ]; then
  echo "ganpan visibility-check: OK — $REPO is private and reviewer.autoMergePrivatePlanWorkaround is already true."
  echo "  You have accepted that a Free private repo cannot have branch protection; the Reviewer"
  echo "  treats only that exact 403 as 'unprotected'. Nothing further to do."
  exit 0
fi

echo "ganpan visibility-check: ADVISORY — $REPO is PRIVATE. If it is on the GitHub Free plan,"
echo "  reviewer.autoMerge can never complete:"
echo "    - repos/$REPO/branches/<base>/protection is a paid feature and returns 403"
echo "      \"Upgrade to GitHub Pro or make this repository public…\" whether or not protection exists."
echo "    - auto-merge.sh fails CLOSED on any non-404 probe (by design — it never guesses past an"
echo "      active gate), so it returns protect-check-failed forever and passing PRs sit in"
echo "      status:in-review with no obvious cause."
echo "  Fixes, cheapest first:"
echo "    1. Make the repo public, or"
echo "    2. upgrade to GitHub Pro/Team so real branch protection becomes configurable, or"
echo "    3. accept that a Free private repo CANNOT have branch protection and opt in:"
echo "         jq '.reviewer.autoMergePrivatePlanWorkaround = true' \$CFG > tmp && mv tmp \$CFG"
echo "       (\$CFG = your .ganpan/orchestration.json). Only that exact 403 is then read as"
echo "       'unprotected'; every other inconclusive probe still fails closed, and a repo that"
echo "       actually supports protection never emits that message, so no real gate is bypassed."
echo "  Not applicable on a paid plan — a private repo on Pro/Team gets a genuine 404/200 and needs"
echo "  no opt-in. Leave the flag at its default false unless you are on Free."
if [ "${REVIEWER_AUTO_MERGE:-false}" != "true" ]; then
  echo "  (reviewer.autoMerge is currently false, so nothing is stuck today — this is the one-time"
  echo "   heads-up for when you turn it on.)"
fi
exit 1
