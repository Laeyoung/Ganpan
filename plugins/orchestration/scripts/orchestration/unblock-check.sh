#!/usr/bin/env bash
# unblock-check.sh <issue#> — decide whether a status:blocked issue should be re-triaged.
# Read-only: prints a decision; the Triager lane performs the label move.
#
# stdout:
#   retriage: no-blocker       no bot-authored comment exists → stale/unexplained block
#                              (e.g. a follow-up created blocked, or a block whose reason
#                              was never recorded — #29) → re-evaluate from scratch.
#   retriage: human-answered   a TRUSTED human commented AFTER the latest bot comment (the
#                              recorded blocker was answered; same trust model as the
#                              Reviewer decision gate — write+ permission or allowlist).
#   keep-blocked               a recorded blocker exists and no trusted human has answered
#                              it yet → leave it blocked (fail closed; next tick re-checks).
# exit 0 ok | 1 api fail.
#
# Untrusted-input safety: only the bot's own comments mark the blocker boundary, and only a
# trusted human's later comment unblocks — an arbitrary commenter cannot unblock the lane.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$DIR/lib.sh"
load_config

issue="${1:?issue number required}"
view=$(gh issue view "$issue" --json comments --repo "$REPO") || exit 1

# Boundary = createdAt of the LATEST bot-authored comment (the recorded blocker). ISO8601 is
# fixed-width so a lexicographic max is the most recent. None → no recorded blocker.
boundary=$(printf '%s' "$view" | jq -r --arg b "$BOT" \
  '[.comments[] | select(.author.login==$b) | .createdAt] | max // empty')
if [ -z "$boundary" ]; then
  echo "retriage: no-blocker"; exit 0
fi

# A recorded blocker exists → unblock only if a trusted human commented strictly after it.
candidates=$(printf '%s' "$view" | jq -r --arg b "$BOT" --arg t "$boundary" \
  '[.comments[] | select(.author.login!=$b and .createdAt > $t) | .author.login] | unique | .[]')
while IFS= read -r user; do
  [ -z "$user" ] && continue
  # `if is_trusted` fails closed: a definitive "untrusted" (1) and a transient lookup
  # failure (2) both leave the issue blocked this tick.
  if is_trusted "$user"; then
    echo "retriage: human-answered"; exit 0
  fi
done <<< "$candidates"

echo "keep-blocked"; exit 0
