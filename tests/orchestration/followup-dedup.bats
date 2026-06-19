setup() {
  load helpers/common
  setup_gh_stub
  export ORCH_CONFIG="$BATS_TEST_TMPDIR/orchestration.json"
  printf '{"repo":"o/r","bot":"botx","candidateN":5,"wipLimit":5,"reclaim":{"timeoutMinutes":1,"heartbeatMinutes":1},"commands":{"test":null,"build":null,"lint":null},"worktreeBaseDir":"../","project":{"number":null,"statusField":"Status"},"reviewer":{"permissionThreshold":"write","allowlist":[],"followupIssueCapPerPR":3}}' > "$ORCH_CONFIG"
  SCRIPT="$BATS_TEST_DIRNAME/../../plugins/orchestration/scripts/orchestration/followup-dedup.sh"
}

@test "fresh item under cap → create" {
  queue_response '{"comments":[]}'
  run bash "$SCRIPT" 5 comment-100
  [ "$status" -eq 0 ]; [ "$output" = "create" ]
}

@test "same item already created → skip-exists" {
  queue_response '{"comments":[{"author":{"login":"botx"},"body":"followup-created: comment-100 → #42"}]}'
  run bash "$SCRIPT" 5 comment-100
  [ "$output" = "skip-exists" ]
}

@test "cap reached for a new item → cap-exceeded" {
  queue_response '{"comments":[
    {"author":{"login":"botx"},"body":"followup-created: comment-1 → #11"},
    {"author":{"login":"botx"},"body":"followup-created: comment-2 → #12"},
    {"author":{"login":"botx"},"body":"followup-created: comment-3 → #13"}
  ]}'
  run bash "$SCRIPT" 5 comment-100
  [ "$output" = "cap-exceeded" ]
}

@test "item already cap-noted → cap-noted (idempotent, no re-post)" {
  queue_response '{"comments":[
    {"author":{"login":"botx"},"body":"followup-created: comment-1 → #11"},
    {"author":{"login":"botx"},"body":"followup-created: comment-2 → #12"},
    {"author":{"login":"botx"},"body":"followup-created: comment-3 → #13"},
    {"author":{"login":"botx"},"body":"cap-exceeded: comment-100 | manual create needed"}
  ]}'
  run bash "$SCRIPT" 5 comment-100
  [ "$output" = "cap-noted" ]
}

@test "human-forged followup-created does not count (bot-only)" {
  queue_response '{"comments":[{"author":{"login":"attacker"},"body":"followup-created: comment-100 → #999"}]}'
  run bash "$SCRIPT" 5 comment-100
  [ "$output" = "create" ]
}

@test "API failure → exit 1" {
  export GH_FAIL_MATCH='issue view'
  run bash "$SCRIPT" 5 comment-100
  [ "$status" -eq 1 ]
}
