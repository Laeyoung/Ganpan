#!/usr/bin/env bash
# update-info.sh — advisory: detect install mode, show installed vs latest ganpan
# version, and print the exact per-mode update steps. READ-ONLY: never mutates the
# repo, never runs the updater/plugin-manager. exit 0 always (an advisory must not fail).
#
# stdout: a human-readable advisory block. stderr: diagnostics only.
set -uo pipefail   # NOT -e: a failed lookup must degrade to "unknown", not abort.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SLUG="${GANPAN_SOURCE_REPO:-Laeyoung/Ganpan}"

# --- install mode + installed version ---
# copy-in iff the local engine lib.sh carries the install sentinel (not mere file
# existence — avoids a false positive for an unrelated ./scripts/orchestration dir).
installed=""
if [ -f "./scripts/orchestration/lib.sh" ] && grep -q 'ganpan-orchestration:' "./scripts/orchestration/lib.sh" 2>/dev/null; then
  mode="copy-in"
  installed="$(grep -o 'ganpan-orchestration: v[0-9][0-9.]*' "./scripts/orchestration/lib.sh" | head -1 | sed 's/.*v//')"
else
  mode="plugin"
  # Resolve the plugin manifest script-relative: update-info.sh lives at
  # <plugin-root>/scripts/orchestration/, so the manifest is two levels up. This is
  # robust without any env var (a plugin install always ships the script inside the
  # plugin). GANPAN_PLUGIN_MANIFEST is a test/override hook. We deliberately do NOT
  # reference ${CLAUDE_PLUGIN_ROOT} — it is redundant with the script-relative path,
  # and the install path-drift guard forbids that path token in copied scripts.
  manifest=""
  if [ -n "${GANPAN_PLUGIN_MANIFEST:-}" ] && [ -f "${GANPAN_PLUGIN_MANIFEST}" ]; then
    manifest="$GANPAN_PLUGIN_MANIFEST"
  elif [ -f "$DIR/../../.claude-plugin/plugin.json" ]; then
    manifest="$DIR/../../.claude-plugin/plugin.json"
  fi
  if [ -n "$manifest" ]; then
    installed="$(jq -r '.version // empty' "$manifest" 2>/dev/null)"
  fi
fi
[ -n "${installed:-}" ] || installed="unknown"

# --- latest version via version-check.sh, in an isolated throwaway state dir so the
# lanes' shared throttle stamp is never overwritten; days=0 forces a fresh check. ---
state="$(mktemp -d 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/ganpan-update.$$")"
mkdir -p "$state" 2>/dev/null || true
probe="$installed"; [ "$probe" = "unknown" ] && probe="0.0.0"   # 0.0.0 < any real release → "update-available: 0.0.0 -> <latest>" so we can read <latest>
vc="$(VERSION_CHECK_INTERVAL_DAYS=0 GANPAN_STATE_DIR="$state" GANPAN_SOURCE_REPO="$SLUG" \
      bash "$DIR/version-check.sh" "$probe" 2>/dev/null)" || vc="unknown"
rm -rf "$state" 2>/dev/null || true

case "$vc" in
  "update-available: "*) latest="${vc##*-> }"; status="update available" ;;
  current)
    if [ "$installed" = "unknown" ]; then
      # installed unknown ⇒ probe was the synthetic 0.0.0; a `current` verdict here means
      # the lookup couldn't give us a real latest to show. Don't claim "up to date".
      latest="unknown"; status="could not determine latest"
    else
      latest="$installed"; status="up to date"
    fi ;;
  *)                     latest="unknown";    status="could not determine latest" ;;
esac

# --- per-mode guidance ---
if [ "$mode" = "copy-in" ]; then
  guidance="  ./install.sh . --target both --force      # re-run from your repo root (use your actual target path)"
else
  guidance='  Run /plugin, then update "ganpan@laeyoung" from the marketplace manager.'
fi

# --- advisory (stdout) ---
cat <<EOF
ganpan update info
  mode:      $mode
  installed: $installed
  latest:    $latest
  status:    $status

To update (run this yourself — /ganpan:update never changes your repo):
$guidance
EOF
exit 0
