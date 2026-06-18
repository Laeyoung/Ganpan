#!/usr/bin/env bash
# wip-check.sh — sum of in-review + qa vs WIP_LIMIT.
# stdout OK|EXCEED. exit 0 OK | 1 EXCEED | 2 api fail.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$DIR/lib.sh"
load_config

count() {
  gh issue list --label "$1" --limit 1000 --json number --repo "$REPO" | jq 'length'
}
ir=$(count status:in-review) || exit 2
qa=$(count status:qa) || exit 2
total=$(( ir + qa ))
if [ "$total" -ge "$WIP_LIMIT" ]; then echo EXCEED; exit 1; fi
echo OK; exit 0
