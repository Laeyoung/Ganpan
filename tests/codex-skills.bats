#!/usr/bin/env bats

setup() {
  REPO_ROOT="$BATS_TEST_DIRNAME/.."
  CODEX_SKILLS="$REPO_ROOT/plugins/ganpan-codex/skills"
  LANE_REFS="$REPO_ROOT/plugins/orchestration/references/lanes"
}

@test "codex skills include required frontmatter and openai metadata" {
  for name in ganpan-triage ganpan-work-issue ganpan-review-queue ganpan-qa-check ganpan-setup; do
    skill="$CODEX_SKILLS/$name/SKILL.md"
    metadata="$CODEX_SKILLS/$name/agents/openai.yaml"

    [ -f "$skill" ]
    [ -f "$metadata" ]
    run sed -n '1,5p' "$skill"
    [ "$status" -eq 0 ]
    [[ "$output" == ---$'\n'name:*$'\n'description:* ]]
    run grep -Eq '^name: ganpan-' "$metadata"
    [ "$status" -eq 0 ]
    run grep -Eq '^description: .+' "$metadata"
    [ "$status" -eq 0 ]
  done
}

@test "codex artifacts do not contain Claude-only execution tokens" {
  run grep -R -E 'CLAUDE_PLUGIN_ROOT|/loop|/goal|PLUGIN_ROOT|PLUGIN_DATA' "$REPO_ROOT/plugins/ganpan-codex"
  [ "$status" -ne 0 ]
}

@test "shared lane references exist for every lane" {
  for lane in triage work-issue review-queue qa-check setup; do
    [ -f "$LANE_REFS/$lane.md" ]
  done
}

@test "codex lane references match the shared source" {
  for lane in triage work-issue review-queue qa-check setup; do
    run cmp -s "$LANE_REFS/$lane.md" "$CODEX_SKILLS/ganpan-$lane/references/$lane.md"
    [ "$status" -eq 0 ]
  done
}

@test "runtime Claude lane commands do not hardcode the legacy config path" {
  run grep -R '\.claude/orchestration\.json' \
    "$REPO_ROOT/plugins/orchestration/commands/triage.md" \
    "$REPO_ROOT/plugins/orchestration/commands/work-issue.md" \
    "$REPO_ROOT/plugins/orchestration/commands/review-queue.md" \
    "$REPO_ROOT/plugins/orchestration/commands/qa-check.md"
  [ "$status" -ne 0 ]
}
