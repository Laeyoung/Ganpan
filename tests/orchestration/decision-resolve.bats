setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../plugins/orchestration/scripts/orchestration/decision-resolve.sh"
}

# Feed stdin via a temp file + redirection — never pipe into `run` (that runs in a
# subshell and bats would not capture $status/$output).
run_with() {
  printf '%s' "$1" > "$BATS_TEST_TMPDIR/in.json"
  run bash "$SCRIPT" < "$BATS_TEST_TMPDIR/in.json"
}

@test "single rework → action rework" {
  run_with '{"answers":[{"createdAt":"2026-01-01T00:00:00Z","bucket":"rework"}]}'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .action)" = "rework" ]
}

@test "single proceed → action proceed" {
  run_with '{"answers":[{"createdAt":"2026-01-01T00:00:00Z","bucket":"proceed"}]}'
  [ "$(echo "$output" | jq -r .action)" = "proceed" ]
}

@test "single followup → action followup" {
  run_with '{"answers":[{"createdAt":"2026-01-01T00:00:00Z","bucket":"followup"}]}'
  [ "$(echo "$output" | jq -r .action)" = "followup" ]
}

@test "no classifiable answers → clarify" {
  run_with '{"answers":[{"createdAt":"2026-01-01T00:00:00Z","bucket":"unclassifiable"}]}'
  [ "$(echo "$output" | jq -r .action)" = "clarify" ]
  [ "$(echo "$output" | jq -r .reason)" = "no-classifiable-answer" ]
}

@test "empty answers → clarify" {
  run_with '{"answers":[]}'
  [ "$(echo "$output" | jq -r .action)" = "clarify" ]
}

@test "first-bucket adoption: earliest classifiable wins (unclassifiable does not occupy)" {
  run_with '{"answers":[{"createdAt":"2026-01-01T00:00:01Z","bucket":"unclassifiable"},{"createdAt":"2026-01-01T00:00:02Z","bucket":"rework"}]}'
  [ "$(echo "$output" | jq -r .action)" = "rework" ]
}

@test "two same buckets → adopt, no conflict" {
  run_with '{"answers":[{"createdAt":"2026-01-01T00:00:01Z","bucket":"proceed"},{"createdAt":"2026-01-01T00:00:02Z","bucket":"proceed"}]}'
  [ "$(echo "$output" | jq -r .action)" = "proceed" ]
}

@test "conflict: rework then proceed → clarify" {
  run_with '{"answers":[{"createdAt":"2026-01-01T00:00:01Z","bucket":"rework"},{"createdAt":"2026-01-01T00:00:02Z","bucket":"proceed"}]}'
  [ "$(echo "$output" | jq -r .action)" = "clarify" ]
  [ "$(echo "$output" | jq -r .reason)" = "conflict" ]
}

@test "ordering independent of input order (sorted by createdAt)" {
  run_with '{"answers":[{"createdAt":"2026-01-01T00:00:09Z","bucket":"proceed"},{"createdAt":"2026-01-01T00:00:01Z","bucket":"rework"}]}'
  [ "$(echo "$output" | jq -r .reason)" = "conflict" ]
}

@test "malformed bucket → clarify/schema-violation, exit 0" {
  run_with '{"answers":[{"createdAt":"2026-01-01T00:00:01Z","bucket":"bogus"}]}'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .action)" = "clarify" ]
  [ "$(echo "$output" | jq -r .reason)" = "schema-violation" ]
}
