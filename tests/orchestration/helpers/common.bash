#!/usr/bin/env bash
# Shared bats helpers.

setup_gh_stub() {
  export GH_BIN="$BATS_TEST_TMPDIR/bin"
  export GH_CALLS="$BATS_TEST_TMPDIR/gh-calls.log"
  export GH_RESPONSES="$BATS_TEST_TMPDIR/gh-responses"
  mkdir -p "$GH_BIN" "$GH_RESPONSES"
  : > "$GH_CALLS"
  cp "$BATS_TEST_DIRNAME/helpers/gh-stub.sh" "$GH_BIN/gh"
  chmod +x "$GH_BIN/gh"
  export PATH="$GH_BIN:$PATH"
}

# queue_response <json-or-text> — enqueue stdout for the next read-style gh call.
# Counts only digit-prefixed files (the stub's .idx dotfile is invisible to plain ls),
# so write-time indices here stay in lockstep with the stub's read-time .idx counter
# as long as all responses are queued before the script under test runs.
queue_response() {
  local n
  n=$(( $(ls "$GH_RESPONSES" 2>/dev/null | grep -c '^[0-9]' || true) + 1 ))
  printf '%s' "$1" > "$GH_RESPONSES/$n"
}
