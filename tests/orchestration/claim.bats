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

@test "stdout carries ONLY the issue number even when gh writes leak URLs on success" {
  # Regression for the ISSUE=$(claim.sh) corruption: real `gh issue edit/comment` print the
  # resource URL to stdout on success. With GH_EMIT_WRITE_URL the stub mimics that, so this
  # asserts claim.sh keeps every mutating write off stdout and emits only `echo "$issue"`.
  export GH_EMIT_WRITE_URL=1
  queue_response '[{"number":42,"createdAt":"2026-01-01T00:00:00Z"}]'   # list
  export CLAIM_TOKEN_OVERRIDE='2026-02-01T00:00:00Z-botx-h-1'
  queue_response '{"labels":[{"name":"status:in-progress"}],"assignees":[{"login":"botx"}],"comments":[{"id":1,"author":{"login":"botx"},"body":"claim: 2026-02-01T00:00:00Z-botx-h-1"}]}'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "42" ]                  # exactly the number — no https://… lines
  [[ "$output" != *"STUB-URL"* ]]       # the leaked write URL never reached stdout
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

@test "claim comment never visible after all retries → exit 3 (unconfirmed), no success echo, no label rollback" {
  # The comment write itself returned success (we passed the line-33 write without GH_FAIL_MATCH),
  # so the token exists server-side and reclaim.sh will recover the in-progress issue after timeout.
  # This is distinct from a clean lost race (exit 2): the issue is left status:in-progress, NOT
  # rolled back to agent-ready, so the caller must not treat it as available.
  queue_response '[{"number":13,"createdAt":"2026-01-01T00:00:00Z"}]'   # list
  export CLAIM_RETRIES=2 CLAIM_TOKEN_OVERRIDE='2026-02-01T00:00:00Z-botx-h-1'
  queue_response '{"labels":[{"name":"status:in-progress"}],"assignees":[{"login":"botx"}],"comments":[]}'  # re-read 1: empty
  queue_response '{"labels":[{"name":"status:in-progress"}],"assignees":[{"login":"botx"}],"comments":[]}'  # re-read 2: still empty
  run bash "$SCRIPT"
  [ "$status" -eq 3 ]
  [ "$output" != "13" ]
  # left in-progress for reclaim — NOT rolled back to agent-ready
  ! grep -q 'issue edit 13 --add-label status:agent-ready --remove-label status:in-progress' "$GH_CALLS"
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

@test "bot not among assignees but re-add succeeds → claim proceeds (exit 0)" {
  # The initial add-assignee (line 32) is best-effort and may transiently fail, leaving the
  # re-read without the bot assignee. Rather than strand the (otherwise confirmed) claim, we
  # re-add the assignee once; success ⇒ proceed.
  queue_response '[{"number":14,"createdAt":"2026-01-01T00:00:00Z"}]'   # list
  export CLAIM_TOKEN_OVERRIDE='2026-02-01T00:00:00Z-botx-h-1'
  # claim comment visible (visibility loop passes) but assignees does NOT include botx
  queue_response '{"labels":[{"name":"status:in-progress"}],"assignees":[],"comments":[{"id":1,"author":{"login":"botx"},"body":"claim: 2026-02-01T00:00:00Z-botx-h-1"}]}'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "14" ]
  # re-add attempted (a second --add-assignee beyond the initial line-32 one)
  [ "$(grep -c 'issue edit 14 --add-assignee botx' "$GH_CALLS")" -ge 2 ]
}

@test "bot not among assignees and re-add fails → clean rollback to agent-ready (exit 2)" {
  # If the assignee can never be added, the claim cannot be confirmed by the assignee gate.
  # Rather than strand the issue in-progress, roll it back cleanly: delete our (visible) claim
  # comment and reset the label to agent-ready, so the next claimer finds it clean.
  queue_response '[{"number":14,"createdAt":"2026-01-01T00:00:00Z"}]'   # list
  export CLAIM_TOKEN_OVERRIDE='2026-02-01T00:00:00Z-botx-h-1'
  export GH_FAIL_MATCH='add-assignee'   # both the initial add (line 32) and the re-add fail
  queue_response '{"labels":[{"name":"status:in-progress"}],"assignees":[],"comments":[{"id":1,"author":{"login":"botx"},"body":"claim: 2026-02-01T00:00:00Z-botx-h-1"}]}'
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
  grep -q 'api --method DELETE /repos/o/r/issues/comments/1' "$GH_CALLS"                       # deleted OUR claim comment
  grep -q 'issue edit 14 --add-label status:agent-ready --remove-label status:in-progress' "$GH_CALLS"  # rolled back label
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
