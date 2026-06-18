#!/usr/bin/env bash
# install.sh — install the GitHub-native orchestration toolkit into a target repo.
#
# Usage:
#   ./install.sh <target-repo-path>
#
# Copies the portable toolkit (scripts, lane commands, labels, issue template,
# setup docs) into <target-repo-path>. Repo-specific files are handled safely:
#   - .claude/orchestration.json : copied as a template only if absent (never clobbered).
#   - CLAUDE.md                  : created if absent; otherwise the repo-conventions
#                                  block is appended once (guarded by a sentinel).
#
# After running, edit <target>/.claude/orchestration.json (repo, bot) and follow
# the printed next steps (see <target>/docs/SETUP.md).

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$SRC/plugins/orchestration"
VERSION=$(jq -r '.version' "$PLUGIN/.claude-plugin/plugin.json")
SENTINEL_TOKEN="ganpan-orchestration: v$VERSION"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '  %s\n' "$*"; }

# --- args ---------------------------------------------------------------------
TARGET=""
FORCE=""
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//;/^$/d'; exit 0 ;;
    -*) die "unknown flag: $arg" ;;
    *) if [ -z "${TARGET:-}" ]; then TARGET="$arg"; else die "unexpected arg: $arg"; fi ;;
  esac
done
[ -n "$TARGET" ] || die "usage: ./install.sh <target-repo-path>"
[ -d "$TARGET" ] || die "target is not a directory: $TARGET"
TARGET="$(cd "$TARGET" && pwd)"
[ "$TARGET" = "$SRC" ] && die "target must differ from the toolkit source ($SRC)"
[ -d "$TARGET/.git" ] || printf 'warning: %s has no .git — sure this is a repo root?\n' "$TARGET" >&2

echo "Installing orchestration toolkit"
echo "  from: $SRC"
echo "  into: $TARGET"
echo

# --- 1. assets (plain "if absent" guard; not sentinel-stamped) ----------------
echo "Copying files:"
mkdir -p "$TARGET/scripts/orchestration" "$TARGET/.claude/commands" "$TARGET/.github/ISSUE_TEMPLATE"
[ -f "$TARGET/.github/labels.yml" ]             || cp "$PLUGIN/assets/labels.yml" "$TARGET/.github/labels.yml"
[ -f "$TARGET/.github/ISSUE_TEMPLATE/task.yml" ] || cp "$PLUGIN/assets/task.yml" "$TARGET/.github/ISSUE_TEMPLATE/task.yml"
[ -f "$TARGET/.claude/orchestration.json" ]     || cp "$PLUGIN/assets/orchestration.json" "$TARGET/.claude/orchestration.json"
info ".github/labels.yml, .github/ISSUE_TEMPLATE/task.yml, .claude/orchestration.json (if absent)"

# --- sentinel helpers ---------------------------------------------------------
# stamp <file> — append the version sentinel as the last line, in the right comment syntax.
stamp() {
  local dest="$1"
  sed -i '' "\|$SENTINEL_TOKEN|d" "$dest" 2>/dev/null || true   # drop any prior sentinel (| delimiter: robust to any version string)
  case "$dest" in
    *.md) printf '\n<!-- %s -->\n' "$SENTINEL_TOKEN" >> "$dest" ;;
    *)    printf '\n# %s\n'        "$SENTINEL_TOKEN" >> "$dest" ;;
  esac
}
# needs_write <file> — decide whether to (re)write a destination before copying.
needs_write() {
  local dest="$1" cur
  [ ! -f "$dest" ] && return 0                                 # absent → write
  [ -n "$FORCE" ] && return 0                                  # --force → overwrite
  cur=$(grep -Fm1 "$SENTINEL_TOKEN" "$dest" || true)
  [ -n "$cur" ] && return 1                                    # same version sentinel present → skip
  grep -q 'ganpan-orchestration:' "$dest" && return 0          # different version → overwrite
  echo "warn: $dest has no sentinel (user-owned); skipping (use --force)"; return 1
}

# --- 2. engine scripts --------------------------------------------------------
for src in "$PLUGIN"/scripts/orchestration/*.sh; do
  dest="$TARGET/scripts/orchestration/$(basename "$src")"
  needs_write "$dest" && { cp "$src" "$dest"; chmod +x "$dest"; stamp "$dest"; }
done
info "scripts/orchestration/*.sh"

# --- 3. lane commands (rewrite \${CLAUDE_PLUGIN_ROOT}/ -> ./ between copy and stamp; orch-setup.md excluded) ---
for name in work-issue triage review-queue qa-check; do
  src="$PLUGIN/commands/$name.md"; dest="$TARGET/.claude/commands/$name.md"
  # shellcheck disable=SC2016  # ${CLAUDE_PLUGIN_ROOT} must not expand — it's a literal to strip
  needs_write "$dest" && { cp "$src" "$dest"; sed -i '' 's|\${CLAUDE_PLUGIN_ROOT}/|./|g' "$dest"; stamp "$dest"; }
done
info ".claude/commands/{work-issue,triage,review-queue,qa-check}.md"

# --- 4. CLAUDE.md (create or append conventions once) -------------------------
echo
echo "Conventions (CLAUDE.md):"
SENTINEL="<!-- orchestration-conventions -->"
DST_CLAUDE="$TARGET/CLAUDE.md"
if [ ! -f "$DST_CLAUDE" ]; then
  { printf '%s\n' "$SENTINEL"; cat "$PLUGIN/assets/CLAUDE.md"; } > "$DST_CLAUDE"
  info "CLAUDE.md created"
elif grep -qF "$SENTINEL" "$DST_CLAUDE"; then
  info "CLAUDE.md already has the conventions block — skipped"
else
  { printf '\n%s\n' "$SENTINEL"; cat "$PLUGIN/assets/CLAUDE.md"; } >> "$DST_CLAUDE"
  info "CLAUDE.md exists — appended repo-conventions block"
fi

# --- next steps ---------------------------------------------------------------
cat <<EOF

Done. Next steps (details in $TARGET/docs/SETUP.md):

  1. Edit .claude/orchestration.json   → set "repo" and "bot"
  2. Bot account + fine-grained PAT    → export GH_TOKEN=..., add bot as collaborator
  3. Bootstrap labels:
       cd "$TARGET" && scripts/orchestration/bootstrap-labels.sh .github/labels.yml
  4. Branch protection on main         → require 1 human review; bot is NOT admin
  5. Run lanes:  /loop /work-issue · /loop 10m /triage · /loop 5m /review-queue · /qa-check
EOF
