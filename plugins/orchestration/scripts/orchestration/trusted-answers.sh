#!/usr/bin/env bash
# trusted-answers.sh <issue#> <pr#> — emit new trusted human answers as a JSON array.
# Each: {id, author, createdAt, edited, body, source}. exit 0 ok | 1 api fail.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$DIR/lib.sh"
load_config

issue="$1"; pr="$2"

# `gh api --paginate` concatenates one JSON array per page ([...][...]); `jq -s 'add'`
# merges them into a single array so `--argjson` below receives valid JSON. `// []`
# guards the zero-page case (slurp of empty input → null) so it stays a valid array.
icmts=$(gh api "repos/$REPO/issues/$issue/comments" --paginate | jq -s 'add // []') || { log ERROR "issue comments failed"; exit 1; }
pcmts=$(gh api "repos/$REPO/issues/$pr/comments" --paginate | jq -s 'add // []')     || { log ERROR "pr comments failed"; exit 1; }

# cutoff = created_at of the latest bot reference marker on the ISSUE. Per spec §4, "new
# trusted input" is measured after the latest of rework-requested:/decision-requested:/
# decision-clarify: — all three must reset the window (rework-requested: matters on a
# rework→re-review cycle, so pre-rework answers do not leak back in).
cutoff=$(echo "$icmts" | jq -r --arg b "$BOT" '
  [.[] | select(.user.login==$b and ((.body|startswith("rework-requested:")) or (.body|startswith("decision-requested:")) or (.body|startswith("decision-clarify:")))) | .created_at]
  | (max // "1970-01-01T00:00:00Z")')

# Merge issue + PR comments, tag source, drop bot-authored, keep created_at > cutoff.
candidates=$(jq -n --argjson i "$icmts" --argjson p "$pcmts" --arg b "$BOT" --arg cut "$cutoff" '
  ( ($i | map(. + {source:"issue"})) + ($p | map(. + {source:"pr"})) )
  | map(select(.user.login != $b and (.created_at > $cut)))
  | map({id:.id, author:.user.login, createdAt:.created_at, edited:(.updated_at != .created_at), body:.body, source:.source})')

# Trust filter: keep only authors that pass is_trusted (queried now == conversion time).
result='[]'
while IFS= read -r row; do
  [ -z "$row" ] && continue
  author=$(echo "$row" | jq -r '.author')
  if is_trusted "$author"; then
    result=$(jq -c --argjson r "$row" '. + [$r]' <<<"$result")
  fi
done < <(echo "$candidates" | jq -c '.[]')

echo "$result"
