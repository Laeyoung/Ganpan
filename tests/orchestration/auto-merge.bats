#!/usr/bin/env bats
bats_require_minimum_version 1.5.0  # for `run --separate-stderr`

# auto-merge.sh — opt-in reviewer auto-merge. Performs `gh pr merge` ONLY when
# reviewer.autoMerge is true, the PR's base branch is NOT protected (confirmed by a
# genuine 404 — any inconclusive probe fails CLOSED), and the PR is OPEN + MERGEABLE +
# mergeStateStatus CLEAN (conservative: any failing/pending check or conflict blocks).
# Otherwise it emits a status token and merges nothing.

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

# write a config with autoMerge:true and reviewer.autoMergePrivatePlanWorkaround set to $1
write_config_workaround() {
  printf '{"repo":"o/r","bot":"botx","candidateN":3,"wipLimit":5,"reclaim":{"timeoutMinutes":120,"heartbeatMinutes":15},"commands":{"test":null,"build":null,"lint":null},"worktreeBaseDir":"../","project":{"number":null,"statusField":"Status"},"reviewer":{"permissionThreshold":"write","allowlist":[],"followupIssueCapPerPR":3,"autoMerge":true,"autoMergePrivatePlanWorkaround":%s}}' "$1" > "$ORCH_CONFIG"
}

# GitHub's exact Free-plan private-repo protection-API 403 body (the string auto-merge.sh keys on)
PRIVATE_PLAN_403='gh: Upgrade to GitHub Pro or make this repository public to enable this feature. (HTTP 403)'

@test "autoMerge off → 'disabled', never merges" {
  write_config false
  run bash "$SCRIPT" 7
  [ "$status" -eq 0 ]
  [ "$output" = "disabled" ]
  ! grep -q 'pr merge' "$GH_CALLS"
}

@test "autoMerge on but base branch protected → 'protected', never merges" {
  write_config true
  queue_response '{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","baseRefName":"main"}'   # gh pr view
  queue_response '{"required_status_checks":{}}'   # the protection GET body (200 ⇒ protected)
  run bash "$SCRIPT" 7
  [ "$status" -eq 0 ]
  [ "$output" = "protected" ]
  ! grep -q 'pr merge' "$GH_CALLS"
  grep -q 'api repos/o/r/branches/main/protection' "$GH_CALLS"
}

@test "autoMerge on, unprotected (genuine 404), PR clean → merges, prints 'merged'" {
  write_config true
  export GH_API_404_MATCH='branches/main/protection'   # genuine 404 ⇒ not protected
  queue_response '{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","baseRefName":"main"}'   # gh pr view
  run bash "$SCRIPT" 7
  [ "$status" -eq 0 ]
  [ "$output" = "merged" ]
  grep -q 'pr merge 7' "$GH_CALLS"
}

@test "autoMerge on, protection probe fails NON-404 (403/5xx/transient) → fails closed 'protect-check-failed', never merges" {
  write_config true
  queue_response '{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","baseRefName":"main"}'   # gh pr view
  export GH_FAIL_MATCH='branches/main/protection'   # generic non-zero exit, NO 404 message ⇒ inconclusive
  run --separate-stderr bash "$SCRIPT" 7
  [ "$status" -eq 2 ]
  [ "$output" = "protect-check-failed" ]
  [[ "$stderr" == *"inconclusive"* ]]   # the failure is surfaced, not silently treated as unprotected
  ! grep -q 'pr merge' "$GH_CALLS"
}

@test "autoMerge on, PR targets a non-main base → protection probed on the PR's actual base" {
  write_config true
  queue_response '{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","baseRefName":"release"}'   # gh pr view: base=release
  queue_response '{"required_status_checks":{}}'   # protection on release ⇒ protected
  run bash "$SCRIPT" 7
  [ "$status" -eq 0 ]
  [ "$output" = "protected" ]
  grep -q 'api repos/o/r/branches/release/protection' "$GH_CALLS"
  ! grep -q 'pr merge' "$GH_CALLS"
}

@test "autoMerge on, unprotected, merge call fails (e.g. method disallowed) → 'merge-failed'" {
  write_config true
  export GH_API_404_MATCH='branches/main/protection'
  queue_response '{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","baseRefName":"main"}'   # gh pr view
  export GH_FAIL_MATCH='pr merge'   # the merge itself fails
  run --separate-stderr bash "$SCRIPT" 7
  [ "$status" -eq 2 ]
  [ "$output" = "merge-failed" ]
  [[ "$stderr" == *"gh pr merge failed"* ]]   # the reason is surfaced, not swallowed
}

@test "autoMerge on, unprotected, checks not green (UNSTABLE) → 'not-ready', never merges" {
  write_config true
  export GH_API_404_MATCH='branches/main/protection'
  queue_response '{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"UNSTABLE","baseRefName":"main"}'
  run bash "$SCRIPT" 7
  [ "$status" -eq 0 ]
  [[ "$output" == not-ready* ]]
  ! grep -q 'pr merge' "$GH_CALLS"
}

@test "autoMerge on, unprotected, conflicts (CONFLICTING) → 'not-ready', never merges" {
  write_config true
  export GH_API_404_MATCH='branches/main/protection'
  queue_response '{"state":"OPEN","mergeable":"CONFLICTING","mergeStateStatus":"DIRTY","baseRefName":"main"}'
  run bash "$SCRIPT" 7
  [ "$status" -eq 0 ]
  [[ "$output" == not-ready* ]]
  ! grep -q 'pr merge' "$GH_CALLS"
}

@test "actor mismatch → aborts before any merge" {
  write_config true
  export GH_STUB_LOGIN=intruder
  run bash "$SCRIPT" 7
  [ "$status" -ne 0 ]
  ! grep -q 'pr merge' "$GH_CALLS"
}

@test "captured stdout stays exactly 'merged' even when gh pr merge leaks a URL" {
  # Regression guard for the ISSUE=$(claim.sh)-class bug applied to AM=$(auto-merge.sh):
  # real `gh pr merge` prints a confirmation line on success. With GH_EMIT_WRITE_URL the
  # stub mimics that. auto-merge.sh must keep that line off its OWN stdout (it captures the
  # merge into merge_out=$(…)), so the only thing on stdout is the `merged` token. This
  # fails if `gh pr merge` is ever invoked so its stdout reaches the script's stdout — e.g.
  # called bare (`gh pr merge … && echo merged`) instead of captured into a local.
  export GH_EMIT_WRITE_URL=1
  write_config true
  export GH_API_404_MATCH='branches/main/protection'   # genuine 404 ⇒ not protected
  queue_response '{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","baseRefName":"main"}'   # gh pr view
  run bash "$SCRIPT" 7
  [ "$status" -eq 0 ]
  [ "$output" = "merged" ]               # exactly the token — no leaked URL line (subsumes a STUB-URL check)
  grep -q 'pr merge 7' "$GH_CALLS"       # the merge actually ran (so the assertion isn't vacuous)
}

# --- issue #72: Free-plan private-repo protection-API 403 workaround (opt-in) ---

@test "autoMerge on, workaround OFF (default), Free-plan private 403 → fails closed 'protect-check-failed', never merges" {
  # Regression guard: the private-plan 403 is inconclusive like any other non-404 and MUST
  # stay fail-closed unless the operator explicitly opts in. Default behavior unchanged.
  write_config true   # autoMergePrivatePlanWorkaround absent ⇒ defaults false
  queue_response '{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","baseRefName":"main"}'
  export GH_API_ERR_MATCH='branches/main/protection'
  export GH_API_ERR_BODY="$PRIVATE_PLAN_403"
  run --separate-stderr bash "$SCRIPT" 7
  [ "$status" -eq 2 ]
  [ "$output" = "protect-check-failed" ]
  [[ "$stderr" == *"inconclusive"* ]]
  ! grep -q 'pr merge' "$GH_CALLS"
}

@test "autoMerge on, workaround ON, Free-plan private 403, PR clean → treats base as unprotected and merges" {
  write_config_workaround true
  queue_response '{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","baseRefName":"main"}'
  export GH_API_ERR_MATCH='branches/main/protection'
  export GH_API_ERR_BODY="$PRIVATE_PLAN_403"
  run --separate-stderr bash "$SCRIPT" 7
  [ "$status" -eq 0 ]
  [ "$output" = "merged" ]
  [[ "$stderr" == *"autoMergePrivatePlanWorkaround=true"* ]]   # the bypass is logged, not silent
  grep -q 'pr merge 7' "$GH_CALLS"
}

@test "autoMerge on, workaround ON, but a DIFFERENT non-404 error (5xx/other 403) → still fails closed, never merges" {
  # The workaround keys on the EXACT Free-plan message only. Any other inconclusive body
  # (here a 500) must remain fail-closed even with the flag on — real gates never bypassed.
  write_config_workaround true
  queue_response '{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","baseRefName":"main"}'
  export GH_API_ERR_MATCH='branches/main/protection'
  export GH_API_ERR_BODY='gh: Server Error (HTTP 500)'
  run --separate-stderr bash "$SCRIPT" 7
  [ "$status" -eq 2 ]
  [ "$output" = "protect-check-failed" ]
  ! grep -q 'pr merge' "$GH_CALLS"
}

@test "autoMerge on, workaround ON, but base IS protected (200) → 'protected', never merges" {
  # Even with the flag on, a repo that supports protection returns 200 and is honored:
  # the workaround only affects the error branch, so a real gate is never bypassed.
  write_config_workaround true
  queue_response '{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","baseRefName":"main"}'
  queue_response '{"required_status_checks":{}}'   # 200 ⇒ protected
  run bash "$SCRIPT" 7
  [ "$status" -eq 0 ]
  [ "$output" = "protected" ]
  ! grep -q 'pr merge' "$GH_CALLS"
}
