#!/usr/bin/env bash
# project-check.sh — read-only diagnostic for the GitHub Projects (v2) status-sync config.
# Verifies the configured board is reachable as config.bot and its status field carries the
# option names the lanes emit. Run from the target repo root. READ-ONLY: mutates nothing.
#
# REQUIRED below = the exact values the lanes pass to project_sync (work-issue*/review-queue/
# qa-check). If a lane's status value ever changes, update BOTH the lane and this list.
#
# exit 0: not configured (number null) OR fully valid.   exit 1: configured but broken.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$DIR/lib.sh"
load_config || exit 1

REQUIRED=("In Progress" "In Review" "QA" "Done")

if [ "$PROJECT_NUMBER" = "null" ]; then
  echo "ganpan project-check: project.number is null → status sync is OFF (no-op). Valid state."
  echo "  Keep project.statusField in the config even when disabled — load_config requires it."
  exit 0
fi

owner="${REPO%%/*}"
if ! gh project view "$PROJECT_NUMBER" --owner "$owner" --format json >/dev/null 2>&1; then
  echo "ganpan project-check: FAIL — cannot access project #$PROJECT_NUMBER as '$BOT' (owner '$owner')."
  echo "  Likely: wrong project.number, the PAT lacks Projects access, or the board is owned by a"
  echo "  different org/user than the repo (owner is derived from config.repo)."
  exit 1
fi

fl=$(gh project field-list "$PROJECT_NUMBER" --owner "$owner" --format json 2>/dev/null) || {
  echo "ganpan project-check: FAIL — could not list fields for project #$PROJECT_NUMBER."; exit 1; }

nmatch=$(printf '%s' "$fl" | jq --arg n "$PROJECT_STATUS_FIELD" '[.fields[] | select(.name==$n)] | length' 2>/dev/null || echo 0)
if [ "${nmatch:-0}" -eq 0 ]; then
  echo "ganpan project-check: FAIL — no field named '$PROJECT_STATUS_FIELD' on project #$PROJECT_NUMBER."
  echo "  Use the built-in 'Status' field, or set project.statusField to your field's exact name."
  exit 1
fi
if [ "$nmatch" -gt 1 ]; then
  echo "ganpan project-check: FAIL — more than one field is named '$PROJECT_STATUS_FIELD'; field names must be unique (use the built-in Status field)."
  exit 1
fi

have=$(printf '%s' "$fl" | jq -r --arg n "$PROJECT_STATUS_FIELD" '.fields[] | select(.name==$n) | .options[].name' 2>/dev/null)
missing=()
for want in "${REQUIRED[@]}"; do
  printf '%s\n' "$have" | grep -qxF "$want" || missing+=("$want")
done
if [ "${#missing[@]}" -gt 0 ]; then
  echo "ganpan project-check: FAIL — field '$PROJECT_STATUS_FIELD' is missing required option(s): ${missing[*]}"
  echo "  The lanes set these exact values; add them as options: ${REQUIRED[*]}"
  exit 1
fi

echo "ganpan project-check: OK — project #$PROJECT_NUMBER, field '$PROJECT_STATUS_FIELD' has all required options (${REQUIRED[*]})."
echo "  Reminder: issues must be added to the board as items (enable the board's auto-add workflow) for sync to take effect."
exit 0
