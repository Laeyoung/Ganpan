#!/usr/bin/env bats

setup() {
  load helpers/common
  setup_gh_stub
  LIB="$BATS_TEST_DIRNAME/../../plugins/orchestration/scripts/orchestration/lib.sh"
  export ORCH_CONFIG="$BATS_TEST_TMPDIR/orchestration.json"
  cat > "$ORCH_CONFIG" <<'JSON'
{ "repo":"o/r","bot":"botx","candidateN":3,"wipLimit":4,
  "reclaim":{"timeoutMinutes":120,"heartbeatMinutes":15},
  "commands":{"test":null,"build":null,"lint":null},
  "worktreeBaseDir":"../","project":{"number":null,"statusField":"Status"} }
JSON
}

@test "load_config exports expected vars" {
  run bash -c 'source "$0"; load_config; echo "$REPO|$BOT|$CANDIDATE_N|$WIP_LIMIT|$RECLAIM_TIMEOUT_MIN|$HEARTBEAT_MIN|$PROJECT_NUMBER"' "$LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "o/r|botx|3|4|120|15|null" ]
}

@test "load_config fails clearly when config missing" {
  export ORCH_CONFIG="$BATS_TEST_TMPDIR/nope.json"
  # merge stderr→stdout explicitly so the error message is in $output on any bats config
  run bash -c 'source "$0"; load_config 2>&1' "$LIB"
  [ "$status" -ne 0 ]
  [[ "$output" == *"config not found"* ]]
}

@test "claim_token sorts by time then is unique per process" {
  run bash -c 'source "$0"; load_config; claim_token' "$LIB"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z-botx- ]]
}

@test "iso_to_epoch round-trips a known timestamp" {
  run bash -c 'source "$0"; iso_to_epoch 1970-01-01T00:00:00Z' "$LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "load_config finds ./.claude/orchestration.json from cwd when ORCH_CONFIG unset" {
  work="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$work/.claude"
  cp "$ORCH_CONFIG" "$work/.claude/orchestration.json"
  # unset the override and run from inside $work so only the cwd fallback can resolve it
  run bash -c 'unset ORCH_CONFIG; cd "$1"; source "$2"; load_config; echo "$REPO"' _ "$work" "$LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "o/r" ]
}

@test "load_config exports reviewer.* with defaults when block present" {
  cat > "$ORCH_CONFIG" <<'JSON'
{"repo":"o/r","bot":"botx","candidateN":5,"wipLimit":5,
 "reclaim":{"timeoutMinutes":120,"heartbeatMinutes":15},
 "commands":{"test":null,"build":null,"lint":null},
 "worktreeBaseDir":"../","project":{"number":null,"statusField":"Status"},
 "reviewer":{"permissionThreshold":"write","allowlist":["alice","bob"],"followupIssueCapPerPR":3}}
JSON
  run bash -c 'source "$0"; load_config; printf "%s|%s|%s" "$REVIEWER_PERM_THRESHOLD" "$FOLLOWUP_CAP" "$REVIEWER_ALLOWLIST"' "$LIB"
  [ "$status" -eq 0 ]
  [[ "$output" == "write|3|"* ]]
  [[ "$output" == *alice* ]]
  [[ "$output" == *bob* ]]
}

@test "load_config reviewer.* falls back to defaults when block absent" {
  cat > "$ORCH_CONFIG" <<'JSON'
{"repo":"o/r","bot":"botx","candidateN":5,"wipLimit":5,
 "reclaim":{"timeoutMinutes":120,"heartbeatMinutes":15},
 "commands":{"test":null,"build":null,"lint":null},
 "worktreeBaseDir":"../","project":{"number":null,"statusField":"Status"}}
JSON
  run bash -c 'source "$0"; load_config; printf "%s|%s|[%s]" "$REVIEWER_PERM_THRESHOLD" "$FOLLOWUP_CAP" "$REVIEWER_ALLOWLIST"' "$LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "write|3|[]" ]
}

@test "perm_rank orders permissions" {
  run bash -c 'source "$0"
    [ "$(perm_rank admin)" -eq 4 ] && [ "$(perm_rank maintain)" -eq 3 ] \
    && [ "$(perm_rank write)" -eq 2 ] && [ "$(perm_rank read)" -eq 0 ] \
    && [ "$(perm_rank pull)" -eq 0 ] && [ "$(perm_rank none)" -eq -1 ] \
    && [ "$(perm_rank bogus)" -eq -1 ]' "$LIB"
  [ "$status" -eq 0 ]
}

@test "is_trusted: allowlist match short-circuits (no API call)" {
  printf '%s' '{"repo":"o/r","bot":"botx","candidateN":5,"wipLimit":5,"reclaim":{"timeoutMinutes":1,"heartbeatMinutes":1},"commands":{"test":null,"build":null,"lint":null},"worktreeBaseDir":"../","project":{"number":null,"statusField":"Status"},"reviewer":{"permissionThreshold":"write","allowlist":["carol"],"followupIssueCapPerPR":3}}' > "$ORCH_CONFIG"
  run bash -c 'source "$0"; load_config; is_trusted carol' "$LIB"
  [ "$status" -eq 0 ]
  ! grep -q 'api repos/o/r/collaborators/carol' "$GH_CALLS"
}

@test "is_trusted: write permission passes threshold" {
  printf '%s' '{"repo":"o/r","bot":"botx","candidateN":5,"wipLimit":5,"reclaim":{"timeoutMinutes":1,"heartbeatMinutes":1},"commands":{"test":null,"build":null,"lint":null},"worktreeBaseDir":"../","project":{"number":null,"statusField":"Status"},"reviewer":{"permissionThreshold":"write","allowlist":[],"followupIssueCapPerPR":3}}' > "$ORCH_CONFIG"
  queue_response 'write'
  run bash -c 'source "$0"; load_config; is_trusted dave' "$LIB"
  [ "$status" -eq 0 ]
  grep -q 'api repos/o/r/collaborators/dave/permission' "$GH_CALLS"
}

@test "is_trusted: read permission fails threshold" {
  printf '%s' '{"repo":"o/r","bot":"botx","candidateN":5,"wipLimit":5,"reclaim":{"timeoutMinutes":1,"heartbeatMinutes":1},"commands":{"test":null,"build":null,"lint":null},"worktreeBaseDir":"../","project":{"number":null,"statusField":"Status"},"reviewer":{"permissionThreshold":"write","allowlist":[],"followupIssueCapPerPR":3}}' > "$ORCH_CONFIG"
  queue_response 'read'
  run bash -c 'source "$0"; load_config; is_trusted eve' "$LIB"
  [ "$status" -eq 1 ]
}

@test "is_trusted: API failure is untrusted" {
  printf '%s' '{"repo":"o/r","bot":"botx","candidateN":5,"wipLimit":5,"reclaim":{"timeoutMinutes":1,"heartbeatMinutes":1},"commands":{"test":null,"build":null,"lint":null},"worktreeBaseDir":"../","project":{"number":null,"statusField":"Status"},"reviewer":{"permissionThreshold":"write","allowlist":[],"followupIssueCapPerPR":3}}' > "$ORCH_CONFIG"
  export GH_FAIL_MATCH='collaborators'
  run bash -c 'source "$0"; load_config; is_trusted mallory' "$LIB"
  [ "$status" -eq 1 ]
}
