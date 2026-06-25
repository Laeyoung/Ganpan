#!/usr/bin/env bash
# version-check.sh <installed-version> — throttled check for a newer ganpan release.
#
# Read-only and strictly NON-INTERACTIVE: it prints a one-line status and never prompts.
# Prompting here would break an unattended `/loop` (the issue's own constraint), so lanes call
# this only to surface a notice; deciding to update and running the plugin manager is the
# user's action. Throttled to roughly once per VERSION_CHECK_INTERVAL_DAYS (default 3) via a
# per-user stamp file, so it stays quiet across frequent loop ticks.
#
# stdout (exactly one):
#   skip                                  checked recently → no network call this run
#   current                               installed == latest (or installed is newer)
#   update-available: <installed> -> <latest>
#   unknown                               could not determine latest (offline / API error)
# exit 0 always — a version check must never fail a lane.
set -euo pipefail
installed="${1:?installed version required}"
repo="${GANPAN_SOURCE_REPO:-Laeyoung/Ganpan}"
days="${VERSION_CHECK_INTERVAL_DAYS:-3}"
state_dir="${GANPAN_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/ganpan}"
stamp="$state_dir/version-check.epoch"

now=$(date -u +%s)

# Throttle: if the last check was within the interval, do nothing (no network call).
if [ -f "$stamp" ]; then
  last=$(cat "$stamp" 2>/dev/null || echo 0)
  case "$last" in (*[!0-9]*|'') last=0 ;; esac
  if [ "$(( now - last ))" -lt "$(( days * 86400 ))" ]; then
    echo "skip"; exit 0
  fi
fi

# Due for a check: record the attempt now so the next run is throttled regardless of outcome
# (a transient offline blip must not turn into per-tick API hammering inside a loop).
mkdir -p "$state_dir" 2>/dev/null || true
echo "$now" > "$stamp" 2>/dev/null || true

# Latest version = .version of plugin.json on the source repo's main branch.
latest=$(gh api "repos/$repo/contents/plugins/orchestration/.claude-plugin/plugin.json?ref=main" \
  -H "Accept: application/vnd.github.raw" 2>/dev/null | jq -r '.version' 2>/dev/null) || true
if [ -z "$latest" ] || [ "$latest" = "null" ]; then
  echo "unknown"; exit 0
fi

# Update available only when latest is strictly newer (sort -V == version order); never flag a
# downgrade if the local checkout happens to be ahead of the published release.
if [ "$installed" != "$latest" ] && [ "$(printf '%s\n%s\n' "$installed" "$latest" | sort -V | tail -1)" = "$latest" ]; then
  echo "update-available: $installed -> $latest"
else
  echo "current"
fi
