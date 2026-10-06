#!/usr/bin/env bats

# update-info.sh — advisory: install mode, installed vs latest version, per-mode update steps.

setup() {
  load helpers/common
  setup_gh_stub
  SCRIPT="$BATS_TEST_DIRNAME/../../plugins/orchestration/scripts/orchestration/update-info.sh"
  # update-info.sh self-isolates version-check's state dir, but pin one anyway for determinism.
  export GANPAN_STATE_DIR="$BATS_TEST_TMPDIR/state"
}

# build a copy-in target repo (cwd) whose lib.sh carries the install sentinel.
mk_copyin() {
  local root="$1" ver="$2"
  mkdir -p "$root/scripts/orchestration"
  printf '#!/usr/bin/env bash\n# lib\n# ganpan-orchestration: v%s\n' "$ver" > "$root/scripts/orchestration/lib.sh"
}

@test "copy-in: reports mode, sentinel version, and install.sh guidance" {
  mk_copyin "$BATS_TEST_TMPDIR/repo" 1.5.0
  queue_response '{"version":"9.9.9"}'                 # version-check.sh gh api GET
  cd "$BATS_TEST_TMPDIR/repo"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"mode:"*"copy-in"* ]]
  [[ "$output" == *"installed:"*"1.5.0"* ]]
  [[ "$output" == *"latest:"*"9.9.9"* ]]
  [[ "$output" == *"update available"* ]]
  [[ "$output" == *"install.sh"* ]]
  [[ "$output" == *"--force"* ]]
}

@test "copy-in: detected from a subdirectory (upward walk), not just repo root" {
  mk_copyin "$BATS_TEST_TMPDIR/repo" 1.5.0
  mkdir -p "$BATS_TEST_TMPDIR/repo/some/nested/dir"
  queue_response '{"version":"9.9.9"}'
  cd "$BATS_TEST_TMPDIR/repo/some/nested/dir"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"mode:"*"copy-in"* ]]
  [[ "$output" == *"installed:"*"1.5.0"* ]]
}

@test "plugin: reports mode, manifest version (via GANPAN_PLUGIN_MANIFEST), and /plugin guidance" {
  mkdir -p "$BATS_TEST_TMPDIR/empty"                   # cwd with no ./scripts/orchestration
  printf '{"version":"1.5.0"}' > "$BATS_TEST_TMPDIR/manifest.json"
  export GANPAN_PLUGIN_MANIFEST="$BATS_TEST_TMPDIR/manifest.json"
  queue_response '{"version":"9.9.9"}'
  cd "$BATS_TEST_TMPDIR/empty"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"mode:"*"plugin"* ]]
  [[ "$output" == *"installed:"*"1.5.0"* ]]
  [[ "$output" == *"/plugin"* ]]
}

@test "same version → up to date" {
  mk_copyin "$BATS_TEST_TMPDIR/repo" 9.9.9
  queue_response '{"version":"9.9.9"}'
  cd "$BATS_TEST_TMPDIR/repo"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"up to date"* ]]
}

@test "latest lookup fails (offline) → could not determine latest, still exits 0" {
  mk_copyin "$BATS_TEST_TMPDIR/repo" 1.5.0
  export GH_EXIT=1                                      # gh api fails → version-check prints unknown
  cd "$BATS_TEST_TMPDIR/repo"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"could not determine latest"* ]]
}

@test "plugin mode, manifest present but versionless → installed unknown, still prints latest + /plugin" {
  # A nonexistent GANPAN_PLUGIN_MANIFEST would fall through to the (always-present) script-
  # relative source manifest, so to exercise the "unknown installed" path we point it at a
  # manifest that exists but has no .version field.
  mkdir -p "$BATS_TEST_TMPDIR/empty"
  printf '{"name":"ganpan"}' > "$BATS_TEST_TMPDIR/noversion.json"
  export GANPAN_PLUGIN_MANIFEST="$BATS_TEST_TMPDIR/noversion.json"
  queue_response '{"version":"9.9.9"}'
  cd "$BATS_TEST_TMPDIR/empty"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"installed:"*"unknown"* ]]
  [[ "$output" == *"latest:"*"9.9.9"* ]]
  [[ "$output" == *"/plugin"* ]]
}

@test "copy-in: install.sh guidance names the repo root (not '.') and no fixed --target both" {
  # install.sh runs from a ganpan checkout and takes the target repo as its argument;
  # `.` would read as "this repo" — print the detected root, even from a subdirectory.
  mk_copyin "$BATS_TEST_TMPDIR/repo" 1.5.0
  mkdir -p "$BATS_TEST_TMPDIR/repo/sub"
  queue_response '{"version":"9.9.9"}'
  cd "$BATS_TEST_TMPDIR/repo"; root="$PWD"; cd sub
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"./install.sh \"$root\" --target <codex|claude|antigravity|both|all> --force"* ]]
  [[ "$output" == *"run from a ganpan checkout"* ]]
  [[ "$output" != *"install.sh . "* ]]
  [[ "$output" != *"--target both --force"* ]]
}

@test "copy-in: also prints the pinned npx update for engines installed via npx skills" {
  # A repo bootstrapped with `npx … init` has no install.sh of its own; it needs the npx form,
  # pinned to the latest version, keeping its own --target.
  mk_copyin "$BATS_TEST_TMPDIR/repo" 1.5.0
  queue_response '{"version":"9.9.9"}'
  cd "$BATS_TEST_TMPDIR/repo"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"npx -y github:Laeyoung/Ganpan#v9.9.9 init --force"* ]]
  [[ "$output" == *"--target"* ]]
}

@test "copy-in, latest unknown: npx guidance uses a vX.Y.Z placeholder, not v'unknown'" {
  mk_copyin "$BATS_TEST_TMPDIR/repo" 1.5.0
  export GH_EXIT=1                                    # gh api fails → latest unknown
  cd "$BATS_TEST_TMPDIR/repo"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"npx -y github:Laeyoung/Ganpan#vX.Y.Z init --force"* ]]
  [[ "$output" != *"#vunknown"* ]]
}
