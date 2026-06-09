#!/usr/bin/env bats

bats_require_minimum_version 1.5.0  # for `run --separate-stderr` in the last test

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../scripts/orchestration/detect-test-cmd.sh"
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
