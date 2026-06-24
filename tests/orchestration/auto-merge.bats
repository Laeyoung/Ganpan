#!/usr/bin/env bats

# auto-merge.sh — opt-in reviewer auto-merge. Performs `gh pr merge` ONLY when
# reviewer.autoMerge is true, the base branch is NOT protected, and the PR is
# OPEN + MERGEABLE + mergeStateStatus CLEAN (conservative: any failing/pending
# check or conflict blocks). Otherwise it emits a status token and merges nothing.

setup() {
  load helpers/common
  setup_gh_stub
  export ORCH_CONFIG="$BATS_TEST_TMPDIR/orchestration.json"
  export GH_STUB_LOGIN=botx     # gh actor == config.bot so the identity gate passes
  SCRIPT="$BATS_TEST_DIRNAME/../../plugins/orchestration/scripts/orchestration/auto-merge.sh"
}

# write a config with reviewer.autoMerge set to $1 (true|false)
write_config() {
  printf '{"repo":"o/r","bot":"botx","candidateN":3,"wipLimit":5,"reclaim":{"timeoutMinutes":120,"heartbeatMinutes":15},"commands":{"test":null,"build":null,"lint":null},"worktreeBaseDir":"../","project":{"number":null,"statusField":"Status"},"reviewer":{"permissionThreshold":"write","allowlist":[],"followupIssueCapPerPR":3,"autoMerge":%s}}' "$1" > "$ORCH_CONFIG"
}

@test "autoMerge off → 'disabled', never merges" {
  write_config false
  run bash "$SCRIPT" 7
  [ "$status" -eq 0 ]
  [ "$output" = "disabled" ]
  ! grep -q 'pr merge' "$GH_CALLS"
}

@test "autoMerge on but base branch protected → 'protected', never merges" {
  write_config true
  # `gh api .../protection` succeeds (exit 0) ⇒ protection exists ⇒ must NOT merge
  queue_response '{"required_status_checks":{}}'   # the protection GET body
  run bash "$SCRIPT" 7
  [ "$status" -eq 0 ]
  [ "$output" = "protected" ]
  ! grep -q 'pr merge' "$GH_CALLS"
  grep -q 'api repos/o/r/branches/main/protection' "$GH_CALLS"
}

@test "autoMerge on, unprotected, PR clean → merges, prints 'merged'" {
  write_config true
  export GH_FAIL_MATCH='branches/main/protection'   # 404 ⇒ not protected (exits before consuming a slot)
  queue_response '{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}'   # gh pr view
  run bash "$SCRIPT" 7
  [ "$status" -eq 0 ]
  [ "$output" = "merged" ]
  grep -q 'pr merge 7' "$GH_CALLS"
}

@test "autoMerge on, unprotected, checks not green (UNSTABLE) → 'not-ready', never merges" {
  write_config true
  export GH_FAIL_MATCH='branches/main/protection'
  queue_response '{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"UNSTABLE"}'
  run bash "$SCRIPT" 7
  [ "$status" -eq 0 ]
  [[ "$output" == not-ready* ]]
  ! grep -q 'pr merge' "$GH_CALLS"
}

@test "autoMerge on, unprotected, conflicts (CONFLICTING) → 'not-ready', never merges" {
  write_config true
  export GH_FAIL_MATCH='branches/main/protection'
  queue_response '{"state":"OPEN","mergeable":"CONFLICTING","mergeStateStatus":"DIRTY"}'
  run bash "$SCRIPT" 7
  [ "$status" -eq 0 ]
  [[ "$output" == not-ready* ]]
  ! grep -q 'pr merge' "$GH_CALLS"
}

@test "actor mismatch → aborts before any merge" {
  write_config true
  export GH_STUB_LOGIN=intruder
  export GH_FAIL_MATCH='branches/main/protection'
  queue_response '{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}'
  run bash "$SCRIPT" 7
  [ "$status" -ne 0 ]
  ! grep -q 'pr merge' "$GH_CALLS"
}
