#!/usr/bin/env bats

bats_require_minimum_version 1.5.0  # for `run --separate-stderr` in the last test

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../plugins/orchestration/scripts/orchestration/detect-test-cmd.sh"
  WORK="$BATS_TEST_TMPDIR/proj"; mkdir -p "$WORK"
  export ORCH_CONFIG="$WORK/.claude/orchestration.json"; mkdir -p "$WORK/.claude"
}

cfg() { printf '%s' "$1" > "$ORCH_CONFIG"; }

@test "config override wins" {
  cfg '{"repo":"o/r","bot":"b","candidateN":1,"wipLimit":1,"reclaim":{"timeoutMinutes":1,"heartbeatMinutes":1},"commands":{"test":"make check","build":null,"lint":null},"worktreeBaseDir":"../","project":{"number":null,"statusField":"S"}}'
  run bash -c "cd '$WORK' && '$SCRIPT' test"
  [ "$output" = "make check" ]
}

@test "auto-detect package.json test script" {
  cfg '{"repo":"o/r","bot":"b","candidateN":1,"wipLimit":1,"reclaim":{"timeoutMinutes":1,"heartbeatMinutes":1},"commands":{"test":null,"build":null,"lint":null},"worktreeBaseDir":"../","project":{"number":null,"statusField":"S"}}'
  printf '{"scripts":{"test":"jest"}}' > "$WORK/package.json"
  run bash -c "cd '$WORK' && '$SCRIPT' test"
  [ "$output" = "npm test" ]
}

@test "auto-detect Makefile target" {
  cfg '{"repo":"o/r","bot":"b","candidateN":1,"wipLimit":1,"reclaim":{"timeoutMinutes":1,"heartbeatMinutes":1},"commands":{"test":null,"build":null,"lint":null},"worktreeBaseDir":"../","project":{"number":null,"statusField":"S"}}'
  printf 'test:\n\techo hi\n' > "$WORK/Makefile"
  run bash -c "cd '$WORK' && '$SCRIPT' test"
  [ "$output" = "make test" ]
}

@test "nothing detected → empty output, exit 0" {
  cfg '{"repo":"o/r","bot":"b","candidateN":1,"wipLimit":1,"reclaim":{"timeoutMinutes":1,"heartbeatMinutes":1},"commands":{"test":null,"build":null,"lint":null},"worktreeBaseDir":"../","project":{"number":null,"statusField":"S"}}'
  # --separate-stderr: the script intentionally logs a diagnostic to stderr on the
  # no-detection path; callers consume only stdout via $(...). Assert stdout is empty.
  run --separate-stderr bash -c "cd '$WORK' && '$SCRIPT' test"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "auto-detect pytest from pyproject.toml" {
  cfg '{"repo":"o/r","bot":"b","candidateN":1,"wipLimit":1,"reclaim":{"timeoutMinutes":1,"heartbeatMinutes":1},"commands":{"test":null,"build":null,"lint":null},"worktreeBaseDir":"../","project":{"number":null,"statusField":"S"}}'
  printf '[tool.pytest.ini_options]\n' > "$WORK/pyproject.toml"
  run bash -c "cd '$WORK' && '$SCRIPT' test"
  [ "$output" = "pytest" ]
}

@test "auto-detect pytest from pytest.ini" {
  cfg '{"repo":"o/r","bot":"b","candidateN":1,"wipLimit":1,"reclaim":{"timeoutMinutes":1,"heartbeatMinutes":1},"commands":{"test":null,"build":null,"lint":null},"worktreeBaseDir":"../","project":{"number":null,"statusField":"S"}}'
  printf '[pytest]\n' > "$WORK/pytest.ini"
  run bash -c "cd '$WORK' && '$SCRIPT' test"
  [ "$output" = "pytest" ]
}

@test "auto-detect pytest from tox.ini" {
  cfg '{"repo":"o/r","bot":"b","candidateN":1,"wipLimit":1,"reclaim":{"timeoutMinutes":1,"heartbeatMinutes":1},"commands":{"test":null,"build":null,"lint":null},"worktreeBaseDir":"../","project":{"number":null,"statusField":"S"}}'
  printf '[tox]\n' > "$WORK/tox.ini"
  run bash -c "cd '$WORK' && '$SCRIPT' test"
  [ "$output" = "pytest" ]
}

@test "build and lint kinds auto-detect their Makefile targets" {
  cfg '{"repo":"o/r","bot":"b","candidateN":1,"wipLimit":1,"reclaim":{"timeoutMinutes":1,"heartbeatMinutes":1},"commands":{"test":null,"build":null,"lint":null},"worktreeBaseDir":"../","project":{"number":null,"statusField":"S"}}'
  printf 'build:\n\techo b\nlint:\n\techo l\n' > "$WORK/Makefile"
  run bash -c "cd '$WORK' && '$SCRIPT' build"
  [ "$output" = "make build" ]
  run bash -c "cd '$WORK' && '$SCRIPT' lint"
  [ "$output" = "make lint" ]
}

@test "config override is read from .ganpan when ORCH_CONFIG is unset" {
  unset ORCH_CONFIG
  mkdir -p "$WORK/.ganpan"
  printf '%s' '{"repo":"o/r","bot":"b","candidateN":1,"wipLimit":1,"reclaim":{"timeoutMinutes":1,"heartbeatMinutes":1},"commands":{"test":"npm run ci","build":null,"lint":null},"worktreeBaseDir":"../","project":{"number":null,"statusField":"S"}}' > "$WORK/.ganpan/orchestration.json"

  run bash -c "cd '$WORK' && '$SCRIPT' test"
  [ "$status" -eq 0 ]
  [ "$output" = "npm run ci" ]
}

@test "config override prefers .ganpan over .claude when both configs exist" {
  unset ORCH_CONFIG
  mkdir -p "$WORK/.ganpan" "$WORK/.claude"
  printf '%s' '{"repo":"o/r","bot":"b","candidateN":1,"wipLimit":1,"reclaim":{"timeoutMinutes":1,"heartbeatMinutes":1},"commands":{"test":"npm run ganpan","build":null,"lint":null},"worktreeBaseDir":"../","project":{"number":null,"statusField":"S"}}' > "$WORK/.ganpan/orchestration.json"
  printf '%s' '{"repo":"o/r","bot":"b","candidateN":1,"wipLimit":1,"reclaim":{"timeoutMinutes":1,"heartbeatMinutes":1},"commands":{"test":"npm run claude","build":null,"lint":null},"worktreeBaseDir":"../","project":{"number":null,"statusField":"S"}}' > "$WORK/.claude/orchestration.json"

  run bash -c "cd '$WORK' && '$SCRIPT' test"
  [ "$status" -eq 0 ]
  [ "$output" = "npm run ganpan" ]
}
