#!/usr/bin/env bats

setup() {
  load helpers/common
  setup_gh_stub
  export ORCH_CONFIG="$BATS_TEST_TMPDIR/orchestration.json"
  printf '{"repo":"o/r","bot":"b","candidateN":1,"wipLimit":1,"reclaim":{"timeoutMinutes":1,"heartbeatMinutes":1},"commands":{"test":null,"build":null,"lint":null},"worktreeBaseDir":"../","project":{"number":null,"statusField":"Status"}}' > "$ORCH_CONFIG"
  SCRIPT="$BATS_TEST_DIRNAME/../../plugins/orchestration/scripts/orchestration/bootstrap-labels.sh"
  LABELS="$BATS_TEST_DIRNAME/../../plugins/orchestration/assets/labels.yml"
  # Derived from labels.yml, never hardcoded: a label added to the asset raises the
  # expectation automatically. A frozen literal is the shape of bug that let
  # status:needs-decision ship in the asset while no repo ever received it (#81).
  N_LABELS=$(yq -r '.[].name' "$LABELS" | grep -c .)
}

@test "creates every label defined in labels.yml via gh label create" {
  run bash "$SCRIPT" "$LABELS"
  [ "$status" -eq 0 ]
  run grep -c '^label create' "$GH_CALLS"
  [ "$output" -eq "$N_LABELS" ]
}

@test "every label name in labels.yml is bootstrapped by name (#81)" {
  # The count alone would still pass if one name were created twice and another skipped.
  bash "$SCRIPT" "$LABELS"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    grep -qF "label create $name " "$GH_CALLS"
  done < <(yq -r '.[].name' "$LABELS")
}

@test "passes name color and description for each label" {
  bash "$SCRIPT" "$LABELS"
  grep -q 'label create status:in-progress --color fbca04 --description' "$GH_CALLS"
}

@test "uses --force so re-running is idempotent (create-or-update)" {
  bash "$SCRIPT" "$LABELS"
  # --force on every label create; without it a second bootstrap run would error on existing labels
  run grep -c 'label create .* --force' "$GH_CALLS"
  [ "$output" -eq "$N_LABELS" ]
}

@test "bootstrap-labels creates status:needs-decision" {
  run bash "$SCRIPT" "$LABELS"
  [ "$status" -eq 0 ]
  grep -q 'label create status:needs-decision' "$GH_CALLS"
}

@test "is NOT actor-gated — runs under /orch-setup before the bot PAT exists (spec §4.3)" {
  # config.bot is "b" (setup) and GH_STUB_LOGIN is unset → the stub would report
  # the default login "bot-login" (≠ "b"). If require_bot_actor were ever added here,
  # the gate would call `gh api user` and abort on the mismatch. Assert it does neither:
  # bootstrap must succeed as whoever runs setup (often the human, pre-PAT).
  run bash "$SCRIPT" "$LABELS"
  [ "$status" -eq 0 ]
  ! grep -q 'api user' "$GH_CALLS"          # never probes identity == never gated
  run grep -c '^label create' "$GH_CALLS"
  [ "$output" -eq "$N_LABELS" ]
}
