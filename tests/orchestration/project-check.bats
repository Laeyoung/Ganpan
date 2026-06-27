#!/usr/bin/env bats

# project-check.sh — read-only diagnostic for GitHub Projects status-sync config.

setup() {
  load helpers/common
  setup_gh_stub
  SCRIPT="$BATS_TEST_DIRNAME/../../plugins/orchestration/scripts/orchestration/project-check.sh"
  export GH_STUB_LOGIN=botx
  export ORCH_CONFIG="$BATS_TEST_TMPDIR/orchestration.json"
}

# config with project.number SET (non-null) so checks run past the null short-circuit.
cfg_with_number() {
  cat > "$ORCH_CONFIG" <<'JSON'
{ "repo":"o/r","bot":"botx","candidateN":3,"wipLimit":4,
  "reclaim":{"timeoutMinutes":120,"heartbeatMinutes":15},
  "commands":{"test":null,"build":null,"lint":null},
  "worktreeBaseDir":"../","project":{"number":1,"statusField":"Status"} }
JSON
}

# config with project.number null (sync disabled).
cfg_null() {
  cat > "$ORCH_CONFIG" <<'JSON'
{ "repo":"o/r","bot":"botx","candidateN":3,"wipLimit":4,
  "reclaim":{"timeoutMinutes":120,"heartbeatMinutes":15},
  "commands":{"test":null,"build":null,"lint":null},
  "worktreeBaseDir":"../","project":{"number":null,"statusField":"Status"} }
JSON
}

@test "not configured (number null) → exit 0, no gh call" {
  cfg_null
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no-op"* ]]
}

@test "project view fails → exit 1 (access guidance)" {
  cfg_with_number
  export GH_FAIL_MATCH='project view'   # short-circuits before the queue → no queue_response needed
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot access project"* ]]
}

@test "missing a required option → exit 1 naming it" {
  cfg_with_number
  queue_response '{"id":"PVT_x"}'                                                   # gh project view
  queue_response '{"fields":[{"name":"Status","options":[{"name":"In Progress"},{"name":"In Review"},{"name":"QA"}]}]}'  # field-list (no Done)
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Done"* ]]
}

@test "all four options present → exit 0 with summary" {
  cfg_with_number
  queue_response '{"id":"PVT_x"}'                                                   # gh project view
  queue_response '{"fields":[{"name":"Status","options":[{"name":"In Progress"},{"name":"In Review"},{"name":"QA"},{"name":"Done"}]}]}'  # field-list
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "duplicate-named status field → exit 1" {
  cfg_with_number
  queue_response '{"id":"PVT_x"}'
  queue_response '{"fields":[{"name":"Status","options":[]},{"name":"Status","options":[]}]}'
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unique"* ]]
}
