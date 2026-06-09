#!/usr/bin/env bats

setup() {
  load helpers/common
  setup_gh_stub
  export ORCH_CONFIG="$BATS_TEST_TMPDIR/orchestration.json"
  printf '{"repo":"o/r","bot":"botx","candidateN":3,"wipLimit":5,"reclaim":{"timeoutMinutes":120,"heartbeatMinutes":15},"commands":{"test":null,"build":null,"lint":null},"worktreeBaseDir":"../","project":{"number":null,"statusField":"Status"}}' > "$ORCH_CONFIG"
  export CLAIM_BACKOFF_SECS=0   # make tests fast
  SCRIPT="$BATS_TEST_DIRNAME/../../scripts/orchestration/claim.sh"
}

@test "no candidates → exit 1" {
  queue_response '[]'                 # issue list
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "clean claim → exit 0, prints issue number, writes label+assignee+claim comment" {
  queue_response '[{"number":42,"createdAt":"2026-01-01T00:00:00Z"}]'   # list
  # re-read after claim: in-progress present, single bot assignee, one claim token.
  # Pin our token so the re-read visibility check matches on the first pass.
  export CLAIM_TOKEN_OVERRIDE='2026-02-01T00:00:00Z-botx-h-1'
  queue_response '{"labels":[{"name":"status:in-progress"}],"assignees":[{"login":"botx"}],"comments":[{"id":1,"author":{"login":"botx"},"body":"claim: 2026-02-01T00:00:00Z-botx-h-1"}]}'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "42" ]
  grep -q 'issue edit 42 --add-label status:in-progress --remove-label status:agent-ready' "$GH_CALLS"
  grep -q 'issue edit 42 --add-assignee botx' "$GH_CALLS"
  grep -q 'issue comment 42 --body claim: ' "$GH_CALLS"
}

@test "two distinct claim tokens → lexicographic-min wins; if ours is larger we lose (exit 2) and delete our comment" {
  queue_response '[{"number":7,"createdAt":"2026-01-01T00:00:00Z"}]'    # list
  # re-read shows TWO claim tokens; the smaller one belongs to another process
  queue_response '{"labels":[{"name":"status:in-progress"}],"assignees":[{"login":"botx"}],"comments":[
    {"id":10,"author":{"login":"botx"},"body":"claim: 2026-01-01T00:00:00Z-botx-h-999"},
    {"id":11,"author":{"login":"botx"},"body":"claim: 2030-01-01T00:00:00Z-botx-h-1000"}]}'
  # Force our token to be the LARGER one so we lose deterministically:
  export CLAIM_TOKEN_OVERRIDE='2030-01-01T00:00:00Z-botx-h-1000'
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
  grep -q 'api --method DELETE /repos/o/r/issues/comments/11' "$GH_CALLS"  # deleted OUR comment (id 11), not the winner's
}

@test "propagation lag: comment not yet visible → backoff retry then succeed" {
  queue_response '[{"number":9,"createdAt":"2026-01-01T00:00:00Z"}]'    # list
  queue_response '{"labels":[{"name":"status:in-progress"}],"assignees":[{"login":"botx"}],"comments":[]}'  # 1st re-read: empty
  queue_response '{"labels":[{"name":"status:in-progress"}],"assignees":[{"login":"botx"}],"comments":[{"id":1,"author":{"login":"botx"},"body":"claim: 2026-02-01T00:00:00Z-botx-h-1"}]}'  # 2nd re-read
  export CLAIM_TOKEN_OVERRIDE='2026-02-01T00:00:00Z-botx-h-1'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "9" ]
}

@test "claim comment never visible after all retries → exit 2, no success echo" {
  queue_response '[{"number":13,"createdAt":"2026-01-01T00:00:00Z"}]'   # list
  export CLAIM_RETRIES=2 CLAIM_TOKEN_OVERRIDE='2026-02-01T00:00:00Z-botx-h-1'
  queue_response '{"labels":[{"name":"status:in-progress"}],"assignees":[{"login":"botx"}],"comments":[]}'  # re-read 1: empty
  queue_response '{"labels":[{"name":"status:in-progress"}],"assignees":[{"login":"botx"}],"comments":[]}'  # re-read 2: still empty
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
  [ "$output" != "13" ]
}

@test "bot not among assignees → exit 2" {
  queue_response '[{"number":14,"createdAt":"2026-01-01T00:00:00Z"}]'   # list
  export CLAIM_TOKEN_OVERRIDE='2026-02-01T00:00:00Z-botx-h-1'
  # claim comment visible (so the visibility loop passes) but assignees does NOT include botx
  queue_response '{"labels":[{"name":"status:in-progress"}],"assignees":[],"comments":[{"id":1,"author":{"login":"botx"},"body":"claim: 2026-02-01T00:00:00Z-botx-h-1"}]}'
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
}

@test "in-progress label missing on re-read → re-added, then claim succeeds" {
  queue_response '[{"number":15,"createdAt":"2026-01-01T00:00:00Z"}]'   # list
  export CLAIM_TOKEN_OVERRIDE='2026-02-01T00:00:00Z-botx-h-1'
  # claim comment visible + assignee present, but labels[] lacks status:in-progress (transient race removed it)
  queue_response '{"labels":[],"assignees":[{"login":"botx"}],"comments":[{"id":1,"author":{"login":"botx"},"body":"claim: 2026-02-01T00:00:00Z-botx-h-1"}]}'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "15" ]
  # the re-add is a bare --add-label (no --remove-label), distinct from the initial mark
  grep -q 'issue edit 15 --add-label status:in-progress --repo' "$GH_CALLS"
}
