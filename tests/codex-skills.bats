#!/usr/bin/env bats

setup() {
  REPO_ROOT="$BATS_TEST_DIRNAME/.."
  CODEX_SKILLS="$REPO_ROOT/plugins/ganpan-codex/skills"
  LANE_REFS="$REPO_ROOT/plugins/orchestration/references/lanes"
}

@test "codex skills include required frontmatter and openai metadata" {
  for name in ganpan-triage ganpan-work-issue ganpan-review-queue ganpan-qa-check ganpan-setup ganpan-update; do
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
    run yq e '.' "$metadata"
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

@test "runtime Claude lane commands point at shared lane references" {
  for lane in triage work-issue review-queue qa-check; do
    run grep -q "references/lanes/$lane.md" "$REPO_ROOT/plugins/orchestration/commands/$lane.md"
    [ "$status" -eq 0 ]
  done
}

@test "qa command shows the concrete repo-root capture before resolving config" {
  run grep -q 'REPO_ROOT="\$PWD"' "$REPO_ROOT/plugins/orchestration/commands/qa-check.md"
  [ "$status" -eq 0 ]
}

@test "qa pass path closes the GitHub issue" {
  for file in \
    "$REPO_ROOT/plugins/orchestration/commands/qa-check.md" \
    "$REPO_ROOT/plugins/orchestration/references/lanes/qa-check.md"; do
    run grep -Eq 'gh issue close .*--reason completed' "$file"
    [ "$status" -eq 0 ]
  done
}

@test "qa first-failure instructions preserve regression issue audit link" {
  for file in \
    "$REPO_ROOT/plugins/orchestration/commands/qa-check.md" \
    "$REPO_ROOT/plugins/orchestration/references/lanes/qa-check.md"; do
    run grep -qi 'regression issue.*number\|linked regression issue' "$file"
    [ "$status" -eq 0 ]
  done
}

@test "work-issue reference preserves rework resume safety steps" {
  ref="$REPO_ROOT/plugins/orchestration/references/lanes/work-issue.md"
  run grep -q 'kill any orphaned heartbeat' "$ref"
  [ "$status" -eq 0 ]
  run grep -q 'rework-resolved:' "$ref"
  [ "$status" -eq 0 ]
}

@test "work-issue-deep resume path runs conflict-resolve with loop-prevention skip" {
  cmd="$REPO_ROOT/plugins/orchestration/commands/work-issue-deep.md"
  run grep -q 'conflict-resolve.sh main' "$cmd"   # the invocation
  [ "$status" -eq 0 ]
  run grep -q 'up-to-date' "$cmd"                  # the up-to-date outcome branch
  [ "$status" -eq 0 ]
  run grep -q 'merged in cleanly' "$cmd"           # the resolved outcome branch (distinct from 'rework-resolved:')
  [ "$status" -eq 0 ]
  run grep -q '자동 해소 불가' "$cmd"               # the conflict-escalation gh pr comment body
  [ "$status" -eq 0 ]
  run grep -q 'Skip this whole step' "$cmd"        # the step-9 loop-prevention skip (core safety property)
  [ "$status" -eq 0 ]
}

@test "claude setup command respects the shared config contract" {
  setup_cmd="$REPO_ROOT/plugins/orchestration/commands/orch-setup.md"
  run grep -q '.ganpan/orchestration.json' "$setup_cmd"
  [ "$status" -eq 0 ]
  run grep -q 'neither .ganpan/orchestration.json nor .claude/orchestration.json exists' "$setup_cmd"
  [ "$status" -eq 0 ]
  run grep -q 'both config files exist and differ' "$setup_cmd"
  [ "$status" -eq 0 ]
}

@test "installed codex skills resolve references and metadata from .agents skills" {
  target="$BATS_TEST_TMPDIR/target"
  mkdir -p "$target/.git"

  run bash "$REPO_ROOT/install.sh" "$target" --target codex
  [ "$status" -eq 0 ]

  for name in ganpan-triage ganpan-work-issue ganpan-review-queue ganpan-qa-check ganpan-setup; do
    [ -f "$target/.agents/skills/$name/SKILL.md" ]
    [ -d "$target/.agents/skills/$name/references" ]
    [ -f "$target/.agents/skills/$name/agents/openai.yaml" ]
    run yq e '.' "$target/.agents/skills/$name/agents/openai.yaml"
    [ "$status" -eq 0 ]
  done

  # Existence alone would pass even if install copied an empty or wrong reference.
  # Verify the installed reference body matches the shared source. stamp() appends
  # a trailing blank line + sentinel comment, so compare only the first N lines
  # (N = source line count) — head -n is portable, unlike `head -n -2`.
  for lane in triage work-issue review-queue qa-check setup; do
    src="$LANE_REFS/$lane.md"
    installed="$target/.agents/skills/ganpan-$lane/references/$lane.md"
    [ -f "$installed" ]
    n=$(wc -l < "$src")
    run diff "$src" <(head -n "$n" "$installed")
    [ "$status" -eq 0 ]
  done
}
