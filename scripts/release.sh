#!/usr/bin/env bash
# release.sh — tag a shipped ganpan version so the pinned npx bootstrap resolves.
#
# Usage: scripts/release.sh [--dry-run] [--remote <name>] <X.Y.Z>
#
# The release itself is still the merge to main (docs/RELEASE_PLAYBOOK.md). This adds
# the immutable vX.Y.Z tag that ganpan-setup's `npx -y github:Laeyoung/Ganpan#vX.Y.Z`
# resolves. Every guard is read-only; nothing is created until all pass. It never edits
# versions — bump plugin.json, package.json and the ganpan-setup pin in the feature PR.
#
# GANPAN_RELEASE_REMOTE_RE overrides the canonical-remote pattern (tests only; set it
# per invocation, never export it globally).

set -euo pipefail

die() { printf 'release: %s\n' "$*" >&2; exit 1; }
usage_die() { printf 'release: %s\nusage: scripts/release.sh [--dry-run] [--remote <name>] <X.Y.Z>\n' "$*" >&2; exit 2; }

DRY_RUN=""
REMOTE="origin"
VERSION=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --remote)
      shift
      [ "$#" -gt 0 ] || usage_die "--remote requires a name"
      REMOTE="$1"
      ;;
    --remote=*) REMOTE="${1#--remote=}" ;;
    -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) usage_die "unknown flag: $1" ;;
    *) [ -z "$VERSION" ] || usage_die "unexpected arg: $1"; VERSION="$1" ;;
  esac
  shift
done
[ -n "$VERSION" ] || usage_die "a version is required"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version must be X.Y.Z (got '$VERSION')"
TAG="v$VERSION"
command -v jq >/dev/null 2>&1 || die "jq is required but not found on PATH"

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"
cd "$ROOT"

# --- guards (read-only) -------------------------------------------------------
branch="$(git rev-parse --abbrev-ref HEAD)"
[ "$branch" = "main" ] || die "must be on main (on '$branch')"
[ -z "$(git status --porcelain)" ] || die "working tree is not clean"

url="$(git remote get-url "$REMOTE" 2>/dev/null)" || die "no remote named '$REMOTE'"
# git@github.com-<alias>: covers ~/.ssh/config host aliases (multi-account setups); the alias
# segment allows no dots, so lookalike hosts like github.com.evil.example never match.
remote_re="${GANPAN_RELEASE_REMOTE_RE:-^(https://github\.com/|git@github\.com(-[A-Za-z0-9_-]+)?:|ssh://git@github\.com(-[A-Za-z0-9_-]+)?/)Laeyoung/Ganpan(\.git)?/?$}"
printf '%s\n' "$url" | grep -Eiq "$remote_re" \
  || die "remote '$REMOTE' ($url) is not Laeyoung/Ganpan — the pinned bootstrap resolves there; pass --remote <canonical>"

git fetch --quiet "$REMOTE" main || die "git fetch $REMOTE main failed"
[ "$(git rev-parse HEAD)" = "$(git rev-parse FETCH_HEAD)" ] \
  || die "HEAD is not $REMOTE/main — push or pull first; the tag must point at shipped code"

plugin_v="$(jq -r .version plugins/orchestration/.claude-plugin/plugin.json)" || die "cannot read plugin.json version"
package_v="$(jq -r .version package.json)" || die "cannot read package.json version"
pin_v="$(grep -oE 'github:Laeyoung/Ganpan#v[0-9]+\.[0-9]+\.[0-9]+' plugins/ganpan-codex/skills/ganpan-setup/SKILL.md | head -n1 | sed 's/.*#v//')" || true
[ "$plugin_v" = "$VERSION" ]  || die "plugin.json is '$plugin_v', expected $VERSION"
[ "$package_v" = "$VERSION" ] || die "package.json is '$package_v', expected $VERSION"
[ "$pin_v" = "$VERSION" ]     || die "ganpan-setup pin is '${pin_v:-missing}', expected $VERSION"

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then die "tag $TAG already exists locally"; fi
remote_tag="$(git ls-remote --tags "$REMOTE" "refs/tags/$TAG")" || die "git ls-remote $REMOTE failed"
[ -z "$remote_tag" ] || die "tag $TAG already exists on $REMOTE"

mode="$(git ls-files -s bin/ganpan.mjs | awk '{print $1}')"
[ "$mode" = "100755" ] \
  || die "bin/ganpan.mjs is tracked as '${mode:-untracked}', expected 100755 — run: git update-index --chmod=+x bin/ganpan.mjs, then commit"

# --- act ----------------------------------------------------------------------
if [ -n "$DRY_RUN" ]; then
  printf 'dry-run: all guards passed; would run:\n  git tag -a %s -m "ganpan %s"\n  git push %s %s\n' "$TAG" "$TAG" "$REMOTE" "$TAG"
  exit 0
fi

git tag -a "$TAG" -m "ganpan $TAG"
git push --quiet "$REMOTE" "$TAG" || die "push to $REMOTE failed; the local tag was kept — remove it with: git tag -d $TAG"
printf 'released %s -> %s\n' "$TAG" "$REMOTE"
