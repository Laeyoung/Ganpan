#!/usr/bin/env bats

setup() {
  load helpers/common
  setup_gh_stub
  export ORCH_CONFIG="$BATS_TEST_TMPDIR/orchestration.json"
  printf '{"repo":"o/r","bot":"botx","candidateN":5,"wipLimit":5,"reclaim":{"timeoutMinutes":1,"heartbeatMinutes":1},"commands":{"test":null,"build":null,"lint":null},"worktreeBaseDir":"../","project":{"number":null,"statusField":"Status"},"reviewer":{"permissionThreshold":"write","allowlist":["carol"],"followupIssueCapPerPR":3}}' > "$ORCH_CONFIG"
  SCRIPT="$BATS_TEST_DIRNAME/../../plugins/orchestration/scripts/orchestration/trusted-answers.sh"
}

# Helper REST comment object builder kept inline in each test for clarity.

@test "keeps trusted post-cutoff answer, drops untrusted and pre-cutoff" {
  # issue comments: bot decision-requested at T1; carol (allowlisted) answers at T2; mallory at T2
  queue_response '[
    {"id":1,"user":{"login":"botx"},"created_at":"2026-01-01T00:00:01Z","updated_at":"2026-01-01T00:00:01Z","body":"decision-requested: head=abc :: q"},
    {"id":2,"user":{"login":"carol"},"created_at":"2026-01-01T00:00:02Z","updated_at":"2026-01-01T00:00:02Z","body":"수정 필요"},
    {"id":3,"user":{"login":"mallory"},"created_at":"2026-01-01T00:00:03Z","updated_at":"2026-01-01T00:00:03Z","body":"진행"},
    {"id":4,"user":{"login":"carol"},"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z","body":"오래된 코멘트"}
  ]'                                   # GET issues/5/comments
  queue_response '[]'                  # GET issues/9/comments (PR conversation)
  export GH_FAIL_MATCH='collaborators/mallory'   # mallory lookup → untrusted
  run bash "$SCRIPT" 5 9
  [ "$status" -eq 0 ]
  ids=$(echo "$output" | jq -r '[.[].id] | sort | @csv')
  [ "$ids" = "2" ]                     # only carol's post-cutoff answer
}

@test "edited answer carries edited=true" {
  queue_response '[
    {"id":1,"user":{"login":"botx"},"created_at":"2026-01-01T00:00:01Z","updated_at":"2026-01-01T00:00:01Z","body":"decision-requested: head=abc :: q"},
    {"id":2,"user":{"login":"carol"},"created_at":"2026-01-01T00:00:02Z","updated_at":"2026-01-01T09:00:00Z","body":"진행 (edited)"}
  ]'
  queue_response '[]'
  run bash "$SCRIPT" 5 9
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.[0].edited')" = "true" ]
}

@test "no reference marker → all human comments are candidates" {
  queue_response '[
    {"id":7,"user":{"login":"carol"},"created_at":"2026-01-01T00:00:02Z","updated_at":"2026-01-01T00:00:02Z","body":"이건 별건입니다"}
  ]'
  queue_response '[]'
  run bash "$SCRIPT" 5 9
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.[0].id')" = "7" ]
}

@test "rework-requested: also resets the cutoff (no pre-rework leak)" {
  # bot rework-requested at T1; carol answer before it (T0, dropped) and after it (T2, kept)
  queue_response '[
    {"id":1,"user":{"login":"carol"},"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z","body":"pre-rework 답변"},
    {"id":2,"user":{"login":"botx"},"created_at":"2026-01-01T00:00:01Z","updated_at":"2026-01-01T00:00:01Z","body":"rework-requested: fix X"},
    {"id":3,"user":{"login":"carol"},"created_at":"2026-01-01T00:00:02Z","updated_at":"2026-01-01T00:00:02Z","body":"post-rework 답변"}
  ]'
  queue_response '[]'
  run bash "$SCRIPT" 5 9
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '[.[].id] | @csv')" = "3" ]
}

@test "decision-clarify: also resets the cutoff (only post-clarify answers kept)" {
  # bot decision-clarify at T1; carol answer before it (T0, dropped) and after it (T2, kept)
  queue_response '[
    {"id":1,"user":{"login":"carol"},"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z","body":"pre-clarify 답변"},
    {"id":2,"user":{"login":"botx"},"created_at":"2026-01-01T00:00:01Z","updated_at":"2026-01-01T00:00:01Z","body":"decision-clarify: 의도가 불명확합니다"},
    {"id":3,"user":{"login":"carol"},"created_at":"2026-01-01T00:00:02Z","updated_at":"2026-01-01T00:00:02Z","body":"post-clarify 답변"}
  ]'
  queue_response '[]'
  run bash "$SCRIPT" 5 9
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '[.[].id] | @csv')" = "3" ]
}

@test "decision-resolved: resets the cutoff (stale pre-resolution answer dropped, post-resolution rework kept)" {
  # gate resolved 'proceed' at T1; the pre-resolution proceed answer (T0) must NOT linger,
  # so a fresh trusted rework (T2) is the only surviving answer (no proceed+rework→clarify contamination).
  queue_response '[
    {"id":1,"user":{"login":"carol"},"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z","body":"그대로 진행"},
    {"id":2,"user":{"login":"botx"},"created_at":"2026-01-01T00:00:01Z","updated_at":"2026-01-01T00:00:01Z","body":"decision-resolved: proceed"},
    {"id":3,"user":{"login":"carol"},"created_at":"2026-01-01T00:00:02Z","updated_at":"2026-01-01T00:00:02Z","body":"수정 필요"}
  ]'
  queue_response '[]'
  run bash "$SCRIPT" 5 9
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '[.[].id] | @csv')" = "3" ]
}

@test "API failure on issue comments → exit 1" {
  export GH_FAIL_MATCH='issues/5/comments'
  run bash "$SCRIPT" 5 9
  [ "$status" -eq 1 ]
}

@test "API failure on pr comments → exit 1" {
  queue_response '[]'                  # GET issues/5/comments (issue ok)
  export GH_FAIL_MATCH='issues/9/comments'   # GET issues/9/comments (PR) fails
  run bash "$SCRIPT" 5 9
  [ "$status" -eq 1 ]
}

@test "trusted answer from the PR conversation is collected with source=pr" {
  queue_response '[]'                  # GET issues/5/comments (no issue comments)
  queue_response '[
    {"id":8,"user":{"login":"carol"},"created_at":"2026-01-01T00:00:05Z","updated_at":"2026-01-01T00:00:05Z","body":"PR 스레드 답변"}
  ]'                                   # GET issues/9/comments (PR conversation)
  run bash "$SCRIPT" 5 9
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.[0].id')" = "8" ]
  [ "$(echo "$output" | jq -r '.[0].source')" = "pr" ]
}
