#!/usr/bin/env bats

setup() {
  load helpers/common
  setup_gh_stub
  export ORCH_CONFIG="$BATS_TEST_TMPDIR/orchestration.json"
  printf '{"repo":"o/r","bot":"botx","candidateN":1,"wipLimit":1,"reclaim":{"timeoutMinutes":1,"heartbeatMinutes":1},"commands":{"test":null,"build":null,"lint":null},"worktreeBaseDir":"../","project":{"number":null,"statusField":"Status"}}' > "$ORCH_CONFIG"
  SCRIPT="$BATS_TEST_DIRNAME/../../scripts/orchestration/heartbeat.sh"
}

@test "edits the existing claim comment by id (PATCH), not --edit-last" {
  export CLAIM_TOKEN_OVERRIDE='2026-02-01T00:00:00Z-botx-h-1'
  queue_response '{"comments":[{"id":555,"author":{"login":"botx"},"body":"claim: old-token"},{"id":556,"author":{"login":"botx"},"body":"PR: https://x"}]}'
  run bash "$SCRIPT" 42
  [ "$status" -eq 0 ]
  # the refreshed body must actually be written (not just the comment URL hit)
  grep -q 'api --method PATCH /repos/o/r/issues/comments/555 -f body=claim: 2026-02-01T00:00:00Z-botx-h-1' "$GH_CALLS"
  ! grep -q -- '--edit-last' "$GH_CALLS"
}

@test "no claim comment → exit 1" {
  queue_response '{"comments":[{"id":1,"author":{"login":"botx"},"body":"PR: x"}]}'
  run bash "$SCRIPT" 42
  [ "$status" -eq 1 ]
}

@test "with multiple bot claim comments, patches the NEWEST (matches reclaim's max)" {
  export CLAIM_TOKEN_OVERRIDE='2026-02-01T00:00:00Z-botx-h-1'
  # id 100 = stale (old token, left by an earlier reclaim cycle); id 200 = live (newer token).
  queue_response '{"comments":[{"id":100,"author":{"login":"botx"},"body":"claim: 2000-01-01T00:00:00Z-botx-h-9"},{"id":200,"author":{"login":"botx"},"body":"claim: 2025-01-01T00:00:00Z-botx-h-2"}]}'
  run bash "$SCRIPT" 42
  [ "$status" -eq 0 ]
  grep -q 'api --method PATCH /repos/o/r/issues/comments/200' "$GH_CALLS"   # newest
  ! grep -q 'api --method PATCH /repos/o/r/issues/comments/100' "$GH_CALLS" # not the stale one
}
