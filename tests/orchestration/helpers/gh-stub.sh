#!/usr/bin/env bash
# Fake `gh` for bats. Logs each call (subcommand-first) to $GH_CALLS.
# For stdout-producing READ commands, emits the next queued response file
# $GH_RESPONSES/<n> in call order. Exit code overridable via $GH_EXIT.
# NOTE: `gh api` is only used for WRITES here (PATCH heartbeat, DELETE claim),
# so it is deliberately NOT in the read-emitting case — it must not consume a
# response slot (that would desync the queue index for later reads).
echo "$*" >> "$GH_CALLS"
# GH_FAIL_MATCH (extended regex): make any call whose args match it exit 1 — used to
# exercise failure/rollback paths. Only fail WRITE calls with it; failing a queued READ
# would leave its response unconsumed and desync the index for later reads.
if [ -n "${GH_FAIL_MATCH:-}" ] && printf '%s' "$*" | grep -qE "$GH_FAIL_MATCH"; then
  exit 1
fi
case "${1:-} ${2:-}" in
  "issue list"|"issue view"|"pr view"|"pr list"|"project view"|"project field-list"|"project item-list")
    idx_file="$GH_RESPONSES/.idx"
    n=$(( $(cat "$idx_file" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$idx_file"
    [ -f "$GH_RESPONSES/$n" ] && cat "$GH_RESPONSES/$n" || true
    ;;
esac
exit "${GH_EXIT:-0}"
