#!/usr/bin/env bats

# conflict-resolve.sh exercises real git (no gh), so each test builds a throwaway repo with a
# bare "origin" remote, a main branch, and a diverged issue branch.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../plugins/orchestration/scripts/orchestration/conflict-resolve.sh"
  REMOTE="$BATS_TEST_TMPDIR/remote.git"
  WORK="$BATS_TEST_TMPDIR/work"
  git init -q --bare "$REMOTE"
  git clone -q "$REMOTE" "$WORK"
  cd "$WORK"
  git config user.email t@example.com
  git config user.name tester
  git config commit.gpgsign false
  # main: two files
  printf 'a1\na2\na3\n' > a.txt
  printf 'b1\nb2\nb3\n' > b.txt
  git add .; git commit -qm init
  git branch -M main
  git push -q origin main
  git checkout -q -b issue-1
}

# advance origin/main with a commit applied on a fresh checkout of main, then return to issue-1
advance_main() {  # $1 = file, $2 = new contents
  ( cd "$BATS_TEST_TMPDIR" && git clone -q "$REMOTE" m && cd m \
    && git config user.email t@example.com && git config user.name tester \
    && git checkout -q main && printf '%s' "$2" > "$1" && git add . && git commit -qm "main change" && git push -q origin main )
  git fetch -q origin main
}

@test "base already an ancestor → up-to-date, no merge" {
  # issue-1 has not diverged and origin/main has not advanced
  run bash "$SCRIPT" main
  [ "$status" -eq 0 ]
  [ "$output" = "up-to-date" ]
}

@test "non-overlapping changes → resolved (clean auto-merge, committed)" {
  # issue-1 edits b.txt; main edits a.txt → no overlap
  printf 'b1\nb2\nb3\nb4-feature\n' > b.txt; git add .; git commit -qm feat
  advance_main a.txt $'a1\na2\na3\na4-main\n'
  run bash "$SCRIPT" main
  [ "$status" -eq 0 ]
  [ "$output" = "resolved" ]
  # both changes present, tree clean, merge committed
  grep -q 'a4-main' a.txt
  grep -q 'b4-feature' b.txt
  [ -z "$(git status --porcelain)" ]
  ! git rev-parse -q --verify MERGE_HEAD   # no merge in progress
}

@test "overlapping changes → conflict, merge aborted, tree clean (no markers)" {
  # both edit the SAME line of a.txt
  printf 'a1\na2-FEATURE\na3\n' > a.txt; git add .; git commit -qm feat
  advance_main a.txt $'a1\na2-MAIN\na3\n'
  run bash "$SCRIPT" main
  [ "$status" -eq 0 ]
  [ "$output" = "conflict" ]
  # aborted: working tree clean, no conflict markers committed or staged
  [ -z "$(git status --porcelain)" ]
  ! git rev-parse -q --verify MERGE_HEAD
  ! grep -q '<<<<<<<' a.txt
  grep -q 'a2-FEATURE' a.txt   # our side intact (merge rolled back)
}

@test "fetch failure → exit 2" {
  git remote set-url origin "$BATS_TEST_TMPDIR/does-not-exist.git"
  run bash "$SCRIPT" main
  [ "$status" -eq 2 ]
  [ "$output" = "error" ]
}
