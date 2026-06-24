#!/usr/bin/env bats

bats_require_minimum_version 1.5.0  # for `run --separate-stderr`

setup() {
  REPO_ROOT="$BATS_TEST_DIRNAME/.."
  TARGET="$BATS_TEST_TMPDIR/target"
  mkdir -p "$TARGET/.git"
}

@test "install copies engine, commands, assets into the target repo" {
  run bash "$REPO_ROOT/install.sh" "$TARGET"
  [ "$status" -eq 0 ]
  [ -f "$TARGET/scripts/orchestration/claim.sh" ]
  [ -x "$TARGET/scripts/orchestration/detect-test-cmd.sh" ]
  [ -f "$TARGET/.claude/commands/work-issue.md" ]
  [ -f "$TARGET/references/lanes/work-issue.md" ]
  [ -f "$TARGET/.github/labels.yml" ]
  [ -f "$TARGET/.claude/orchestration.json" ]
}

@test "copied commands have zero CLAUDE_PLUGIN_ROOT path residue (path-drift guard)" {
  run bash "$REPO_ROOT/install.sh" "$TARGET"
  [ "$status" -eq 0 ]
  # Guard the PATH form `${CLAUDE_PLUGIN_ROOT}/...` (what the sed rewrite targets),
  # not the bare token: run-all.md intentionally keeps a bare ${CLAUDE_PLUGIN_ROOT}
  # for install-mode detection + agent-preamble prose, which has no trailing slash
  # and is correct to retain. Shared references are copied verbatim (no sed), so
  # they must carry no path-form token either.
  run grep -rl 'CLAUDE_PLUGIN_ROOT}/' "$TARGET/.claude/commands" "$TARGET/scripts/orchestration" "$TARGET/references"
  [ "$status" -ne 0 ]   # grep -l exits non-zero when there are no matches
  # The path-form check above narrows to `CLAUDE_PLUGIN_ROOT}/`, which lets a
  # *bare* (slashless) unsubstituted token drift through in any lane file. run-all.md
  # is the ONLY file that legitimately keeps a bare ${CLAUDE_PLUGIN_ROOT} (install-mode
  # detection + agent-preamble prose); every other copied command must carry none.
  run grep -rl --exclude=run-all.md 'CLAUDE_PLUGIN_ROOT' "$TARGET/.claude/commands"
  [ "$status" -ne 0 ]
  run grep -q './references/lanes/work-issue.md' "$TARGET/.claude/commands/work-issue.md"
  [ "$status" -eq 0 ]
}

@test "both .sh and .md copies carry exactly one version sentinel" {
  run bash "$REPO_ROOT/install.sh" "$TARGET"
  [ "$status" -eq 0 ]
  run grep -c 'ganpan-orchestration:' "$TARGET/scripts/orchestration/claim.sh"
  [ "$output" = "1" ]
  run grep -c 'ganpan-orchestration:' "$TARGET/.claude/commands/work-issue.md"
  [ "$output" = "1" ]
  run grep -c 'ganpan-orchestration:' "$TARGET/references/lanes/work-issue.md"
  [ "$output" = "1" ]
  # the .md sentinel must be an HTML comment, not a Markdown heading
  run grep -q '<!-- ganpan-orchestration:' "$TARGET/.claude/commands/work-issue.md"
  [ "$status" -eq 0 ]
}

@test "run-all launcher command is installed and stamped" {
  run bash "$REPO_ROOT/install.sh" "$TARGET"
  [ "$status" -eq 0 ]
  [ -f "$TARGET/.claude/commands/run-all.md" ]
  run grep -c 'ganpan-orchestration:' "$TARGET/.claude/commands/run-all.md"
  [ "$output" = "1" ]
  run grep -q '<!-- ganpan-orchestration:' "$TARGET/.claude/commands/run-all.md"
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

@test "codex target installs skills and platform config without claude commands" {
  run bash "$REPO_ROOT/install.sh" "$TARGET" --target codex
  [ "$status" -eq 0 ]
  [ -f "$TARGET/scripts/orchestration/claim.sh" ]
  # stamp() rewrites the file inode via mktemp+mv; if it runs after chmod +x the
  # exec bit is lost (PHASE1_DEV_LOG regression). Guard it on the codex codepath too.
  [ -x "$TARGET/scripts/orchestration/detect-test-cmd.sh" ]
  [ -f "$TARGET/.agents/skills/ganpan-work-issue/SKILL.md" ]
  [ -f "$TARGET/.agents/skills/ganpan-triage/SKILL.md" ]
  [ -f "$TARGET/.agents/skills/ganpan-review-queue/SKILL.md" ]
  [ -f "$TARGET/.agents/skills/ganpan-qa-check/SKILL.md" ]
  [ -f "$TARGET/.agents/skills/ganpan-setup/SKILL.md" ]
  [ -f "$TARGET/.agents/skills/ganpan-work-issue/references/work-issue.md" ]
  [ -f "$TARGET/.agents/skills/ganpan-work-issue/agents/openai.yaml" ]
  [ -f "$TARGET/AGENTS.md" ]
  [ -f "$TARGET/.ganpan/orchestration.json" ]
  [ -f "$TARGET/.github/labels.yml" ]
  # Codex skills point at ./references/lanes/*.md; install.sh section 3 is
  # unconditional, but gate it behind wants_claude by mistake and codex installs
  # would silently ship skills whose references resolve to nothing.
  [ -f "$TARGET/references/lanes/work-issue.md" ]
  [ ! -d "$TARGET/.claude/commands" ]
  [ ! -f "$TARGET/.claude/orchestration.json" ]
}

@test "both target installs claude and codex surfaces with .ganpan config for new repos" {
  run bash "$REPO_ROOT/install.sh" "$TARGET" --target both
  [ "$status" -eq 0 ]
  [ -f "$TARGET/.claude/commands/work-issue.md" ]
  [ -f "$TARGET/.agents/skills/ganpan-work-issue/SKILL.md" ]
  [ -f "$TARGET/references/lanes/work-issue.md" ]
  [ -f "$TARGET/.ganpan/orchestration.json" ]
  [ ! -f "$TARGET/.claude/orchestration.json" ]
}

@test "codex target uses existing legacy claude config as fallback without creating .ganpan config" {
  mkdir -p "$TARGET/.claude"
  printf '{"repo":"legacy/repo","bot":"bot","candidateN":1,"wipLimit":1,"reclaim":{"timeoutMinutes":1,"heartbeatMinutes":1},"commands":{"test":null,"build":null,"lint":null},"worktreeBaseDir":"../","project":{"number":null,"statusField":"Status"}}' > "$TARGET/.claude/orchestration.json"

  run bash "$REPO_ROOT/install.sh" "$TARGET" --target codex
  [ "$status" -eq 0 ]
  [ -f "$TARGET/.claude/orchestration.json" ]
  [ ! -f "$TARGET/.ganpan/orchestration.json" ]
  [ -f "$TARGET/.agents/skills/ganpan-work-issue/SKILL.md" ]
  [[ "$output" == *"Using legacy .claude/orchestration.json"* ]]
  [[ "$output" == *"To migrate later, create .ganpan/orchestration.json deliberately"* ]]
}

@test "codex target preserves an existing .ganpan config" {
  mkdir -p "$TARGET/.ganpan"
  printf '{"repo":"existing/ganpan","bot":"bot","candidateN":1,"wipLimit":1,"reclaim":{"timeoutMinutes":1,"heartbeatMinutes":1},"commands":{"test":"keep-me","build":null,"lint":null},"worktreeBaseDir":"../","project":{"number":null,"statusField":"Status"}}' > "$TARGET/.ganpan/orchestration.json"

  run bash "$REPO_ROOT/install.sh" "$TARGET" --target codex
  [ "$status" -eq 0 ]
  run jq -r '.commands.test' "$TARGET/.ganpan/orchestration.json"
  [ "$output" = "keep-me" ]
}

@test "claude target with an existing .ganpan config prints that selected config path" {
  mkdir -p "$TARGET/.ganpan"
  printf '{"repo":"existing/ganpan","bot":"bot","candidateN":1,"wipLimit":1,"reclaim":{"timeoutMinutes":1,"heartbeatMinutes":1},"commands":{"test":"keep-me","build":null,"lint":null},"worktreeBaseDir":"../","project":{"number":null,"statusField":"Status"}}' > "$TARGET/.ganpan/orchestration.json"

  run bash "$REPO_ROOT/install.sh" "$TARGET" --target claude
  [ "$status" -eq 0 ]
  [ -f "$TARGET/.ganpan/orchestration.json" ]
  [ ! -f "$TARGET/.claude/orchestration.json" ]
  [[ "$output" == *"Edit .ganpan/orchestration.json"* ]]
}

@test "both target warns when .ganpan and .claude configs diverge without rewriting either" {
  mkdir -p "$TARGET/.ganpan" "$TARGET/.claude"
  printf '{"repo":"new/repo","bot":"bot","candidateN":1,"wipLimit":1,"reclaim":{"timeoutMinutes":1,"heartbeatMinutes":1},"commands":{"test":"ganpan","build":null,"lint":null},"worktreeBaseDir":"../","project":{"number":null,"statusField":"Status"}}' > "$TARGET/.ganpan/orchestration.json"
  printf '{"repo":"old/repo","bot":"bot","candidateN":1,"wipLimit":1,"reclaim":{"timeoutMinutes":1,"heartbeatMinutes":1},"commands":{"test":"claude","build":null,"lint":null},"worktreeBaseDir":"../","project":{"number":null,"statusField":"Status"}}' > "$TARGET/.claude/orchestration.json"

  run --separate-stderr bash "$REPO_ROOT/install.sh" "$TARGET" --target both
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"both .ganpan/orchestration.json and .claude/orchestration.json exist and differ"* ]]
  run jq -r '.commands.test' "$TARGET/.ganpan/orchestration.json"
  [ "$output" = "ganpan" ]
  run jq -r '.commands.test' "$TARGET/.claude/orchestration.json"
  [ "$output" = "claude" ]
}

@test "both target with matching configs does not warn or rewrite either config" {
  mkdir -p "$TARGET/.ganpan" "$TARGET/.claude"
  config='{"repo":"same/repo","bot":"bot","candidateN":1,"wipLimit":1,"reclaim":{"timeoutMinutes":1,"heartbeatMinutes":1},"commands":{"test":"same","build":null,"lint":null},"worktreeBaseDir":"../","project":{"number":null,"statusField":"Status"}}'
  printf '%s' "$config" > "$TARGET/.ganpan/orchestration.json"
  printf '%s' "$config" > "$TARGET/.claude/orchestration.json"

  run --separate-stderr bash "$REPO_ROOT/install.sh" "$TARGET" --target both
  [ "$status" -eq 0 ]
  [[ "$stderr" != *"both .ganpan/orchestration.json and .claude/orchestration.json exist and differ"* ]]
  run jq -r '.repo' "$TARGET/.ganpan/orchestration.json"
  [ "$output" = "same/repo" ]
  run jq -r '.repo' "$TARGET/.claude/orchestration.json"
  [ "$output" = "same/repo" ]
}

@test "codex AGENTS conventions are appended only once on rerun" {
  printf '# Existing guidance\n' > "$TARGET/AGENTS.md"

  run bash "$REPO_ROOT/install.sh" "$TARGET" --target codex
  [ "$status" -eq 0 ]
  run bash "$REPO_ROOT/install.sh" "$TARGET" --target codex
  [ "$status" -eq 0 ]

  run grep -c '<!-- ganpan-codex-conventions -->' "$TARGET/AGENTS.md"
  [ "$output" = "1" ]
}

@test "installer output does not print token values" {
  export GH_TOKEN="github_pat_secret_should_not_print"
  run bash "$REPO_ROOT/install.sh" "$TARGET" --target codex
  [ "$status" -eq 0 ]
  [[ "$output" != *"github_pat_secret_should_not_print"* ]]
}
