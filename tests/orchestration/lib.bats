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
    && [ "$(perm_rank write)" -eq 2 ] && [ "$(perm_rank triage)" -eq 1 ] \
    && [ "$(perm_rank read)" -eq 0 ] \
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

@test "is_trusted: invalid threshold fails closed (rejects read collaborator)" {
  # A mistyped permissionThreshold (perm_rank → -1) must NOT fall open to read/pull.
  printf '%s' '{"repo":"o/r","bot":"botx","candidateN":5,"wipLimit":5,"reclaim":{"timeoutMinutes":1,"heartbeatMinutes":1},"commands":{"test":null,"build":null,"lint":null},"worktreeBaseDir":"../","project":{"number":null,"statusField":"Status"},"reviewer":{"permissionThreshold":"wirte","allowlist":[],"followupIssueCapPerPR":3}}' > "$ORCH_CONFIG"
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

@test "bot_marker_pending: open marker with no resolve → yes" {
  printf '%s' '{"comments":[{"author":{"login":"botx"},"body":"decision-requested: head=abc :: q"}]}' > "$BATS_TEST_TMPDIR/v.json"
  run bash -c 'source "$0"; BOT=botx; bot_marker_pending "decision-requested:" "decision-resolved:" < "$1"' "$LIB" "$BATS_TEST_TMPDIR/v.json"
  [ "$status" -eq 0 ]
  [ "$output" = "yes" ]
}

@test "bot_marker_pending: resolve after open → no" {
  printf '%s' '{"comments":[{"author":{"login":"botx"},"body":"decision-requested: head=abc :: q"},{"author":{"login":"botx"},"body":"decision-resolved: done"}]}' > "$BATS_TEST_TMPDIR/v.json"
  run bash -c 'source "$0"; BOT=botx; bot_marker_pending "decision-requested:" "decision-resolved:" < "$1"' "$LIB" "$BATS_TEST_TMPDIR/v.json"
  [ "$output" = "no" ]
}

@test "bot_marker_pending: re-open after resolve → yes (latest marker wins)" {
  printf '%s' '{"comments":[{"author":{"login":"botx"},"body":"decision-resolved: prev cycle"},{"author":{"login":"botx"},"body":"decision-requested: head=def :: q2"}]}' > "$BATS_TEST_TMPDIR/v.json"
  run bash -c 'source "$0"; BOT=botx; bot_marker_pending "decision-requested:" "decision-resolved:" < "$1"' "$LIB" "$BATS_TEST_TMPDIR/v.json"
  [ "$output" = "yes" ]
}

@test "bot_marker_pending: non-bot marker ignored → no" {
  printf '%s' '{"comments":[{"author":{"login":"attacker"},"body":"decision-requested: head=abc :: q"}]}' > "$BATS_TEST_TMPDIR/v.json"
  run bash -c 'source "$0"; BOT=botx; bot_marker_pending "decision-requested:" "decision-resolved:" < "$1"' "$LIB" "$BATS_TEST_TMPDIR/v.json"
  [ "$output" = "no" ]
}

@test "bot_marker_pending: no markers → no" {
  printf '%s' '{"comments":[]}' > "$BATS_TEST_TMPDIR/v.json"
  run bash -c 'source "$0"; BOT=botx; bot_marker_pending "merge-requested:" "merge-resolved:" < "$1"' "$LIB" "$BATS_TEST_TMPDIR/v.json"
  [ "$output" = "no" ]
}

@test "require_bot_actor passes when gh actor == config.bot" {
  export GH_STUB_LOGIN=botx
  run bash -c 'source "$0"; load_config; require_bot_actor' "$LIB"
  [ "$status" -eq 0 ]
}

@test "require_bot_actor fails (with message) when actor != bot" {
  export GH_STUB_LOGIN=intruder
  run bash -c 'source "$0"; load_config; require_bot_actor 2>&1' "$LIB"
  [ "$status" -ne 0 ]
  [[ "$output" == *"acting as 'intruder'"* ]]
}

@test "require_bot_actor fails when config.bot is empty" {
  printf '%s' '{"repo":"o/r","bot":"","candidateN":3,"wipLimit":4,"reclaim":{"timeoutMinutes":120,"heartbeatMinutes":15},"commands":{"test":null,"build":null,"lint":null},"worktreeBaseDir":"../","project":{"number":null,"statusField":"Status"}}' > "$ORCH_CONFIG"
  export GH_STUB_LOGIN=botx
  run bash -c 'source "$0"; load_config; require_bot_actor 2>&1' "$LIB"
  [ "$status" -ne 0 ]
  [[ "$output" == *"config.bot is empty"* ]]
}

@test "require_bot_actor fails when gh returns an empty login" {
  export GH_STUB_LOGIN=
  run bash -c 'source "$0"; load_config; require_bot_actor 2>&1' "$LIB"
  [ "$status" -ne 0 ]
  [[ "$output" == *"empty login"* ]]
}

@test "require_bot_actor fails when gh api user errors (unresolvable identity)" {
  export GH_STUB_LOGIN=botx
  export GH_EXIT=1
  run bash -c 'source "$0"; load_config; require_bot_actor 2>&1' "$LIB"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot resolve gh identity"* ]]
}

@test "ORCH_SKIP_ACTOR_CHECK=1 short-circuits without calling gh" {
  export ORCH_SKIP_ACTOR_CHECK=1
  export GH_STUB_LOGIN=intruder
  run bash -c 'source "$0"; load_config; require_bot_actor' "$LIB"
  [ "$status" -eq 0 ]
  ! grep -q 'api user' "$GH_CALLS"
}
