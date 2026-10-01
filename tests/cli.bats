#!/usr/bin/env bats
# tests/cli.bats — bin/ganpan.mjs (npx `ganpan` CLI) + version-sync guards.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CLI="$REPO_ROOT/bin/ganpan.mjs"
  PLUGIN_VERSION="$(jq -r .version "$REPO_ROOT/plugins/orchestration/.claude-plugin/plugin.json")"
}

@test "--version prints the plugin.json version" {
  run node "$CLI" --version
  [ "$status" -eq 0 ]
  [ "$output" = "$PLUGIN_VERSION" ]
  run node "$CLI" -v
  [ "$output" = "$PLUGIN_VERSION" ]
}

@test "package.json version equals plugin.json version" {
  run jq -r .version "$REPO_ROOT/package.json"
  [ "$status" -eq 0 ]
  [ "$output" = "$PLUGIN_VERSION" ]
}

@test "package.json declares the ganpan bin, ESM, node>=18, and the install payload" {
  pkg="$REPO_ROOT/package.json"
  [ "$(jq -r .type "$pkg")" = "module" ]
  [ "$(jq -r .private "$pkg")" = "true" ]
  [ "$(jq -r '.bin.ganpan' "$pkg")" = "./bin/ganpan.mjs" ]
  [ "$(jq -r '.engines.node' "$pkg")" = ">=18" ]
  [ "$(jq -c '.files' "$pkg")" = '["bin","install.sh","plugins","docs/SETUP.md"]' ]
}

@test "help / no args print usage and exit 0" {
  for arg in "" help -h --help; do
    if [ -z "$arg" ]; then run node "$CLI"; else run node "$CLI" "$arg"; fi
    [ "$status" -eq 0 ]
    [[ "$output" == *"ganpan init [dir]"* ]]
    [[ "$output" == *"ganpan validate [dir]"* ]]
  done
}

@test "unknown command prints usage and exits 2" {
  run node "$CLI" frobnicate
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown command: frobnicate"* ]]
  [[ "$output" == *"usage:"* ]]
}

@test "bin/ganpan.mjs has a node shebang and is tracked executable (100755)" {
  run head -n1 "$CLI"
  [ "$output" = "#!/usr/bin/env node" ]
  run git -C "$REPO_ROOT" ls-files -s bin/ganpan.mjs
  [ "$status" -eq 0 ]
  [[ "$output" == 100755* ]]
}

@test "ganpan.mjs imports only node: built-ins" {
  # every import specifier must carry the literal node: prefix ('node-fetch' etc. must fail)
  run grep -cE "^import " "$CLI"
  [ "$output" -gt 0 ]
  run bash -c "grep -E \"^import \" '$CLI' | grep -v \"from 'node:\""
  [ -z "$output" ]
}

# install_fresh <dir> — engine + codex payload into <dir> via install.sh (fixture for validate).
install_fresh() {
  mkdir -p "$1/.git"
  bash "$REPO_ROOT/install.sh" "$1" --target codex >/dev/null
}

# fill_config <dir> — replace the template placeholders with real-looking values.
fill_config() {
  local cfg="$1/.ganpan/orchestration.json"
  jq '.repo = "acme/widgets" | .bot = "acme-bot"' "$cfg" > "$cfg.tmp" && mv "$cfg.tmp" "$cfg"
}

@test "validate: fresh install fails on template placeholders" {
  T="$BATS_TEST_TMPDIR/t"; install_fresh "$T"
  run node "$CLI" validate "$T"
  [ "$status" -eq 1 ]
  [[ "$output" == *'FAIL config.repo is still the template placeholder "owner/repo"'* ]]
  [[ "$output" == *'FAIL config.bot is still the template placeholder "bot-login"'* ]]
}

@test "validate: filled-in install passes" {
  T="$BATS_TEST_TMPDIR/t"; install_fresh "$T"; fill_config "$T"
  run node "$CLI" validate "$T"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok   config"*"repo acme/widgets"* ]]
  [[ "$output" == *"ok   engine version v$PLUGIN_VERSION"* ]]
  [[ "$output" == *"ok   labels .github/labels.yml"* ]]
  [[ "$output" != *"FAIL"* ]]
}

@test "validate: defaults to the current directory" {
  T="$BATS_TEST_TMPDIR/t"; install_fresh "$T"; fill_config "$T"
  cd "$T"
  run node "$CLI" validate
  [ "$status" -eq 0 ]
}

@test "validate: repo/bot null or non-string, or repo not owner/name -> FAIL" {
  T="$BATS_TEST_TMPDIR/t"; install_fresh "$T"
  cfg="$T/.ganpan/orchestration.json"
  jq '.repo = null | .bot = 5' "$cfg" > "$cfg.tmp" && mv "$cfg.tmp" "$cfg"
  run node "$CLI" validate "$T"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL config.repo must be a non-empty string"* ]]
  [[ "$output" == *"FAIL config.bot must be a non-empty string"* ]]
  jq '.repo = "just-a-name" | .bot = "b"' "$cfg" > "$cfg.tmp" && mv "$cfg.tmp" "$cfg"
  run node "$CLI" validate "$T"
  [ "$status" -eq 1 ]
  [[ "$output" == *'FAIL config.repo "just-a-name" must look like owner/name'* ]]
}

@test "validate: config that is JSON null or an array -> FAIL, not a crash (Review Focus 4)" {
  T="$BATS_TEST_TMPDIR/t"; install_fresh "$T"
  for body in 'null' '[]'; do
    printf '%s\n' "$body" > "$T/.ganpan/orchestration.json"
    run node "$CLI" validate "$T"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL config must be a JSON object"* ]]
    [[ "$output" != *"TypeError"* ]]
  done
}

@test "validate: invalid JSON -> FAIL" {
  T="$BATS_TEST_TMPDIR/t"; install_fresh "$T"
  printf '{ not json' > "$T/.ganpan/orchestration.json"
  run node "$CLI" validate "$T"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL config is not valid JSON"* ]]
}

@test "validate: missing dir -> exit 1" {
  run node "$CLI" validate "$BATS_TEST_TMPDIR/nope"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL directory not found"* ]]
}

@test "validate: dir without engine or config -> exit 1 naming both" {
  T="$BATS_TEST_TMPDIR/empty"; mkdir -p "$T"
  run node "$CLI" validate "$T"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL config missing"* ]]
  [[ "$output" == *"FAIL engine missing: scripts/orchestration/lib.sh"* ]]
}

@test "validate: missing .github/labels.yml -> FAIL naming it" {
  T="$BATS_TEST_TMPDIR/t"; install_fresh "$T"; fill_config "$T"
  rm "$T/.github/labels.yml"
  run node "$CLI" validate "$T"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL labels missing: .github/labels.yml"* ]]
}

@test "validate: engine version drift is a warn, still exit 0" {
  T="$BATS_TEST_TMPDIR/t"; install_fresh "$T"; fill_config "$T"
  lib="$T/scripts/orchestration/lib.sh"
  sed "s/ganpan-orchestration: v[0-9.]*/ganpan-orchestration: v0.0.1/" "$lib" > "$lib.tmp" && mv "$lib.tmp" "$lib"
  run node "$CLI" validate "$T"
  [ "$status" -eq 0 ]
  [[ "$output" == *"warn engine v0.0.1 differs from ganpan v$PLUGIN_VERSION"* ]]
}

@test "validate: legacy .claude/orchestration.json is used when .ganpan is absent" {
  T="$BATS_TEST_TMPDIR/t"; install_fresh "$T"; fill_config "$T"
  mkdir -p "$T/.claude"; mv "$T/.ganpan/orchestration.json" "$T/.claude/orchestration.json"
  run node "$CLI" validate "$T"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok   config $T/.claude/orchestration.json"* ]]
}

@test "validate: absolute ORCH_CONFIG wins over .ganpan" {
  T="$BATS_TEST_TMPDIR/t"; install_fresh "$T"          # .ganpan config keeps placeholders
  jq '.repo = "acme/alt" | .bot = "alt-bot"' "$T/.ganpan/orchestration.json" > "$BATS_TEST_TMPDIR/alt.json"
  run env ORCH_CONFIG="$BATS_TEST_TMPDIR/alt.json" node "$CLI" validate "$T"
  [ "$status" -eq 0 ]
  [[ "$output" == *"repo acme/alt"* ]]
}

@test "validate: relative ORCH_CONFIG resolves against dir, not cwd" {
  T="$BATS_TEST_TMPDIR/t"; install_fresh "$T"          # .ganpan config keeps placeholders
  mkdir -p "$T/custom"
  jq '.repo = "acme/rel" | .bot = "rel-bot"' "$T/.ganpan/orchestration.json" > "$T/custom/cfg.json"
  cd "$BATS_TEST_TMPDIR"                                # cwd != dir, and has no custom/cfg.json
  run env ORCH_CONFIG=custom/cfg.json node "$CLI" validate t
  [ "$status" -eq 0 ]
  real_t="$(cd "$T" && pwd -P)"                         # node's cwd is the physical path (macOS /private/var)
  [[ "$output" == *"ok   config $real_t/custom/cfg.json"* ]]
}

@test "validate: ORCH_CONFIG pointing at a missing file -> FAIL, no fallback (Review Focus 5)" {
  T="$BATS_TEST_TMPDIR/t"; install_fresh "$T"; fill_config "$T"   # a valid .ganpan config exists
  run env ORCH_CONFIG="$BATS_TEST_TMPDIR/missing.json" node "$CLI" validate "$T"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL config not found: $BATS_TEST_TMPDIR/missing.json (from \$ORCH_CONFIG)"* ]]
}

@test "validate: rejects extra args and flags with exit 2" {
  run node "$CLI" validate a b
  [ "$status" -eq 2 ]
  run node "$CLI" validate --strict
  [ "$status" -eq 2 ]
}

@test "init: installs the codex payload by default" {
  T="$BATS_TEST_TMPDIR/t"; mkdir -p "$T/.git"
  run node "$CLI" init "$T"
  [ "$status" -eq 0 ]
  [ -f "$T/scripts/orchestration/lib.sh" ]
  [ -f "$T/.ganpan/orchestration.json" ]
  [ -f "$T/.agents/skills/ganpan-setup/SKILL.md" ]
  [ -f "$T/AGENTS.md" ]
  [ ! -d "$T/.claude/commands" ]          # codex, not claude
}

@test "init: --target claude is forwarded" {
  T="$BATS_TEST_TMPDIR/t"; mkdir -p "$T/.git"
  run node "$CLI" init "$T" --target claude
  [ "$status" -eq 0 ]
  [ -f "$T/.claude/commands/work-issue.md" ]
  [ ! -d "$T/.agents" ]
}

@test "init: then validate fails on placeholders until filled" {
  T="$BATS_TEST_TMPDIR/t"; mkdir -p "$T/.git"
  node "$CLI" init "$T" >/dev/null
  run node "$CLI" validate "$T"
  [ "$status" -eq 1 ]
  fill_config "$T"
  run node "$CLI" validate "$T"
  [ "$status" -eq 0 ]
}

@test "init: relative dir from another cwd installs into that dir" {
  mkdir -p "$BATS_TEST_TMPDIR/work/t/.git"
  cd "$BATS_TEST_TMPDIR/work"
  run node "$CLI" init t
  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/work/t/scripts/orchestration/lib.sh" ]
  [ ! -d "$BATS_TEST_TMPDIR/work/scripts" ]
}

@test "init: dir with spaces works (Review Focus 1)" {
  T="$BATS_TEST_TMPDIR/my repo"; mkdir -p "$T/.git"
  run node "$CLI" init "$T"
  [ "$status" -eq 0 ]
  [ -f "$T/scripts/orchestration/lib.sh" ]
}

@test "init: nonexistent dir -> exit 1, no stack trace (Review Focus 2)" {
  run node "$CLI" init "$BATS_TEST_TMPDIR/nope"
  [ "$status" -eq 1 ]
  [[ "$output" == *"target is not a directory"* ]]
  [[ "$output" != *"    at "* ]]
}

@test "init: refuses a ganpan checkout, writes nothing" {
  T="$BATS_TEST_TMPDIR/ganpan-clone"
  mkdir -p "$T/.git" "$T/plugins/orchestration/.claude-plugin"
  echo '{"version":"0.0.0"}' > "$T/plugins/orchestration/.claude-plugin/plugin.json"
  run node "$CLI" init "$T"
  [ "$status" -eq 1 ]
  [[ "$output" == *"is a ganpan checkout"* ]]
  [ ! -d "$T/scripts" ]
  [ ! -d "$T/.ganpan" ]
}

@test "init: jq missing from PATH -> actionable error, nothing written" {
  T="$BATS_TEST_TMPDIR/t"; mkdir -p "$T/.git"
  FAKEBIN="$BATS_TEST_TMPDIR/fakebin"; mkdir -p "$FAKEBIN"
  ln -s "$(command -v node)" "$FAKEBIN/node"
  ln -s "$(command -v bash)" "$FAKEBIN/bash"
  run env PATH="$FAKEBIN" "$FAKEBIN/node" "$CLI" init "$T"
  [ "$status" -eq 1 ]
  [[ "$output" == *"jq is required but not found on PATH"* ]]
  [ ! -d "$T/scripts" ]
}

@test "init: bash missing from PATH -> actionable error" {
  T="$BATS_TEST_TMPDIR/t"; mkdir -p "$T/.git"
  FAKEBIN="$BATS_TEST_TMPDIR/fakebin"; mkdir -p "$FAKEBIN"
  ln -s "$(command -v node)" "$FAKEBIN/node"
  ln -s "$(command -v jq)" "$FAKEBIN/jq"
  run env PATH="$FAKEBIN" "$FAKEBIN/node" "$CLI" init "$T"
  [ "$status" -eq 1 ]
  [[ "$output" == *"bash is required but not found on PATH"* ]]
}

@test "init: bad or missing --target value -> exit 2, nothing written (Review Focus 3)" {
  T="$BATS_TEST_TMPDIR/t"; mkdir -p "$T/.git"
  run node "$CLI" init "$T" --target nope
  [ "$status" -eq 2 ]
  [[ "$output" == *"--target must be one of: claude, codex, antigravity, both, all"* ]]
  run node "$CLI" init "$T" --target
  [ "$status" -eq 2 ]
  [[ "$output" == *"--target requires a value"* ]]
  run node "$CLI" init "$T" --bogus
  [ "$status" -eq 2 ]
  run node "$CLI" init "$T" extra-arg
  [ "$status" -eq 2 ]
  [ ! -d "$T/scripts" ]
}

@test "init: --force re-stamps drifted engine files" {
  T="$BATS_TEST_TMPDIR/t"; install_fresh "$T"
  lib="$T/scripts/orchestration/lib.sh"
  sed "s/ganpan-orchestration: v[0-9.]*/ganpan-orchestration: v0.0.1/" "$lib" > "$lib.tmp" && mv "$lib.tmp" "$lib"
  run node "$CLI" init "$T" --force
  [ "$status" -eq 0 ]
  run grep -c "ganpan-orchestration: v$PLUGIN_VERSION" "$lib"
  [ "$output" = "1" ]
}
