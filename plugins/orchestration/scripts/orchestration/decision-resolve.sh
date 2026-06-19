#!/usr/bin/env bash
# decision-resolve.sh — pure routing decision from classified trusted answers.
# stdin: {"answers":[{"createdAt":"<ISO8601Z>","bucket":"rework|proceed|followup|unclassifiable"}]}
# stdout: {"action":"rework|proceed|followup|clarify","reason":"..."}
# exit: 0 always (out-of-schema → clarify; only unparseable JSON exits nonzero via pipefail)
set -euo pipefail

input=$(cat)

# Out-of-schema bucket (classifier error) → route to clarify, never crash the lane (AC26).
# `if ! ... ; then` disables set -e for this pipeline; `jq -e` exits 1 when the test is false.
if ! echo "$input" | jq -e '
  all(.answers[]?; .bucket | IN("rework","proceed","followup","unclassifiable"))' >/dev/null 2>&1; then
  printf '%s\n' '{"action":"clarify","reason":"schema-violation"}'
  exit 0
fi

echo "$input" | jq -c '
  ([.answers[]? | select(.bucket != "unclassifiable")] | sort_by(.createdAt)) as $c
  | if ($c | length) == 0 then
      {action:"clarify", reason:"no-classifiable-answer"}
    else
      ($c[0].bucket) as $first
      | if any($c[]; .bucket != $first) then
          {action:"clarify", reason:"conflict"}
        else
          {action:$first, reason:"first-bucket"}
        end
    end'
