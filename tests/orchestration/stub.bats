#!/usr/bin/env bats
setup() { load helpers/common; setup_gh_stub; }

@test "stub logs calls and returns queued responses in order" {
  queue_response '[{"number":1}]'
  queue_response '[{"number":2}]'
  run gh issue list --label x
  [ "$output" = '[{"number":1}]' ]
  run gh issue list --label y
  [ "$output" = '[{"number":2}]' ]
  grep -q 'issue list --label x' "$GH_CALLS"
}

@test "write commands produce no stdout" {
  run gh issue edit 5 --add-label foo
  [ -z "$output" ]
  grep -q 'issue edit 5 --add-label foo' "$GH_CALLS"
}
