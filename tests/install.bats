#!/usr/bin/env bats

setup() {
  REPO_ROOT="$BATS_TEST_DIRNAME/.."
  TARGET="$BATS_TEST_TMPDIR/target"
  mkdir -p "$TARGET/.git"
}

@test "install copies engine, commands, assets into the target repo" {
  run bash "$REPO_ROOT/install.sh" "$TARGET"
  [ "$status" -eq 0 ]
  [ -f "$TARGET/scripts/orchestration/claim.sh" ]
  [ -f "$TARGET/.claude/commands/work-issue.md" ]
  [ -f "$TARGET/.github/labels.yml" ]
  [ -f "$TARGET/.claude/orchestration.json" ]
}

@test "copied commands have zero CLAUDE_PLUGIN_ROOT residue (path-drift guard)" {
  run bash "$REPO_ROOT/install.sh" "$TARGET"
  [ "$status" -eq 0 ]
  run grep -rl CLAUDE_PLUGIN_ROOT "$TARGET/.claude/commands" "$TARGET/scripts/orchestration"
  [ "$status" -ne 0 ]   # grep -l exits non-zero when there are no matches
}

@test "both .sh and .md copies carry exactly one version sentinel" {
  run bash "$REPO_ROOT/install.sh" "$TARGET"
  [ "$status" -eq 0 ]
  run grep -c 'ganpan-orchestration:' "$TARGET/scripts/orchestration/claim.sh"
  [ "$output" = "1" ]
  run grep -c 'ganpan-orchestration:' "$TARGET/.claude/commands/work-issue.md"
  [ "$output" = "1" ]
  # the .md sentinel must be an HTML comment, not a Markdown heading
  run grep -q '<!-- ganpan-orchestration:' "$TARGET/.claude/commands/work-issue.md"
  [ "$status" -eq 0 ]
}

@test "re-run with --force restamps without doubling the sentinel" {
  run bash "$REPO_ROOT/install.sh" "$TARGET"
  [ "$status" -eq 0 ]
  run bash "$REPO_ROOT/install.sh" "$TARGET" --force
  [ "$status" -eq 0 ]
  run grep -c 'ganpan-orchestration:' "$TARGET/scripts/orchestration/claim.sh"
  [ "$output" = "1" ]   # .sh restamped, not doubled
  run grep -c 'ganpan-orchestration:' "$TARGET/.claude/commands/work-issue.md"
  [ "$output" = "1" ]   # .md restamped, not doubled
}
