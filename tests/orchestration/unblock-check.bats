#!/usr/bin/env bats

# unblock-check.sh — decides whether a status:blocked issue should be re-triaged.
# Re-triage when there is no bot-authored blocker comment, or when a TRUSTED human
# commented after the latest bot comment; otherwise keep it blocked (fail closed).

setup() {
  load helpers/common
  setup_gh_stub
  export ORCH_CONFIG="$BATS_TEST_TMPDIR/orchestration.json"
  export GH_STUB_LOGIN=botx
  SCRIPT="$BATS_TEST_DIRNAME/../../plugins/orchestration/scripts/orchestration/unblock-check.sh"
}

# write config; $1 = JSON array literal for reviewer.allowlist
write_config() {
  printf '{"repo":"o/r","bot":"botx","candidateN":3,"wipLimit":5,"reclaim":{"timeoutMinutes":120,"heartbeatMinutes":15},"commands":{"test":null,"build":null,"lint":null},"worktreeBaseDir":"../","project":{"number":null,"statusField":"Status"},"reviewer":{"permissionThreshold":"write","allowlist":%s,"followupIssueCapPerPR":3}}' "${1:-[]}" > "$ORCH_CONFIG"
}

@test "no comments at all → retriage: no-blocker (the #29 case)" {
  write_config
  queue_response '{"comments":[]}'
  run bash "$SCRIPT" 29
  [ "$status" -eq 0 ]
  [ "$output" = "retriage: no-blocker" ]
}

@test "no BOT comment (only human chatter) → retriage: no-blocker" {
  write_config
  queue_response '{"comments":[{"author":{"login":"someone"},"createdAt":"2026-01-01T00:00:00Z","body":"hi"}]}'
  run bash "$SCRIPT" 7
  [ "$status" -eq 0 ]
  [ "$output" = "retriage: no-blocker" ]
}

@test "bot blocker, no human reply → keep-blocked" {
  write_config
  queue_response '{"comments":[{"author":{"login":"botx"},"createdAt":"2026-02-01T00:00:00Z","body":"Triage: 사람 결정 필요"}]}'
  run bash "$SCRIPT" 7
  [ "$status" -eq 0 ]
  [ "$output" = "keep-blocked" ]
}

@test "bot blocker + trusted (allowlisted) human reply after → retriage: human-answered" {
  write_config '["alice"]'
  # alice is allowlisted ⇒ is_trusted short-circuits, no permission API call
  queue_response '{"comments":[
    {"author":{"login":"botx"},"createdAt":"2026-02-01T00:00:00Z","body":"Triage: 질문"},
    {"author":{"login":"alice"},"createdAt":"2026-02-02T00:00:00Z","body":"답변: 진행하세요"}]}'
  run bash "$SCRIPT" 7
  [ "$status" -eq 0 ]
  [ "$output" = "retriage: human-answered" ]
  ! grep -q 'collaborators' "$GH_CALLS"   # allowlist hit ⇒ no permission lookup
}

@test "bot blocker + untrusted human reply after → keep-blocked" {
  write_config
  queue_response '{"comments":[
    {"author":{"login":"botx"},"createdAt":"2026-02-01T00:00:00Z","body":"Triage: 질문"},
    {"author":{"login":"rando"},"createdAt":"2026-02-02T00:00:00Z","body":"me too"}]}'
  queue_response 'read'   # rando is not allowlisted ⇒ permission lookup returns read (< write)
  run bash "$SCRIPT" 7
  [ "$status" -eq 0 ]
  [ "$output" = "keep-blocked" ]
  grep -q 'collaborators/rando/permission' "$GH_CALLS"
}

@test "trusted reply BEFORE a later bot comment → keep-blocked (boundary is the latest bot comment)" {
  write_config '["alice"]'
  queue_response '{"comments":[
    {"author":{"login":"botx"},"createdAt":"2026-02-01T00:00:00Z","body":"Triage: 질문"},
    {"author":{"login":"alice"},"createdAt":"2026-02-02T00:00:00Z","body":"답변"},
    {"author":{"login":"botx"},"createdAt":"2026-02-03T00:00:00Z","body":"Triage: 추가 질문"}]}'
  run bash "$SCRIPT" 7
  [ "$status" -eq 0 ]
  [ "$output" = "keep-blocked" ]
}

@test "issue view API failure → exit 1" {
  write_config
  export GH_FAIL_MATCH='issue view'
  run bash "$SCRIPT" 7
  [ "$status" -eq 1 ]
}
