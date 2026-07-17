#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$BATS_TEST_DIRNAME/.."
  TARGET="$BATS_TEST_TMPDIR/target"
  mkdir -p "$TARGET/.git"
}

@test "--target antigravity installs the agents-skills payload without Claude commands" {
  run bash "$REPO_ROOT/install.sh" "$TARGET" --target antigravity
  [ "$status" -eq 0 ]
  for name in ganpan-triage ganpan-work-issue ganpan-review-queue ganpan-qa-check ganpan-setup ganpan-update; do
    [ -f "$TARGET/.agents/skills/$name/SKILL.md" ]
  done
  [ -f "$TARGET/scripts/orchestration/claim.sh" ]
  [ -f "$TARGET/references/lanes/work-issue.md" ]
  [ -f "$TARGET/docs/SETUP.md" ]
  [ -f "$TARGET/.ganpan/orchestration.json" ]
  run grep -qF '<!-- ganpan-codex-conventions -->' "$TARGET/AGENTS.md"
  [ "$status" -eq 0 ]
  [ ! -d "$TARGET/.claude/commands" ]
}

@test "installed SKILL.md files carry name/description frontmatter (agy discovery contract)" {
  run bash "$REPO_ROOT/install.sh" "$TARGET" --target antigravity
  [ "$status" -eq 0 ]
  for skill in "$TARGET"/.agents/skills/ganpan-*/SKILL.md; do
    run sed -n '1,3p' "$skill"
    [[ "$output" == ---$'\n'name:*$'\n'description:* ]]
  done
}

@test "--target all installs Claude commands plus the agents-skills payload" {
  run bash "$REPO_ROOT/install.sh" "$TARGET" --target all
  [ "$status" -eq 0 ]
  [ -f "$TARGET/.claude/commands/work-issue.md" ]
  [ -f "$TARGET/.agents/skills/ganpan-work-issue/SKILL.md" ]
  run grep -qF '<!-- orchestration-conventions -->' "$TARGET/CLAUDE.md"
  [ "$status" -eq 0 ]
  run grep -qF '<!-- ganpan-codex-conventions -->' "$TARGET/AGENTS.md"
  [ "$status" -eq 0 ]
}

@test "--target antigravity next steps mention agy and /skills, no /ganpan: commands" {
  run bash "$REPO_ROOT/install.sh" "$TARGET" --target antigravity
  [ "$status" -eq 0 ]
  [[ "$output" == *"agy"* ]]
  [[ "$output" == *"/skills"* ]]
  [[ "$output" != *"/ganpan:"* ]]
}

@test "invalid --target dies listing the accepted values" {
  run bash "$REPO_ROOT/install.sh" "$TARGET" --target nope
  [ "$status" -ne 0 ]
  [[ "$output" == *"claude, codex, antigravity, both, all"* ]]
}

@test "--target both stdout has no antigravity leakage (narrow guard — full byte-identity is covered by tests/install.bats plus code review, not this test)" {
  run bash "$REPO_ROOT/install.sh" "$TARGET" --target both
  [ "$status" -eq 0 ]
  [[ "$output" != *"agy"* ]]
  [ -f "$TARGET/.claude/commands/work-issue.md" ]
  [ -f "$TARGET/.agents/skills/ganpan-work-issue/SKILL.md" ]
}
