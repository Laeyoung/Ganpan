#!/usr/bin/env bash
# followup-dedup.sh <issue#> <itemKey> — print create|skip-exists|cap-exceeded|cap-noted.
# exit 0 ok | 1 api fail. Bot-authored markers only.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$DIR/lib.sh"
load_config

issue="$1"; key="$2"
view=$(gh issue view "$issue" --json comments --repo "$REPO") || exit 1

# 1) already created for this key?
exists=$(echo "$view" | jq -r --arg b "$BOT" --arg k "followup-created: $key " \
  '[.comments[] | select(.author.login==$b and (.body|startswith($k)))] | length')
if [ "$exists" -gt 0 ]; then echo "skip-exists"; exit 0; fi

# 2) already cap-noted for this key?
noted=$(echo "$view" | jq -r --arg b "$BOT" --arg k "cap-exceeded: $key " \
  '[.comments[] | select(.author.login==$b and (.body|startswith($k)))] | length')
if [ "$noted" -gt 0 ]; then echo "cap-noted"; exit 0; fi

# 3) cap reached?
count=$(echo "$view" | jq -r --arg b "$BOT" \
  '[.comments[] | select(.author.login==$b and (.body|startswith("followup-created: ")))] | length')
if [ "$count" -ge "$FOLLOWUP_CAP" ]; then echo "cap-exceeded"; exit 0; fi

echo "create"
