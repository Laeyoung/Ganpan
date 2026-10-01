#!/usr/bin/env bats
# tests/release.bats — scripts/release.sh guards, dry-run, tag+push, push-failure recovery.
# Every test runs in a scratch repo whose `origin` is a local bare repo — never GitHub.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  RELEASE="$REPO_ROOT/scripts/release.sh"
  BARE="$BATS_TEST_TMPDIR/remote.git"
  WORK="$BATS_TEST_TMPDIR/work"
  make_release_repo 1.2.3
}

# make_release_repo <version> — minimal repo carrying the three version sources, pushed to $BARE.
make_release_repo() {
  local v="$1"
  git init -q --bare "$BARE"
  git -C "$BARE" symbolic-ref HEAD refs/heads/main
  git init -q "$WORK"
  git -C "$WORK" symbolic-ref HEAD refs/heads/main
  git -C "$WORK" config user.email "t@example.com"
  git -C "$WORK" config user.name "t"
  git -C "$WORK" config commit.gpgsign false
  git -C "$WORK" config tag.gpgsign false
  mkdir -p "$WORK/plugins/orchestration/.claude-plugin" "$WORK/plugins/ganpan-codex/skills/ganpan-setup" "$WORK/bin"
  printf '{"version":"%s"}\n' "$v" > "$WORK/plugins/orchestration/.claude-plugin/plugin.json"
  printf '{"version":"%s"}\n' "$v" > "$WORK/package.json"
  printf 'npx -y github:Laeyoung/Ganpan#v%s init\n' "$v" > "$WORK/plugins/ganpan-codex/skills/ganpan-setup/SKILL.md"
  printf '#!/usr/bin/env node\n' > "$WORK/bin/ganpan.mjs"
  chmod +x "$WORK/bin/ganpan.mjs"
  git -C "$WORK" add -A
  git -C "$WORK" commit -q -m init
  git -C "$WORK" remote add origin "file://$BARE"
  git -C "$WORK" push -q origin main
}

# release <args…> — run release.sh inside $WORK, accepting the file:// test remote.
release() { cd "$WORK" && GANPAN_RELEASE_REMOTE_RE='^file://' bash "$RELEASE" "$@"; }
# release_canonical <args…> — same, but with the real (default) canonical-remote pattern.
release_canonical() { cd "$WORK" && env -u GANPAN_RELEASE_REMOTE_RE bash "$RELEASE" "$@"; }

no_tags_anywhere() {
  [ -z "$(git -C "$WORK" tag -l)" ]
  [ -z "$(git ls-remote --tags "$BARE")" ]
}

@test "release.sh is tracked-able (not gitignored) and shellcheck-clean" {
  run git -C "$REPO_ROOT" check-ignore -q scripts/release.sh
  [ "$status" -ne 0 ]
  run shellcheck "$RELEASE"
  [ "$status" -eq 0 ]
}

@test "rejects a non-SemVer version" {
  run release 1.2
  [ "$status" -eq 1 ]
  [[ "$output" == *"version must be X.Y.Z"* ]]
  no_tags_anywhere
}

@test "missing version or unknown flag is a usage error (exit 2)" {
  run release
  [ "$status" -eq 2 ]
  run release --bogus 1.2.3
  [ "$status" -eq 2 ]
}

@test "rejects a version that does not match plugin.json" {
  run release 9.9.9
  [ "$status" -eq 1 ]
  [[ "$output" == *"plugin.json is '1.2.3', expected 9.9.9"* ]]
  no_tags_anywhere
}

@test "rejects when package.json or the ganpan-setup pin disagree" {
  printf '{"version":"1.2.2"}\n' > "$WORK/package.json"
  git -C "$WORK" commit -qam drift && git -C "$WORK" push -q origin main
  run release 1.2.3
  [ "$status" -eq 1 ]
  [[ "$output" == *"package.json is '1.2.2', expected 1.2.3"* ]]
  printf '{"version":"1.2.3"}\n' > "$WORK/package.json"
  printf 'npx -y github:Laeyoung/Ganpan#v1.2.0 init\n' > "$WORK/plugins/ganpan-codex/skills/ganpan-setup/SKILL.md"
  git -C "$WORK" commit -qam drift2 && git -C "$WORK" push -q origin main
  run release 1.2.3
  [ "$status" -eq 1 ]
  [[ "$output" == *"ganpan-setup pin is '1.2.0', expected 1.2.3"* ]]
  no_tags_anywhere
}

@test "rejects a dirty working tree" {
  touch "$WORK/stray"
  run release 1.2.3
  [ "$status" -eq 1 ]
  [[ "$output" == *"working tree is not clean"* ]]
  no_tags_anywhere
}

@test "rejects a non-main branch" {
  git -C "$WORK" checkout -q -b feature
  run release 1.2.3
  [ "$status" -eq 1 ]
  [[ "$output" == *"must be on main (on 'feature')"* ]]
  no_tags_anywhere
}

@test "rejects an unpushed local main commit (HEAD != remote/main)" {
  git -C "$WORK" commit -q --allow-empty -m unpushed
  run release 1.2.3
  [ "$status" -eq 1 ]
  [[ "$output" == *"HEAD is not origin/main"* ]]
  no_tags_anywhere
}

@test "rejects a non-canonical remote with the default pattern" {
  run release_canonical 1.2.3
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not Laeyoung/Ganpan"* ]]
  no_tags_anywhere
}

@test "rejects an unknown --remote" {
  run release --remote nope 1.2.3
  [ "$status" -eq 1 ]
  [[ "$output" == *"no remote named 'nope'"* ]]
}

@test "rejects a tag that already exists locally" {
  git -C "$WORK" tag v1.2.3
  run release 1.2.3
  [ "$status" -eq 1 ]
  [[ "$output" == *"tag v1.2.3 already exists locally"* ]]
  [ -z "$(git ls-remote --tags "$BARE")" ]
}

@test "rejects a tag that already exists on the remote" {
  git -C "$WORK" tag v1.2.3 && git -C "$WORK" push -q origin v1.2.3 && git -C "$WORK" tag -d v1.2.3 >/dev/null
  run release 1.2.3
  [ "$status" -eq 1 ]
  [[ "$output" == *"tag v1.2.3 already exists on origin"* ]]
  [ -z "$(git -C "$WORK" tag -l)" ]
}

@test "rejects bin/ganpan.mjs not tracked as 100755, without chmod-ing it" {
  git -C "$WORK" update-index --chmod=-x bin/ganpan.mjs
  chmod -x "$WORK/bin/ganpan.mjs"
  git -C "$WORK" commit -qm "drop x" && git -C "$WORK" push -q origin main
  run release 1.2.3
  [ "$status" -eq 1 ]
  [[ "$output" == *"bin/ganpan.mjs is tracked as '100644', expected 100755"* ]]
  [ ! -x "$WORK/bin/ganpan.mjs" ]
  no_tags_anywhere
}

@test "--dry-run passes all guards, prints the commands, creates no tag" {
  run release --dry-run 1.2.3
  [ "$status" -eq 0 ]
  [[ "$output" == *'git tag -a v1.2.3 -m "ganpan v1.2.3"'* ]]
  [[ "$output" == *"git push origin v1.2.3"* ]]
  no_tags_anywhere
}

@test "real run creates the annotated tag locally and on the remote" {
  run release 1.2.3
  [ "$status" -eq 0 ]
  [ "$(git -C "$WORK" cat-file -t v1.2.3)" = "tag" ]
  run git ls-remote --tags "$BARE" refs/tags/v1.2.3
  [ -n "$output" ]
}

@test "--remote selects another remote" {
  git -C "$WORK" remote rename origin upstream
  run release --remote upstream 1.2.3
  [ "$status" -eq 0 ]
  run git ls-remote --tags "$BARE" refs/tags/v1.2.3
  [ -n "$output" ]
}

@test "push failure prints the git tag -d recovery command and exits 1" {
  printf '#!/bin/sh\nexit 1\n' > "$BARE/hooks/pre-receive"
  chmod +x "$BARE/hooks/pre-receive"
  run release 1.2.3
  [ "$status" -eq 1 ]
  [[ "$output" == *"git tag -d v1.2.3"* ]]
  [ -z "$(git ls-remote --tags "$BARE")" ]
}

@test "canonical-remote guard accepts SSH host aliases (git@github.com-<alias>:Laeyoung/Ganpan.git)" {
  # Maintainers with several GitHub accounts use ~/.ssh/config host aliases; the guard must
  # still recognise the canonical repo. GIT_SSH_COMMAND=false makes the later fetch fail
  # instantly and offline — we only assert the remote guard itself passed.
  git -C "$WORK" remote set-url origin "git@github.com-personal.invalid:Laeyoung/Ganpan.git"
  cd "$WORK"
  run env -u GANPAN_RELEASE_REMOTE_RE GIT_SSH_COMMAND=false bash "$RELEASE" --dry-run 1.2.3
  [ "$status" -eq 1 ]
  [[ "$output" != *"is not Laeyoung/Ganpan"* ]]
  [[ "$output" == *"git fetch origin main failed"* ]]
}

@test "canonical-remote guard still rejects a fork behind an SSH host alias" {
  git -C "$WORK" remote set-url origin "git@github.com-personal.invalid:someone/Ganpan.git"
  cd "$WORK"
  run env -u GANPAN_RELEASE_REMOTE_RE GIT_SSH_COMMAND=false bash "$RELEASE" --dry-run 1.2.3
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not Laeyoung/Ganpan"* ]]
}
