#!/usr/bin/env bats
#
# Structural regression guard for the subagent-dispatch (loop mode) pattern
# (issue #66). The four standard lane commands must each carry a
# `## Dispatch (loop mode)` section, a `## Lane procedure` section, and the
# literal GANPAN_EXECUTE_INLINE token; run-all must pass the same token to its
# lane agents; the out-of-scope commands must NOT have a dispatch section.
#
# This asserts the pattern is PRESENT (so it cannot be silently dropped or a
# lane missed) — not that the LLM-executed dispatch logic behaves correctly,
# which is verified operationally (it mirrors the proven run-all pattern).

setup() {
  REPO_ROOT="$BATS_TEST_DIRNAME/.."
  CMDS="$REPO_ROOT/plugins/orchestration/commands"
}

@test "each standard lane command has the dispatch + lane-procedure sections and the inline token" {
  for lane in triage work-issue review-queue qa-check; do
    cmd="$CMDS/$lane.md"
    [ -f "$cmd" ]
    run grep -qF '## Dispatch (loop mode)' "$cmd"
    [ "$status" -eq 0 ]
    run grep -qF '## Lane procedure' "$cmd"
    [ "$status" -eq 0 ]
    run grep -qF 'GANPAN_EXECUTE_INLINE' "$cmd"
    [ "$status" -eq 0 ]
  done
}

@test "each standard lane command has exactly one of each section heading (no duplicate body)" {
  # Anchor at line start: the strings also appear inside prose (e.g. the subagent
  # prompt references the "## Lane procedure" section), so only count headings.
  for lane in triage work-issue review-queue qa-check; do
    cmd="$CMDS/$lane.md"
    run grep -c '^## Lane procedure$' "$cmd"
    [ "$output" = "1" ]
    run grep -c '^## Dispatch (loop mode)$' "$cmd"
    [ "$output" = "1" ]
  done
}

@test "the dispatch header instructs spawning a foreground subagent" {
  for lane in triage work-issue review-queue qa-check; do
    cmd="$CMDS/$lane.md"
    # canonical dispatch marker: a foreground Agent spawn instruction
    run grep -qF 'run_in_background: false' "$cmd"
    [ "$status" -eq 0 ]
  done
}

@test "run-all passes the inline token to its lane agents" {
  run grep -qF 'GANPAN_EXECUTE_INLINE' "$CMDS/run-all.md"
  [ "$status" -eq 0 ]
}

@test "out-of-scope commands do NOT carry a dispatch (loop mode) section" {
  for cmd in work-issue-deep review-queue-deep orch-setup update; do
    f="$CMDS/$cmd.md"
    [ -f "$f" ]
    run grep -qF '## Dispatch (loop mode)' "$f"
    [ "$status" -ne 0 ]
  done
}

@test "the dispatch header uses only the slash-form plugin-root token (no bare token added)" {
  # The dispatch section must not introduce a bare ${CLAUDE_PLUGIN_ROOT} (one not
  # followed by a slash); install.sh's sed only rewrites the slash form, so a
  # bare token would survive copy-in and break tests/install.bats. We check that
  # every CLAUDE_PLUGIN_ROOT occurrence in the four lane files is slash-form.
  for lane in triage work-issue review-queue qa-check; do
    cmd="$CMDS/$lane.md"
    # count all occurrences vs slash-form occurrences; they must be equal.
    total=$(grep -oF 'CLAUDE_PLUGIN_ROOT}' "$cmd" | wc -l | tr -d ' ')
    slash=$(grep -oF 'CLAUDE_PLUGIN_ROOT}/' "$cmd" | wc -l | tr -d ' ')
    [ "$total" = "$slash" ]
  done
}
