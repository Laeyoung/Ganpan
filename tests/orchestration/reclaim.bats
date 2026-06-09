#!/usr/bin/env bats

setup() {
  load helpers/common
  setup_gh_stub
  export ORCH_CONFIG="$BATS_TEST_TMPDIR/orchestration.json"
  printf '{"repo":"o/r","bot":"botx","candidateN":1,"wipLimit":1,"reclaim":{"timeoutMinutes":120,"heartbeatMinutes":15},"commands":{"test":null,"build":null,"lint":null},"worktreeBaseDir":"../","project":{"number":null,"statusField":"Status"}}' > "$ORCH_CONFIG"
  SCRIPT="$BATS_TEST_DIRNAME/../../scripts/orchestration/reclaim.sh"
}

@test "fresh heartbeat → not reclaimed" {
  queue_response '[{"number":3}]'                                   # in-progress list
  recent=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  queue_response "{\"comments\":[{\"author\":{\"login\":\"botx\"},\"body\":\"claim: ${recent}-botx-h-1\"}]}"  # view #3
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  ! grep -q 'issue edit 3 --add-label status:agent-ready' "$GH_CALLS"
}

@test "unresolved rework → skipped regardless of age" {
  queue_response '[{"number":4}]'
  queue_response '{"comments":[{"author":{"login":"botx"},"body":"claim: 2000-01-01T00:00:00Z-botx-h-1"},{"author":{"login":"botx"},"body":"rework-requested: fix tests"}]}'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  ! grep -q 'issue edit 4' "$GH_CALLS"
}

@test "timed-out with open PR → blocked (not agent-ready)" {
  queue_response '[{"number":5}]'
  queue_response '{"comments":[{"author":{"login":"botx"},"body":"claim: 2000-01-01T00:00:00Z-botx-h-1"}]}'  # view comments
  queue_response '[{"number":99,"state":"OPEN"}]'                   # pr list --head issue-5
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q 'issue edit 5 --add-label status:blocked' "$GH_CALLS"
  ! grep -q 'issue edit 5 --add-label status:agent-ready' "$GH_CALLS"
  grep -q 'issue comment 5 --body reclaimed: orphan lock, PR #99' "$GH_CALLS"  # human-notification posted
}

@test "timed-out with no PR → reset to agent-ready, assignee removed" {
  queue_response '[{"number":6}]'
  queue_response '{"comments":[{"author":{"login":"botx"},"body":"claim: 2000-01-01T00:00:00Z-botx-h-1"}]}'
  queue_response '[]'                                              # pr list empty
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q 'issue edit 6 --add-label status:agent-ready --remove-label status:in-progress' "$GH_CALLS"
  grep -q 'issue edit 6 --remove-assignee botx' "$GH_CALLS"
}

@test "unparseable claim timestamp → skipped (no spurious reclaim)" {
  queue_response '[{"number":10}]'
  queue_response '{"comments":[{"author":{"login":"botx"},"body":"claim: BADDATE-botx-h-1"}]}'  # iso_to_epoch → 0
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  ! grep -q 'issue edit 10' "$GH_CALLS"
}

@test "no claim token → skipped" {
  queue_response '[{"number":11}]'
  queue_response '{"comments":[{"author":{"login":"botx"},"body":"PR: https://x"}]}'  # no claim: marker
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  ! grep -q 'issue edit 11' "$GH_CALLS"
}

@test "newest bot claim token decides liveness (stale leftover comment ignored)" {
  queue_response '[{"number":20}]'
  recent=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  # a stale claim left by a crashed loser PLUS a fresh heartbeat on the live claim;
  # max() must pick the fresh token → issue is alive → must NOT be reclaimed.
  queue_response "{\"comments\":[{\"author\":{\"login\":\"botx\"},\"body\":\"claim: 2000-01-01T00:00:00Z-botx-h-1\"},{\"author\":{\"login\":\"botx\"},\"body\":\"claim: ${recent}-botx-h-2\"}]}"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  ! grep -q 'issue edit 20' "$GH_CALLS"
}

@test "claim/rework markers from a non-bot author are ignored" {
  queue_response '[{"number":12}]'
  # an outsider posts a fresh-looking claim AND a rework-requested; neither is the bot.
  # The only bot-authored claim is ancient → issue is genuinely timed out → must reclaim.
  recent=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  queue_response "{\"comments\":[{\"author\":{\"login\":\"attacker\"},\"body\":\"claim: ${recent}-attacker-h-1\"},{\"author\":{\"login\":\"attacker\"},\"body\":\"rework-requested: stall\"},{\"author\":{\"login\":\"botx\"},\"body\":\"claim: 2000-01-01T00:00:00Z-botx-h-1\"}]}"
  queue_response '[]'                                              # pr list empty
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q 'issue edit 12 --add-label status:agent-ready --remove-label status:in-progress' "$GH_CALLS"
}
