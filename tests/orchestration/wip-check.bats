#!/usr/bin/env bats

setup() {
  load helpers/common
  setup_gh_stub
  export ORCH_CONFIG="$BATS_TEST_TMPDIR/orchestration.json"
  printf '{"repo":"o/r","bot":"botx","candidateN":1,"wipLimit":5,"reclaim":{"timeoutMinutes":1,"heartbeatMinutes":1},"commands":{"test":null,"build":null,"lint":null},"worktreeBaseDir":"../","project":{"number":null,"statusField":"Status"}}' > "$ORCH_CONFIG"
  SCRIPT="$BATS_TEST_DIRNAME/../../scripts/orchestration/wip-check.sh"
}

@test "below limit → OK exit 0" {
  queue_response '[{"number":1},{"number":2}]'   # in-review = 2
  queue_response '[{"number":3}]'                # qa = 1  (total 3 < 5)
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "at limit → EXCEED exit 1" {
  queue_response '[{"number":1},{"number":2},{"number":3}]'  # 3
  queue_response '[{"number":4},{"number":5}]'               # 2 (total 5 == limit)
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [ "$output" = "EXCEED" ]
}

@test "uses --limit 1000 to avoid default-30 undercount" {
  queue_response '[]'; queue_response '[]'
  bash "$SCRIPT" || true
  grep -q 'issue list --label status:in-review --limit 1000' "$GH_CALLS"
  grep -q 'issue list --label status:qa --limit 1000' "$GH_CALLS"
}

@test "gh API failure → EXCEED-free exit 2 (does not silently report OK)" {
  export GH_EXIT=1                      # every gh call fails
  queue_response '[]'                   # response is emitted but gh still exits 1 (pipefail catches it)
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
}
