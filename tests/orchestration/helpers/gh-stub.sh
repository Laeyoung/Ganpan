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
# GH_API_404_MATCH (extended regex): simulate a *genuine* HTTP 404 on a matching call —
# print gh's "(HTTP 404)" message to stderr and exit 1, WITHOUT consuming a queued read
# slot. Distinct from GH_FAIL_MATCH (a generic non-zero exit with NO message): callers that
# must tell a real 404 ("resource absent") apart from a transient/permission error can be
# exercised both ways. Checked before the read-emitting clauses so it never reads a slot.
if [ -n "${GH_API_404_MATCH:-}" ] && printf '%s' "$*" | grep -qE "$GH_API_404_MATCH"; then
  echo "gh: Branch not protected (HTTP 404)" >&2
  exit 1
fi
# `gh api user` (the actor-identity probe) — emit a configurable login WITHOUT
# consuming a queued-response slot. Standalone case BEFORE the queue-emitting one;
# 3-word expansion so "api user "* matches `gh api user --jq .login`.
# `-` (not `:-`): GH_STUB_LOGIN set-but-empty yields an empty login, for the
# "empty login" gate test. Must precede the read-api clause below, which would
# otherwise consume a queue slot for `gh api user`.
case "${1:-} ${2:-} ${3:-}" in
  "api user "*)
    # GH_USER_FAIL_TIMES: fail the first N `gh api user` probes with exit 1 and no
    # output, then succeed — exercises the transient-failure retry path in
    # require_bot_actor. The counter persists across calls in $GH_CALLS.userfail.
    if [ -n "${GH_USER_FAIL_TIMES:-}" ]; then
      state="$GH_CALLS.userfail"
      done_n=$(cat "$state" 2>/dev/null || echo 0)
      if [ "$done_n" -lt "$GH_USER_FAIL_TIMES" ]; then
        echo $((done_n + 1)) > "$state"
        exit 1
      fi
    fi
    echo "${GH_STUB_LOGIN-bot-login}"; exit "${GH_EXIT:-0}" ;;
esac
# Read-style `gh api` (GET): emit the next queued response. Write `api` (-X/--method
# POST|PUT|PATCH|DELETE) is left to fall through and must NOT consume a slot.
if [ "${1:-}" = "api" ] && ! printf '%s' "$*" | grep -qE -- '(-X|--method)[= ](POST|PUT|PATCH|DELETE)'; then
  idx_file="$GH_RESPONSES/.idx"
  n=$(( $(cat "$idx_file" 2>/dev/null || echo 0) + 1 ))
  echo "$n" > "$idx_file"
  [ -f "$GH_RESPONSES/$n" ] && cat "$GH_RESPONSES/$n" || true
  exit "${GH_EXIT:-0}"
fi
case "${1:-} ${2:-}" in
  "issue list"|"issue view"|"pr view"|"pr list"|"project view"|"project field-list"|"project item-list")
    idx_file="$GH_RESPONSES/.idx"
    n=$(( $(cat "$idx_file" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$idx_file"
    [ -f "$GH_RESPONSES/$n" ] && cat "$GH_RESPONSES/$n" || true
    ;;
esac
# Mimic real `gh`, which prints the resource URL to stdout on a successful mutating
# write (issue edit/comment/create, pr create/merge) even non-interactively. Opt-in via
# GH_EMIT_WRITE_URL so existing tests asserting exact stdout stay unaffected; a script
# that captures its return via $(…) must keep these off its own stdout. These are
# WRITES — they do NOT consume a queued-response slot.
if [ -n "${GH_EMIT_WRITE_URL:-}" ]; then
  case "${1:-} ${2:-}" in
    "issue edit"|"issue comment"|"issue create"|"pr create"|"pr merge")
      echo "https://github.com/o/r/issues/STUB-URL" ;;
  esac
  # `gh api --method PATCH|DELETE …` (e.g. heartbeat's claim refresh, claim.sh's
  # loser-comment cleanup) also prints a body/URL on success — guard the same way
  # so a captured+mutating script that forgets to redirect it is caught. (Read
  # `gh api` GET already returned above, so this only matches writes.)
  if [ "${1:-}" = "api" ] && printf '%s' "$*" | grep -qE -- '(-X|--method)[= ](POST|PUT|PATCH|DELETE)'; then
    echo "https://github.com/o/r/issues/STUB-URL"
  fi
fi
exit "${GH_EXIT:-0}"
