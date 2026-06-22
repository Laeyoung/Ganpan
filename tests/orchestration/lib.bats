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
  # ORCH_CONFIG_PATH must echo the explicit $ORCH_CONFIG: detect-test-cmd.sh reads
  # that var directly, so a regression that fails to export it for the explicit
  # path would silently make the script read from an empty path.
  run bash -c 'source "$0"; load_config; echo "$REPO|$BOT|$CANDIDATE_N|$WIP_LIMIT|$RECLAIM_TIMEOUT_MIN|$HEARTBEAT_MIN|$PROJECT_NUMBER|$ORCH_CONFIG_PATH"' "$LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "o/r|botx|3|4|120|15|null|$ORCH_CONFIG" ]
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

@test "resolve_config_path uses ORCH_CONFIG before cwd defaults" {
  work="$BATS_TEST_TMPDIR/proj"
  explicit="$BATS_TEST_TMPDIR/explicit.json"
  mkdir -p "$work/.ganpan" "$work/.claude"
  cp "$ORCH_CONFIG" "$explicit"
  cp "$ORCH_CONFIG" "$work/.ganpan/orchestration.json"
  cp "$ORCH_CONFIG" "$work/.claude/orchestration.json"

  run bash -c 'export ORCH_CONFIG="$1"; cd "$2"; source "$3"; resolve_config_path' _ "$explicit" "$work" "$LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "$explicit" ]
}

@test "resolve_config_path honors an explicit root arg independent of cwd (worktree contract)" {
  # The wt-issue-<n> contract is CFG="$(resolve_config_path "$REPO_ROOT")" run from
  # inside the worktree. cd to a dir with NO config so only the explicit $root arg
  # can resolve it — drop the ${1:-.} default and this returns ./.ganpan instead.
  work="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$work/.ganpan"
  cp "$ORCH_CONFIG" "$work/.ganpan/orchestration.json"
  run bash -c 'unset ORCH_CONFIG; cd "$1"; source "$2"; resolve_config_path "$3"' _ "$BATS_TEST_TMPDIR" "$LIB" "$work"
  [ "$status" -eq 0 ]
  [ "$output" = "$work/.ganpan/orchestration.json" ]
}

@test "resolve_config_path prefers .ganpan over .claude when ORCH_CONFIG unset" {
  work="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$work/.ganpan" "$work/.claude"
  cp "$ORCH_CONFIG" "$work/.ganpan/orchestration.json"
  cp "$ORCH_CONFIG" "$work/.claude/orchestration.json"

  run bash -c 'unset ORCH_CONFIG; cd "$1"; source "$2"; resolve_config_path' _ "$work" "$LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "./.ganpan/orchestration.json" ]
}

@test "load_config exports ORCH_CONFIG_PATH for the selected config" {
  work="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$work/.ganpan"
  cp "$ORCH_CONFIG" "$work/.ganpan/orchestration.json"

  run bash -c 'unset ORCH_CONFIG; cd "$1"; source "$2"; load_config; echo "$ORCH_CONFIG_PATH|$REPO"' _ "$work" "$LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "./.ganpan/orchestration.json|o/r" ]
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
