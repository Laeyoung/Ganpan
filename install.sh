#!/usr/bin/env bash
# install.sh — install the GitHub-native orchestration toolkit into a target repo.
#
# Usage:
#   ./install.sh <target-repo-path> [--target claude|codex|both] [--force]
#
# Copies the portable toolkit (scripts, lane commands, labels, issue template,
# setup docs) into <target-repo-path>. Repo-specific files are handled safely:
#   - .claude/orchestration.json or .ganpan/orchestration.json : copied as a
#     template only when no config exists (never clobbered).
#   - CLAUDE.md / AGENTS.md      : created if absent; otherwise the repo-conventions
#                                  block is appended once (guarded by a sentinel).
#
# After running, edit the printed config path (repo, bot) and follow the printed
# next steps (see <target>/docs/SETUP.md).

set -euo pipefail

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '  %s\n' "$*"; }

# sed_i <file> <sed-args…> — portable in-place edit. `sed -i ''` is BSD-only and
# breaks on GNU/Linux (it consumes '' as the script); install.sh ships to users
# who may be on Linux, so edit via a temp file instead.
sed_i() {
  local f="$1"; shift
  local t; t="$(mktemp)"
  if sed "$@" "$f" > "$t"; then mv "$t" "$f"; else rm -f "$t"; return 1; fi
}

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$SRC/plugins/orchestration"
CODEX_PLUGIN="$SRC/plugins/ganpan-codex"

# prerequisites (checked before any work; under `set -e` a missing jq or manifest
# would otherwise abort with a cryptic message)
command -v jq >/dev/null 2>&1 || die "jq is required but not found on PATH"
[ -f "$PLUGIN/.claude-plugin/plugin.json" ] \
  || die "plugin manifest not found: $PLUGIN/.claude-plugin/plugin.json — run install.sh from a ganpan checkout"
VERSION=$(jq -r '.version' "$PLUGIN/.claude-plugin/plugin.json")
SENTINEL_TOKEN="ganpan-orchestration: v$VERSION"

# --- args ---------------------------------------------------------------------
TARGET=""
FORCE=""
TARGET_MODE="claude"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --force) FORCE=1 ;;
    --target)
      shift
      [ "$#" -gt 0 ] || die "--target requires claude, codex, or both"
      TARGET_MODE="$1"
      ;;
    --target=*)
      TARGET_MODE="${1#--target=}"
      ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//;/^$/d'; exit 0 ;;
    -*) die "unknown flag: $1" ;;
    *) if [ -z "${TARGET:-}" ]; then TARGET="$1"; else die "unexpected arg: $1"; fi ;;
  esac
  shift
done
case "$TARGET_MODE" in
  claude|codex|both) ;;
  *) die "--target must be one of: claude, codex, both" ;;
esac
[ -n "$TARGET" ] || die "usage: ./install.sh <target-repo-path>"
[ -d "$TARGET" ] || die "target is not a directory: $TARGET"
TARGET="$(cd "$TARGET" && pwd)"
[ "$TARGET" = "$SRC" ] && die "target must differ from the toolkit source ($SRC)"
[ -d "$TARGET/.git" ] || printf 'warning: %s has no .git — sure this is a repo root?\n' "$TARGET" >&2

echo "Installing orchestration toolkit"
echo "  from: $SRC"
echo "  into: $TARGET"
echo "  target: $TARGET_MODE"
echo

wants_claude() { [ "$TARGET_MODE" = "claude" ] || [ "$TARGET_MODE" = "both" ]; }
wants_codex() { [ "$TARGET_MODE" = "codex" ] || [ "$TARGET_MODE" = "both" ]; }

# --- 1. assets (plain "if absent" guard; not sentinel-stamped) ----------------
echo "Copying files:"
mkdir -p "$TARGET/scripts/orchestration" "$TARGET/.github/ISSUE_TEMPLATE"
wants_claude && mkdir -p "$TARGET/.claude/commands"
[ -f "$TARGET/.github/labels.yml" ]             || cp "$PLUGIN/assets/labels.yml" "$TARGET/.github/labels.yml"
[ -f "$TARGET/.github/ISSUE_TEMPLATE/task.yml" ] || cp "$PLUGIN/assets/task.yml" "$TARGET/.github/ISSUE_TEMPLATE/task.yml"
if [ -f "$TARGET/.ganpan/orchestration.json" ] && [ -f "$TARGET/.claude/orchestration.json" ] \
  && ! cmp -s "$TARGET/.ganpan/orchestration.json" "$TARGET/.claude/orchestration.json"; then
  printf 'warning: both .ganpan/orchestration.json and .claude/orchestration.json exist and differ; .ganpan wins\n' >&2
fi
if [ ! -f "$TARGET/.ganpan/orchestration.json" ] && [ ! -f "$TARGET/.claude/orchestration.json" ]; then
  case "$TARGET_MODE" in
    claude)
      mkdir -p "$TARGET/.claude"
      cp "$PLUGIN/assets/orchestration.json" "$TARGET/.claude/orchestration.json"
      ;;
    codex|both)
      mkdir -p "$TARGET/.ganpan"
      cp "$PLUGIN/assets/orchestration.json" "$TARGET/.ganpan/orchestration.json"
      ;;
  esac
fi
SELECTED_CONFIG_PATH=""
if [ -f "$TARGET/.ganpan/orchestration.json" ]; then
  SELECTED_CONFIG_PATH=".ganpan/orchestration.json"
elif [ -f "$TARGET/.claude/orchestration.json" ]; then
  SELECTED_CONFIG_PATH=".claude/orchestration.json"
fi
LEGACY_CONFIG_FALLBACK=""
if wants_codex && [ "$SELECTED_CONFIG_PATH" = ".claude/orchestration.json" ]; then
  LEGACY_CONFIG_FALLBACK=1
fi
mkdir -p "$TARGET/docs"
[ -f "$TARGET/docs/SETUP.md" ]                  || cp "$SRC/docs/SETUP.md" "$TARGET/docs/SETUP.md"
info ".github/labels.yml, .github/ISSUE_TEMPLATE/task.yml, orchestration config, docs/SETUP.md (if absent)"
if [ -n "$LEGACY_CONFIG_FALLBACK" ]; then
  info "Using legacy .claude/orchestration.json as the selected config fallback"
  info "To migrate later, create .ganpan/orchestration.json deliberately"
fi

# --- sentinel helpers ---------------------------------------------------------
# stamp <file> — append the version sentinel as the last line, in the right comment syntax.
stamp() {
  local dest="$1" esc
  esc="${SENTINEL_TOKEN//./\\.}"          # escape the version's dots (only BRE metachar in the token) → fixed-string match
  sed_i "$dest" "\|$esc|d" || true        # drop any prior sentinel (| delimiter)
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
  [ -e "$src" ] || die "no engine scripts at $PLUGIN/scripts/orchestration/ — incomplete checkout?"
  dest="$TARGET/scripts/orchestration/$(basename "$src")"
  needs_write "$dest" && { cp "$src" "$dest"; stamp "$dest"; chmod +x "$dest"; }
done
info "scripts/orchestration/*.sh"

# --- 3. shared lane references ------------------------------------------------
mkdir -p "$TARGET/references/lanes"
for src in "$PLUGIN"/references/lanes/*.md; do
  [ -e "$src" ] || die "no lane references at $PLUGIN/references/lanes/ — incomplete checkout?"
  dest="$TARGET/references/lanes/$(basename "$src")"
  needs_write "$dest" && { cp "$src" "$dest"; stamp "$dest"; }
done
info "references/lanes/*.md"

# --- 4. lane commands (rewrite \${CLAUDE_PLUGIN_ROOT}/ -> ./ between copy and stamp; orch-setup.md excluded) ---
if wants_claude; then
  for name in work-issue work-issue-deep triage review-queue review-queue-deep qa-check run-all; do
    src="$PLUGIN/commands/$name.md"; dest="$TARGET/.claude/commands/$name.md"
    # shellcheck disable=SC2016  # ${CLAUDE_PLUGIN_ROOT} must not expand — it's a literal to strip
    needs_write "$dest" && { cp "$src" "$dest"; sed_i "$dest" 's|\${CLAUDE_PLUGIN_ROOT}/|./|g'; stamp "$dest"; }
  done
  info ".claude/commands/{work-issue,work-issue-deep,triage,review-queue,review-queue-deep,qa-check,run-all}.md"
fi

# --- 5. Codex skills ----------------------------------------------------------
if wants_codex; then
  [ -d "$CODEX_PLUGIN/skills" ] || die "Codex skill source not found: $CODEX_PLUGIN/skills"
  while IFS= read -r src; do
    rel="${src#"$CODEX_PLUGIN/skills/"}"
    dest="$TARGET/.agents/skills/$rel"
    mkdir -p "$(dirname "$dest")"
    needs_write "$dest" && { cp "$src" "$dest"; stamp "$dest"; }
  done < <(find "$CODEX_PLUGIN/skills" -type f | sort)
  info ".agents/skills/ganpan-*"
fi

# --- 6. CLAUDE.md / AGENTS.md (create or append conventions once) -------------
# Note: CLAUDE.md is merge-managed (append-once under its own sentinel), NOT
# version-stamped — `--force` deliberately does not rewrite it (spec §3.5); a
# user editing conventions text upstream merges them manually.
echo
if wants_claude; then
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
fi

if wants_codex; then
  echo "Conventions (AGENTS.md):"
  CODEX_SENTINEL="<!-- ganpan-codex-conventions -->"
  DST_AGENTS="$TARGET/AGENTS.md"
  if [ ! -f "$DST_AGENTS" ]; then
    { printf '%s\n' "$CODEX_SENTINEL"; cat "$CODEX_PLUGIN/assets/AGENTS.md"; } > "$DST_AGENTS"
    info "AGENTS.md created"
  elif grep -qF "$CODEX_SENTINEL" "$DST_AGENTS"; then
    info "AGENTS.md already has the conventions block — skipped"
  else
    { printf '\n%s\n' "$CODEX_SENTINEL"; cat "$CODEX_PLUGIN/assets/AGENTS.md"; } >> "$DST_AGENTS"
    info "AGENTS.md exists — appended repo-conventions block"
  fi
fi

# --- next steps ---------------------------------------------------------------
case "$TARGET_MODE" in
  claude) CONFIG_PATH=".claude/orchestration.json"; LANE_HINT="/loop /ganpan:work-issue · /loop 10m /ganpan:triage · /loop 5m /ganpan:review-queue · /ganpan:qa-check · (all at once) /loop 20m /ganpan:run-all" ;;
  codex|both) CONFIG_PATH=".ganpan/orchestration.json"; LANE_HINT="Use Codex skills: ganpan-work-issue · ganpan-triage · ganpan-review-queue · ganpan-qa-check" ;;
esac
if [ -n "$SELECTED_CONFIG_PATH" ]; then
  CONFIG_PATH="$SELECTED_CONFIG_PATH"
fi
cat <<EOF

Done. Next steps (details in $TARGET/docs/SETUP.md):

  1. Edit $CONFIG_PATH   → set "repo" and "bot"
  2. Bot account + fine-grained PAT    → export GH_TOKEN=..., add bot as collaborator
  3. Bootstrap labels:
       cd "$TARGET" && scripts/orchestration/bootstrap-labels.sh .github/labels.yml
  4. Branch protection on main         → require 1 human review; bot is NOT admin
  5. Run lanes:  $LANE_HINT
EOF
