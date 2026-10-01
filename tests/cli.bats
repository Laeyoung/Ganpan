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
