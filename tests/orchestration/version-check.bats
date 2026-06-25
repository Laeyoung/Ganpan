#!/usr/bin/env bats

# version-check.sh — throttled, non-interactive "is there a newer ganpan?" check.

setup() {
  load helpers/common
  setup_gh_stub
  export GANPAN_STATE_DIR="$BATS_TEST_TMPDIR/state"   # isolate the throttle stamp
  export VERSION_CHECK_INTERVAL_DAYS=3
  SCRIPT="$BATS_TEST_DIRNAME/../../plugins/orchestration/scripts/orchestration/version-check.sh"
}

@test "newer remote version → update-available (and stamps)" {
  queue_response '{"name":"ganpan","version":"9.9.9"}'
  run bash "$SCRIPT" 1.6.0
  [ "$status" -eq 0 ]
  [ "$output" = "update-available: 1.6.0 -> 9.9.9" ]
  [ -f "$GANPAN_STATE_DIR/version-check.epoch" ]   # recorded the check
}

@test "same version → current" {
  queue_response '{"version":"1.6.0"}'
  run bash "$SCRIPT" 1.6.0
  [ "$status" -eq 0 ]
  [ "$output" = "current" ]
}

@test "local checkout ahead of remote → current (never flags a downgrade)" {
  queue_response '{"version":"1.6.0"}'
  run bash "$SCRIPT" 2.0.0
  [ "$status" -eq 0 ]
  [ "$output" = "current" ]
}

@test "checked within the interval → skip, no network call" {
  mkdir -p "$GANPAN_STATE_DIR"
  date -u +%s > "$GANPAN_STATE_DIR/version-check.epoch"   # just checked
  run bash "$SCRIPT" 1.6.0
  [ "$status" -eq 0 ]
  [ "$output" = "skip" ]
  ! grep -q 'api repos' "$GH_CALLS"    # throttle short-circuits before any gh call
}

@test "stale stamp (older than interval) → re-checks" {
  mkdir -p "$GANPAN_STATE_DIR"
  echo 0 > "$GANPAN_STATE_DIR/version-check.epoch"        # epoch 0 == ancient
  queue_response '{"version":"9.9.9"}'
  run bash "$SCRIPT" 1.6.0
  [ "$status" -eq 0 ]
  [ "$output" = "update-available: 1.6.0 -> 9.9.9" ]
}

@test "API failure / offline → unknown (exit 0, does not fail the lane)" {
  export GH_FAIL_MATCH='api repos'
  run bash "$SCRIPT" 1.6.0
  [ "$status" -eq 0 ]
  [ "$output" = "unknown" ]
}

@test "minor/patch bump is detected as update-available" {
  queue_response '{"version":"1.6.1"}'
  run bash "$SCRIPT" 1.6.0
  [ "$status" -eq 0 ]
  [ "$output" = "update-available: 1.6.0 -> 1.6.1" ]
}
