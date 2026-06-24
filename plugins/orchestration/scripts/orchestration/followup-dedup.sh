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

# count_markers <body-prefix> — number of bot-authored comments whose body starts with the
# prefix. One place to fix the marker-match predicate (so the three callers can't drift).
count_markers() {
  echo "$view" | jq -r --arg b "$BOT" --arg k "$1" \
    '[.comments[] | select(.author.login==$b and (.body|startswith($k)))] | length'
}

# 1) already created for this key?
exists=$(count_markers "followup-created: $key ")
if [ "$exists" -gt 0 ]; then echo "skip-exists"; exit 0; fi

# 2) already cap-noted for this key?
noted=$(count_markers "cap-exceeded: $key ")
if [ "$noted" -gt 0 ]; then echo "cap-noted"; exit 0; fi

# 3) cap reached?
count=$(count_markers "followup-created: ")
if [ "$count" -ge "$FOLLOWUP_CAP" ]; then echo "cap-exceeded"; exit 0; fi

echo "create"
