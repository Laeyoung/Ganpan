#!/usr/bin/env bats

# visibility-check.sh — read-only setup-time advisory for the Free-plan private-repo
# auto-merge trap (issue #80; the trap itself is #72).

setup() {
  load helpers/common
  setup_gh_stub
  SCRIPT="$BATS_TEST_DIRNAME/../../plugins/orchestration/scripts/orchestration/visibility-check.sh"
  export ORCH_CONFIG="$BATS_TEST_TMPDIR/orchestration.json"
  write_config false false
}

# write_config <autoMerge> <autoMergePrivatePlanWorkaround>
write_config() {
  printf '{"repo":"o/r","bot":"b","candidateN":1,"wipLimit":1,"reclaim":{"timeoutMinutes":1,"heartbeatMinutes":1},"commands":{"test":null,"build":null,"lint":null},"worktreeBaseDir":"../","project":{"number":null,"statusField":"Status"},"reviewer":{"autoMerge":%s,"autoMergePrivatePlanWorkaround":%s}}' "$1" "$2" > "$ORCH_CONFIG"
}

@test "public repo → OK exit 0, no advisory" {
  queue_response 'false'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"visibility-check: OK"* ]]
  [[ "$output" == *"is public"* ]]
  [[ "$output" != *"ADVISORY"* ]]
}

@test "private repo → ADVISORY exit 1 naming the 403 and all three fixes" {
  queue_response 'true'
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"visibility-check: ADVISORY"* ]]
  [[ "$output" == *"is PRIVATE"* ]]
  [[ "$output" == *"Upgrade to GitHub Pro or make this repository public"* ]]
  [[ "$output" == *"Make the repo public"* ]]
  [[ "$output" == *"upgrade to GitHub Pro/Team"* ]]
  [[ "$output" == *"autoMergePrivatePlanWorkaround"* ]]
}

@test "private repo with autoMerge off still advises, flagged as a heads-up" {
  write_config false false
  queue_response 'true'
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ADVISORY"* ]]
  [[ "$output" == *"reviewer.autoMerge is currently false"* ]]
}

@test "private repo with autoMerge on omits the not-stuck-today note" {
  write_config true false
  queue_response 'true'
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ADVISORY"* ]]
  [[ "$output" != *"currently false"* ]]
}

@test "private repo with the workaround already opted in → OK exit 0" {
  write_config true true
  queue_response 'true'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"visibility-check: OK"* ]]
  [[ "$output" == *"already true"* ]]
}

@test "visibility lookup failure → FAIL exit 1, explicitly inconclusive" {
  export GH_API_ERR_MATCH='repos/o/r'
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"visibility-check: FAIL"* ]]
  [[ "$output" == *"Inconclusive"* ]]
}

@test "unexpected .private value → FAIL exit 1 rather than a wrong advisory" {
  queue_response 'null'
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"visibility-check: FAIL"* ]]
  [[ "$output" == *"unexpected visibility value"* ]]
}

@test "missing config → FAIL exit 1 pointing at orch-setup" {
  export ORCH_CONFIG="$BATS_TEST_TMPDIR/nope.json"
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"visibility-check: FAIL"* ]]
  [[ "$output" == *"orch-setup"* ]]
}

@test "read-only: issues no write and no actor probe" {
  queue_response 'true'
  run bash "$SCRIPT"
  # only the single GET; never a mutating gh call
  ! grep -qE 'issue (edit|comment|create)|pr (create|merge)|label (create|delete)' "$GH_CALLS"
  ! grep -qE -- '(-X|--method)[= ](POST|PUT|PATCH|DELETE)' "$GH_CALLS"
  # no require_bot_actor: this may run at setup time before the bot PAT exists
  ! grep -q '^api user' "$GH_CALLS"
}
