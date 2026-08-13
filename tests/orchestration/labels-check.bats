#!/usr/bin/env bats

# labels-check.sh — read-only drift detector: labels defined in labels.yml vs. labels
# that actually exist on the repo (issue #81).

setup() {
  load helpers/common
  setup_gh_stub
  SCRIPT="$BATS_TEST_DIRNAME/../../plugins/orchestration/scripts/orchestration/labels-check.sh"
  ASSET_LABELS="$BATS_TEST_DIRNAME/../../plugins/orchestration/assets/labels.yml"
  export ORCH_CONFIG="$BATS_TEST_TMPDIR/orchestration.json"
  printf '{"repo":"o/r","bot":"b","candidateN":1,"wipLimit":1,"reclaim":{"timeoutMinutes":1,"heartbeatMinutes":1},"commands":{"test":null,"build":null,"lint":null},"worktreeBaseDir":"../","project":{"number":null,"statusField":"Status"}}' > "$ORCH_CONFIG"
}

# Emit the `gh label list --json name --jq '.[].name'` result: the stub returns a queued
# response verbatim, and the script consumes it as newline-separated names.
queue_labels() { queue_response "$(printf '%s\n' "$@")"; }

# A labels.yml fixture with exactly the given names (color/description are irrelevant here).
write_labels_yml() {
  local f="$BATS_TEST_TMPDIR/labels.yml" n
  : > "$f"
  for n in "$@"; do
    printf -- '- name: "%s"\n  color: "ededed"\n  description: "x"\n' "$n" >> "$f"
  done
  printf '%s' "$f"
}

@test "every defined label exists → OK exit 0" {
  f="$(write_labels_yml 'status:triage' 'status:done')"
  queue_labels 'status:triage' 'status:done' 'bug'   # extra repo labels are not drift
  run bash "$SCRIPT" "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *"labels-check: OK"* ]]
  [[ "$output" == *"all 2 label(s)"* ]]
}

@test "a defined label missing on the repo → DRIFT exit 1 naming it" {
  f="$(write_labels_yml 'status:triage' 'status:needs-decision')"
  queue_labels 'status:triage'
  run bash "$SCRIPT" "$f"
  [ "$status" -eq 1 ]
  [[ "$output" == *"labels-check: DRIFT"* ]]
  [[ "$output" == *"status:needs-decision"* ]]
  # the fix must be actionable: name the idempotent bootstrap re-run
  [[ "$output" == *"bootstrap-labels.sh"* ]]
}

@test "read-only: never issues a label write" {
  f="$(write_labels_yml 'status:triage')"
  queue_labels ''
  run bash "$SCRIPT" "$f"
  ! grep -q 'label create' "$GH_CALLS"
  ! grep -q 'label delete' "$GH_CALLS"
}

@test "lists with --limit 1000 so a label past the default page is not reported missing" {
  f="$(write_labels_yml 'status:triage')"
  queue_labels 'status:triage'
  bash "$SCRIPT" "$f"
  grep -q 'label list .*--limit 1000' "$GH_CALLS"
}

@test "gh label list failure → exit 1, reported as inconclusive rather than drift" {
  f="$(write_labels_yml 'status:triage')"
  export GH_FAIL_MATCH='label list'
  run bash "$SCRIPT" "$f"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Inconclusive"* ]]
  [[ "$output" != *"DRIFT"* ]]
}

@test "missing labels.yml → exit 1 with setup guidance, no gh call" {
  run bash "$SCRIPT" "$BATS_TEST_TMPDIR/nope.yml"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no labels.yml found"* ]]
  ! grep -q 'label list' "$GH_CALLS"
}

@test "no config → exit 1 with a stdout explanation (advisory callers show stdout)" {
  export ORCH_CONFIG="$BATS_TEST_TMPDIR/absent.json"
  run bash "$SCRIPT" "$ASSET_LABELS"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no usable ganpan config"* ]]
}

@test "is NOT actor-gated — runs at setup time before the bot PAT exists" {
  f="$(write_labels_yml 'status:triage')"
  queue_labels 'status:triage'
  run bash "$SCRIPT" "$f"
  [ "$status" -eq 0 ]
  ! grep -q 'api user' "$GH_CALLS"
}

@test "defaults to the shipped asset when no argument and no .github/labels.yml" {
  # cwd has no .github/labels.yml, so it must fall back to the plugin asset — i.e. it
  # checks the full shipped set, which is what makes it useful on an upgrade.
  cd "$BATS_TEST_TMPDIR"
  n=$(yq -r '.[].name' "$ASSET_LABELS" | grep -c .)
  queue_response "$(yq -r '.[].name' "$ASSET_LABELS")"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"all $n label(s)"* ]]
}
