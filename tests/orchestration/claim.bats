#!/usr/bin/env bats

setup() {
  load helpers/common
  setup_gh_stub
  export ORCH_CONFIG="$BATS_TEST_TMPDIR/orchestration.json"
  printf '{"repo":"o/r","bot":"botx","candidateN":3,"wipLimit":5,"reclaim":{"timeoutMinutes":120,"heartbeatMinutes":15},"commands":{"test":null,"build":null,"lint":null},"worktreeBaseDir":"../","project":{"number":null,"statusField":"Status"}}' > "$ORCH_CONFIG"
  export CLAIM_BACKOFF_SECS=0   # make tests fast
  export GH_STUB_LOGIN=botx     # gh actor matches config.bot so the identity gate passes
  SCRIPT="$BATS_TEST_DIRNAME/../../plugins/orchestration/scripts/orchestration/claim.sh"
}

@test "no candidates → exit 1" {
  queue_response '[]'                 # issue list
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "issue list API failure → clean exit 1" {
  export GH_FAIL_MATCH='issue list'   # the candidate query itself fails
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "multiple candidates → picks one of the top-N and claims it" {
  # candidateN=3 (setup); all three are within the top-3 by createdAt, so the random pick
  # must yield one of them — exercises the sort_by/slice/RANDOM-pick path (single-candidate
  # tests never do).
  queue_response '[{"number":50,"createdAt":"2026-01-03T00:00:00Z"},{"number":51,"createdAt":"2026-01-02T00:00:00Z"},{"number":52,"createdAt":"2026-01-01T00:00:00Z"}]'
  export CLAIM_TOKEN_OVERRIDE='2026-02-01T00:00:00Z-botx-h-1'
  # the re-read view is returned by call order regardless of which issue was picked; the
  # claim comment matches our pinned token so the visibility check passes either way.
  queue_response '{"labels":[{"name":"status:in-progress"}],"assignees":[{"login":"botx"}],"comments":[{"id":1,"author":{"login":"botx"},"body":"claim: 2026-02-01T00:00:00Z-botx-h-1"}]}'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == "50" || "$output" == "51" || "$output" == "52" ]]
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
  grep -q 'issue edit 7 --remove-assignee botx' "$GH_CALLS"                # released the assignee on loss
}

@test "claim comment write fails → label rolled back to agent-ready, exit 2 (not stuck)" {
  queue_response '[{"number":30,"createdAt":"2026-01-01T00:00:00Z"}]'   # list (read, emitted before the fail)
  export CLAIM_TOKEN_OVERRIDE='2026-02-01T00:00:00Z-botx-h-1'
  export GH_FAIL_MATCH='issue comment'   # only the claim-comment write fails
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
  grep -q 'issue edit 30 --add-label status:in-progress --remove-label status:agent-ready' "$GH_CALLS"  # marked
  grep -q 'issue edit 30 --add-label status:agent-ready --remove-label status:in-progress' "$GH_CALLS"   # rolled back
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

@test "duplicate identical claim comments (retry) dedup to one → claim proceeds" {
  queue_response '[{"number":16,"createdAt":"2026-01-01T00:00:00Z"}]'   # list
  export CLAIM_TOKEN_OVERRIDE='2026-02-01T00:00:00Z-botx-h-1'
  # same token posted twice (e.g. a network retry); unique collapses to 1 distinct token
  # ⇒ no false race ⇒ we proceed as the sole claimant.
  queue_response '{"labels":[{"name":"status:in-progress"}],"assignees":[{"login":"botx"}],"comments":[{"id":1,"author":{"login":"botx"},"body":"claim: 2026-02-01T00:00:00Z-botx-h-1"},{"id":2,"author":{"login":"botx"},"body":"claim: 2026-02-01T00:00:00Z-botx-h-1"}]}'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "16" ]
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

@test "actor mismatch (wrong gh login) → aborts before any write" {
  export GH_STUB_LOGIN=intruder
  queue_response '[{"number":42,"createdAt":"2026-01-01T00:00:00Z"}]'   # would be claimed without the gate
  export CLAIM_TOKEN_OVERRIDE='2026-02-01T00:00:00Z-botx-h-1'
  queue_response '{"labels":[{"name":"status:in-progress"}],"assignees":[{"login":"botx"}],"comments":[{"id":1,"author":{"login":"botx"},"body":"claim: 2026-02-01T00:00:00Z-botx-h-1"}]}'
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"acting as 'intruder'"* ]]   # confirms the identity gate is what aborted
  ! grep -q 'issue edit' "$GH_CALLS"
  ! grep -q 'issue comment' "$GH_CALLS"
}

# Engine-level coverage of the gate's gh-api-failure branch. The gate is the
# first gh call, so the script aborts here before reaching any other gh call —
# representative for all three engine scripts (identical `require_bot_actor || exit 1` wiring).
@test "unresolvable gh identity → aborts before any write" {
  export GH_STUB_LOGIN=botx
  export GH_EXIT=1                                                # `gh api user` exits non-zero
  queue_response '[{"number":42,"createdAt":"2026-01-01T00:00:00Z"}]'   # never consumed — gate aborts first
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot resolve gh identity"* ]]
  ! grep -q 'issue edit' "$GH_CALLS"
}
