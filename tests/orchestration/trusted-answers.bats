#!/usr/bin/env bats

setup() {
  load helpers/common
  setup_gh_stub
  export ORCH_CONFIG="$BATS_TEST_TMPDIR/orchestration.json"
  printf '{"repo":"o/r","bot":"botx","candidateN":5,"wipLimit":5,"reclaim":{"timeoutMinutes":1,"heartbeatMinutes":1},"commands":{"test":null,"build":null,"lint":null},"worktreeBaseDir":"../","project":{"number":null,"statusField":"Status"},"reviewer":{"permissionThreshold":"write","allowlist":["carol"],"followupIssueCapPerPR":3}}' > "$ORCH_CONFIG"
  SCRIPT="$BATS_TEST_DIRNAME/../../plugins/orchestration/scripts/orchestration/trusted-answers.sh"
}

# The script makes four READ gh-api calls in order: issues/<issue>/comments,
# issues/<pr>/comments, pulls/<pr>/comments, pulls/<pr>/reviews — then per-distinct-author
# permission lookups. Tests queue one JSON array per call in that order. `empty_pr_sources`
# queues the two PR-review sources as empty for tests that only exercise the comment paths.
empty_pr_sources() { queue_response '[]'; queue_response '[]'; }   # pulls comments, pulls reviews

@test "keeps trusted post-cutoff answer, drops untrusted and pre-cutoff" {
  queue_response '[
    {"id":1,"user":{"login":"botx"},"created_at":"2026-01-01T00:00:01Z","updated_at":"2026-01-01T00:00:01Z","body":"decision-requested: head=abc :: q"},
    {"id":2,"user":{"login":"carol"},"created_at":"2026-01-01T00:00:02Z","updated_at":"2026-01-01T00:00:02Z","body":"수정 필요"},
    {"id":3,"user":{"login":"mallory"},"created_at":"2026-01-01T00:00:03Z","updated_at":"2026-01-01T00:00:03Z","body":"진행"},
    {"id":4,"user":{"login":"carol"},"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z","body":"오래된 코멘트"}
  ]'                                   # GET issues/5/comments
  queue_response '[]'                  # GET issues/9/comments (PR conversation)
  empty_pr_sources                     # GET pulls/9/comments, pulls/9/reviews
  queue_response 'read'                # collaborators/mallory/permission → untrusted
  run bash "$SCRIPT" 5 9
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '[.[].id] | sort | @csv')" = "2" ]
}

@test "transient trust-lookup failure aborts the tick (never drops a trusted answer)" {
  queue_response '[
    {"id":1,"user":{"login":"botx"},"created_at":"2026-01-01T00:00:01Z","updated_at":"2026-01-01T00:00:01Z","body":"decision-requested: head=abc :: q"},
    {"id":2,"user":{"login":"dave"},"created_at":"2026-01-01T00:00:02Z","updated_at":"2026-01-01T00:00:02Z","body":"수정 필요"}
  ]'
  queue_response '[]'
  empty_pr_sources
  export GH_FAIL_MATCH='collaborators/dave'
  run bash "$SCRIPT" 5 9
  [ "$status" -eq 1 ]
}

@test "edited answer carries edited=true" {
  queue_response '[
    {"id":1,"user":{"login":"botx"},"created_at":"2026-01-01T00:00:01Z","updated_at":"2026-01-01T00:00:01Z","body":"decision-requested: head=abc :: q"},
    {"id":2,"user":{"login":"carol"},"created_at":"2026-01-01T00:00:02Z","updated_at":"2026-01-01T09:00:00Z","body":"진행 (edited)"}
  ]'
  queue_response '[]'
  empty_pr_sources
  run bash "$SCRIPT" 5 9
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.[0].edited')" = "true" ]
}

@test "no reference marker → all human comments are candidates" {
  queue_response '[
    {"id":7,"user":{"login":"carol"},"created_at":"2026-01-01T00:00:02Z","updated_at":"2026-01-01T00:00:02Z","body":"이건 별건입니다"}
  ]'
  queue_response '[]'
  empty_pr_sources
  run bash "$SCRIPT" 5 9
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.[0].id')" = "7" ]
}

@test "rework-requested: also resets the cutoff (no pre-rework leak)" {
  queue_response '[
    {"id":1,"user":{"login":"carol"},"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z","body":"pre-rework 답변"},
    {"id":2,"user":{"login":"botx"},"created_at":"2026-01-01T00:00:01Z","updated_at":"2026-01-01T00:00:01Z","body":"rework-requested: fix X"},
    {"id":3,"user":{"login":"carol"},"created_at":"2026-01-01T00:00:02Z","updated_at":"2026-01-01T00:00:02Z","body":"post-rework 답변"}
  ]'
  queue_response '[]'
  empty_pr_sources
  run bash "$SCRIPT" 5 9
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '[.[].id] | @csv')" = "3" ]
}

@test "decision-clarify: also resets the cutoff (only post-clarify answers kept)" {
  queue_response '[
    {"id":1,"user":{"login":"carol"},"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z","body":"pre-clarify 답변"},
    {"id":2,"user":{"login":"botx"},"created_at":"2026-01-01T00:00:01Z","updated_at":"2026-01-01T00:00:01Z","body":"decision-clarify: 의도가 불명확합니다"},
    {"id":3,"user":{"login":"carol"},"created_at":"2026-01-01T00:00:02Z","updated_at":"2026-01-01T00:00:02Z","body":"post-clarify 답변"}
  ]'
  queue_response '[]'
  empty_pr_sources
  run bash "$SCRIPT" 5 9
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '[.[].id] | @csv')" = "3" ]
}

@test "decision-resolved: resets the cutoff (stale pre-resolution answer dropped, post-resolution rework kept)" {
  queue_response '[
    {"id":1,"user":{"login":"carol"},"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z","body":"그대로 진행"},
    {"id":2,"user":{"login":"botx"},"created_at":"2026-01-01T00:00:01Z","updated_at":"2026-01-01T00:00:01Z","body":"decision-resolved: proceed"},
    {"id":3,"user":{"login":"carol"},"created_at":"2026-01-01T00:00:02Z","updated_at":"2026-01-01T00:00:02Z","body":"수정 필요"}
  ]'
  queue_response '[]'
  empty_pr_sources
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
  export GH_FAIL_MATCH='issues/9/comments'
  run bash "$SCRIPT" 5 9
  [ "$status" -eq 1 ]
}

@test "API failure on pr review comments (pulls/<pr>/comments) → exit 1" {
  queue_response '[]'                  # issues/5/comments
  queue_response '[]'                  # issues/9/comments
  export GH_FAIL_MATCH='pulls/9/comments'
  run bash "$SCRIPT" 5 9
  [ "$status" -eq 1 ]
}

@test "API failure on pr reviews (pulls/<pr>/reviews) → exit 1" {
  queue_response '[]'                  # issues/5/comments
  queue_response '[]'                  # issues/9/comments
  queue_response '[]'                  # pulls/9/comments
  export GH_FAIL_MATCH='pulls/9/reviews'
  run bash "$SCRIPT" 5 9
  [ "$status" -eq 1 ]
}

@test "trusted answer from the PR conversation is collected with source=pr" {
  queue_response '[]'                  # issues/5/comments
  queue_response '[
    {"id":8,"user":{"login":"carol"},"created_at":"2026-01-01T00:00:05Z","updated_at":"2026-01-01T00:00:05Z","body":"PR 스레드 답변"}
  ]'                                   # issues/9/comments (PR conversation)
  empty_pr_sources
  run bash "$SCRIPT" 5 9
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.[0].id')" = "8" ]
  [ "$(echo "$output" | jq -r '.[0].source')" = "pr" ]
}

@test "trusted INLINE review comment (pulls/<pr>/comments) is collected with source=pr-review-comment" {
  queue_response '[]'                  # issues/5/comments
  queue_response '[]'                  # issues/9/comments
  queue_response '[
    {"id":20,"user":{"login":"carol"},"created_at":"2026-01-01T00:00:05Z","updated_at":"2026-01-01T00:00:05Z","body":"이 줄 고쳐주세요"}
  ]'                                   # pulls/9/comments (inline)
  queue_response '[]'                  # pulls/9/reviews
  run bash "$SCRIPT" 5 9
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.[0].id')" = "20" ]
  [ "$(echo "$output" | jq -r '.[0].source')" = "pr-review-comment" ]
}

@test "trusted REVIEW summary (pulls/<pr>/reviews) is collected with source=pr-review (uses submitted_at)" {
  queue_response '[]'                  # issues/5/comments
  queue_response '[]'                  # issues/9/comments
  queue_response '[]'                  # pulls/9/comments
  queue_response '[
    {"id":30,"user":{"login":"carol"},"submitted_at":"2026-01-01T00:00:05Z","state":"CHANGES_REQUESTED","body":"전반적으로 수정 필요"}
  ]'                                   # pulls/9/reviews
  run bash "$SCRIPT" 5 9
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.[0].id')" = "30" ]
  [ "$(echo "$output" | jq -r '.[0].source')" = "pr-review" ]
  [ "$(echo "$output" | jq -r '.[0].createdAt')" = "2026-01-01T00:00:05Z" ]
  [ "$(echo "$output" | jq -r '.[0].edited')" = "false" ]
}

@test "empty-body review (bare APPROVE) is dropped" {
  queue_response '[]'                  # issues/5/comments
  queue_response '[]'                  # issues/9/comments
  queue_response '[]'                  # pulls/9/comments
  queue_response '[
    {"id":31,"user":{"login":"carol"},"submitted_at":"2026-01-01T00:00:05Z","state":"APPROVED","body":""},
    {"id":32,"user":{"login":"carol"},"submitted_at":"2026-01-01T00:00:06Z","state":"APPROVED","body":null}
  ]'                                   # pulls/9/reviews (no text → not answers)
  run bash "$SCRIPT" 5 9
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "inline/review items honor the issue-thread cutoff and bot exclusion" {
  queue_response '[
    {"id":1,"user":{"login":"botx"},"created_at":"2026-01-01T00:00:05Z","updated_at":"2026-01-01T00:00:05Z","body":"decision-requested: head=abc :: q"}
  ]'                                   # issues/5/comments — cutoff at T5
  queue_response '[]'                  # issues/9/comments
  queue_response '[
    {"id":21,"user":{"login":"carol"},"created_at":"2026-01-01T00:00:01Z","updated_at":"2026-01-01T00:00:01Z","body":"pre-cutoff inline (dropped)"},
    {"id":22,"user":{"login":"carol"},"created_at":"2026-01-01T00:00:09Z","updated_at":"2026-01-01T00:00:09Z","body":"post-cutoff inline (kept)"}
  ]'                                   # pulls/9/comments
  queue_response '[
    {"id":33,"user":{"login":"botx"},"submitted_at":"2026-01-01T00:00:10Z","state":"COMMENTED","body":"bot review (excluded)"}
  ]'                                   # pulls/9/reviews — bot-authored, dropped
  run bash "$SCRIPT" 5 9
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '[.[].id] | @csv')" = "22" ]
}

@test "untrusted inline reviewer is dropped" {
  queue_response '[]'                  # issues/5/comments
  queue_response '[]'                  # issues/9/comments
  queue_response '[
    {"id":23,"user":{"login":"dave"},"created_at":"2026-01-01T00:00:05Z","updated_at":"2026-01-01T00:00:05Z","body":"inline from untrusted"}
  ]'                                   # pulls/9/comments
  queue_response '[]'                  # pulls/9/reviews
  queue_response 'read'                # collaborators/dave/permission → below threshold
  run bash "$SCRIPT" 5 9
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "one author across conversation + inline + review → a single permission lookup (memoized)" {
  # dave (not allowlisted) appears in all three PR sources; is_trusted must be queried ONCE.
  queue_response '[]'                  # issues/5/comments
  queue_response '[
    {"id":40,"user":{"login":"dave"},"created_at":"2026-01-01T00:00:02Z","updated_at":"2026-01-01T00:00:02Z","body":"conv"}
  ]'                                   # issues/9/comments
  queue_response '[
    {"id":41,"user":{"login":"dave"},"created_at":"2026-01-01T00:00:03Z","updated_at":"2026-01-01T00:00:03Z","body":"inline"}
  ]'                                   # pulls/9/comments
  queue_response '[
    {"id":42,"user":{"login":"dave"},"submitted_at":"2026-01-01T00:00:04Z","state":"CHANGES_REQUESTED","body":"review"}
  ]'                                   # pulls/9/reviews
  queue_response 'write'               # collaborators/dave/permission → trusted (write)
  run bash "$SCRIPT" 5 9
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '[.[].id] | sort | @csv')" = "40,41,42" ]
  [ "$(grep -c 'collaborators/dave/permission' "$GH_CALLS")" -eq 1 ]   # exactly one lookup
}

@test "answer at exactly the cutoff second is dropped (strict > boundary)" {
  queue_response '[
    {"id":1,"user":{"login":"botx"},"created_at":"2026-01-01T00:00:02Z","updated_at":"2026-01-01T00:00:02Z","body":"decision-requested: head=abc :: q"},
    {"id":2,"user":{"login":"carol"},"created_at":"2026-01-01T00:00:02Z","updated_at":"2026-01-01T00:00:02Z","body":"수정 필요"}
  ]'
  queue_response '[]'
  empty_pr_sources
  run bash "$SCRIPT" 5 9
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "one author's multiple post-cutoff answers are all kept (single trust decision)" {
  queue_response '[
    {"id":1,"user":{"login":"botx"},"created_at":"2026-01-01T00:00:01Z","updated_at":"2026-01-01T00:00:01Z","body":"decision-requested: head=abc :: q"},
    {"id":2,"user":{"login":"carol"},"created_at":"2026-01-01T00:00:02Z","updated_at":"2026-01-01T00:00:02Z","body":"진행"},
    {"id":3,"user":{"login":"carol"},"created_at":"2026-01-01T00:00:03Z","updated_at":"2026-01-01T00:00:03Z","body":"역시 수정"}
  ]'
  queue_response '[]'
  empty_pr_sources
  run bash "$SCRIPT" 5 9
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '[.[].id] | @csv')" = "2,3" ]
}

@test "all candidates untrusted → emits [] and exit 0" {
  queue_response '[
    {"id":1,"user":{"login":"botx"},"created_at":"2026-01-01T00:00:01Z","updated_at":"2026-01-01T00:00:01Z","body":"decision-requested: head=abc :: q"},
    {"id":2,"user":{"login":"dave"},"created_at":"2026-01-01T00:00:02Z","updated_at":"2026-01-01T00:00:02Z","body":"진행"}
  ]'
  queue_response '[]'
  empty_pr_sources
  queue_response 'read'                # collaborators/dave/permission → below threshold
  run bash "$SCRIPT" 5 9
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "cutoff marker in the issue thread also drops a pre-cutoff PR-conversation answer" {
  queue_response '[
    {"id":1,"user":{"login":"botx"},"created_at":"2026-01-01T00:00:05Z","updated_at":"2026-01-01T00:00:05Z","body":"decision-requested: head=abc :: q"}
  ]'
  queue_response '[
    {"id":8,"user":{"login":"carol"},"created_at":"2026-01-01T00:00:01Z","updated_at":"2026-01-01T00:00:01Z","body":"PR 스레드 오래된 답변"}
  ]'
  empty_pr_sources
  run bash "$SCRIPT" 5 9
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "mixed authors in one run: trusted kept, untrusted dropped" {
  queue_response '[
    {"id":1,"user":{"login":"botx"},"created_at":"2026-01-01T00:00:01Z","updated_at":"2026-01-01T00:00:01Z","body":"decision-requested: head=abc :: q"},
    {"id":2,"user":{"login":"carol"},"created_at":"2026-01-01T00:00:02Z","updated_at":"2026-01-01T00:00:02Z","body":"수정 필요"},
    {"id":3,"user":{"login":"dave"},"created_at":"2026-01-01T00:00:03Z","updated_at":"2026-01-01T00:00:03Z","body":"진행"}
  ]'
  queue_response '[]'
  empty_pr_sources
  queue_response 'read'                # collaborators/dave/permission → below threshold
  run bash "$SCRIPT" 5 9
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '[.[].id] | @csv')" = "2" ]
}

@test "a bot gate marker in the PR thread does not raise the cutoff (issue-thread only)" {
  queue_response '[]'                  # issues/5/comments (no markers)
  queue_response '[
    {"id":2,"user":{"login":"carol"},"created_at":"2026-01-01T00:00:01Z","updated_at":"2026-01-01T00:00:01Z","body":"수정 필요"},
    {"id":3,"user":{"login":"botx"},"created_at":"2026-01-01T00:00:05Z","updated_at":"2026-01-01T00:00:05Z","body":"decision-requested: head=abc :: q"}
  ]'                                   # issues/9/comments (PR thread, incl. a bot marker)
  empty_pr_sources
  run bash "$SCRIPT" 5 9
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '[.[].id] | @csv')" = "2" ]
}
