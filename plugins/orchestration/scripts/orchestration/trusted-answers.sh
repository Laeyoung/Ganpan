#!/usr/bin/env bash
# trusted-answers.sh <issue#> <pr#> — emit new trusted human answers as a JSON array.
# Sources: issue-thread comments, PR conversation comments, PR inline review comments
# (pulls/<pr>/comments), and PR review summaries (pulls/<pr>/reviews, body only).
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
# Inline review comments (code-line) and review summaries. A trusted user can answer via
# "Submit review" or a code-line comment, not just the PR conversation — collect both so
# those answers reach the decision gate / rework path.
rcmts=$(gh api "repos/$REPO/pulls/$pr/comments" --paginate | jq -s 'add // []')      || { log ERROR "pr review comments failed"; exit 1; }
reviews=$(gh api "repos/$REPO/pulls/$pr/reviews" --paginate | jq -s 'add // []')     || { log ERROR "pr reviews failed"; exit 1; }

# cutoff = created_at of the latest bot gate-lifecycle marker on the ISSUE. Per spec §4,
# "new trusted input" is measured after the latest of rework-requested: / decision-requested:
# / decision-clarify: / decision-resolved: — all must reset the window:
#  - rework-requested: matters on a rework→re-review cycle (no pre-rework leak),
#  - decision-resolved: matters after a gate closes (terminal) so a stale pre-resolution
#    answer (e.g. an old "proceed") cannot linger and contaminate a later trusted "rework"
#    into a spurious proceed+rework→clarify; only post-resolution answers count.
cutoff=$(echo "$icmts" | jq -r --arg b "$BOT" '
  [.[] | select(.user.login==$b and ((.body|startswith("rework-requested:")) or (.body|startswith("decision-requested:")) or (.body|startswith("decision-clarify:")) or (.body|startswith("decision-resolved:")))) | .created_at]
  | (max // "1970-01-01T00:00:00Z")')

# Merge all four sources, normalise to a common shape, tag source, drop bot-authored, keep
# created_at > cutoff. PR review summaries (pulls/<pr>/reviews) timestamp on submitted_at and
# expose no updated_at (so they are never marked edited); an empty-body review (a bare
# APPROVE/REQUEST_CHANGES with no text) is not an answer and is dropped. The cutoff stays the
# issue-thread marker time — gate markers are issue-scoped (a PR-side marker must not shift it).
candidates=$(jq -n --argjson i "$icmts" --argjson p "$pcmts" --argjson r "$rcmts" --argjson v "$reviews" --arg b "$BOT" --arg cut "$cutoff" '
  ( ($i | map({id:.id, author:.user.login, createdAt:.created_at, edited:(.updated_at != .created_at), body:.body, source:"issue"}))
  + ($p | map({id:.id, author:.user.login, createdAt:.created_at, edited:(.updated_at != .created_at), body:.body, source:"pr"}))
  + ($r | map({id:.id, author:.user.login, createdAt:.created_at, edited:(.updated_at != .created_at), body:.body, source:"pr-review-comment"}))
  + ($v | map(select(.body != null and .body != "")) | map({id:.id, author:.user.login, createdAt:.submitted_at, edited:false, body:.body, source:"pr-review"})) )
  | map(select(.author != $b and (.createdAt > $cut)))')

# Trust filter: resolve each DISTINCT author exactly once (queried now == conversion
# time), then keep every answer whose author is trusted. This per-distinct-author resolution
# is also the memoization the inline-comment path needs — a reviewer who leaves many code-line
# comments triggers exactly one permission lookup, not one per comment. Per-author (not per-row) so a
# transient permission-lookup failure can never keep some of one author's answers while
# dropping others — a partial set could flip decision-resolve to a wrong single-bucket
# action, and once a resolution marker advances the cutoff the dropped answer is lost for
# good. A lookup error (is_trusted rc 2) aborts the tick so the lane retries cleanly,
# rather than treating the author as untrusted and silently discarding a real answer.
trusted='[]'
while IFS= read -r author; do
  [ -z "$author" ] && continue
  rc=0; is_trusted "$author" || rc=$?
  case "$rc" in
    0) trusted=$(jq -c --arg a "$author" '. + [$a]' <<<"$trusted") ;;
    2) log ERROR "trust lookup failed for '$author' — skipping this issue this tick"; exit 1 ;;
    *) : ;;   # 1 → definitively untrusted → drop
  esac
done < <(echo "$candidates" | jq -r '[.[].author] | unique | .[]')

jq -c --argjson t "$trusted" 'map(select(.author | IN($t[])))' <<<"$candidates"
