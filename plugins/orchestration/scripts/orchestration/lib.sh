#!/usr/bin/env bash
# lib.sh — shared config + helpers. Source this; do not execute directly.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPT_DIR

log() { printf '[%s] %s\n' "$1" "${*:2}" >&2; }

load_config() {
  local cfg="${ORCH_CONFIG:-./.claude/orchestration.json}"
  if [ ! -f "$cfg" ]; then log ERROR "config not found: $cfg"; return 1; fi
  REPO=$(jq -er '.repo' "$cfg")                       || { log ERROR "config.repo missing"; return 1; }
  BOT=$(jq -er '.bot' "$cfg")                         || { log ERROR "config.bot missing"; return 1; }
  CANDIDATE_N=$(jq -er '.candidateN' "$cfg")          || { log ERROR "config.candidateN missing"; return 1; }
  WIP_LIMIT=$(jq -er '.wipLimit' "$cfg")              || { log ERROR "config.wipLimit missing"; return 1; }
  RECLAIM_TIMEOUT_MIN=$(jq -er '.reclaim.timeoutMinutes' "$cfg") || { log ERROR "reclaim.timeoutMinutes missing"; return 1; }
  HEARTBEAT_MIN=$(jq -er '.reclaim.heartbeatMinutes' "$cfg")     || { log ERROR "reclaim.heartbeatMinutes missing"; return 1; }
  WORKTREE_BASE=$(jq -er '.worktreeBaseDir' "$cfg")   || { log ERROR "worktreeBaseDir missing"; return 1; }
  PROJECT_NUMBER=$(jq -r '.project.number // "null"' "$cfg")
  PROJECT_STATUS_FIELD=$(jq -er '.project.statusField' "$cfg") || { log ERROR "project.statusField missing"; return 1; }
  REVIEWER_PERM_THRESHOLD=$(jq -r '.reviewer.permissionThreshold // "write"' "$cfg")
  REVIEWER_ALLOWLIST=$(jq -r '.reviewer.allowlist[]? // empty' "$cfg")
  FOLLOWUP_CAP=$(jq -r '.reviewer.followupIssueCapPerPR // 3' "$cfg")
  # $RANDOM tail guarantees distinct tokens even when hostname+pid collide across
  # containers (e.g. pid 1 in identical images), preventing a tie-break double-claim.
  WORKER_ID="${BOT}-$(hostname -s 2>/dev/null || echo host)-$$-${RANDOM}"
  export REPO BOT CANDIDATE_N WIP_LIMIT RECLAIM_TIMEOUT_MIN HEARTBEAT_MIN WORKTREE_BASE PROJECT_NUMBER PROJECT_STATUS_FIELD WORKER_ID REVIEWER_PERM_THRESHOLD REVIEWER_ALLOWLIST FOLLOWUP_CAP
}

# Token sorts by time first (fixed-width ISO8601), then worker id → lexicographic-min == earliest.
claim_token() { printf '%sZ-%s' "$(date -u +%Y-%m-%dT%H:%M:%S)" "$WORKER_ID"; }

now_epoch() { date -u +%s; }

# GNU date first, BSD date fallback (macOS).
iso_to_epoch() {
  date -u -d "$1" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null
}

# project_sync <issue#> <statusValue> — no-op when PROJECT_NUMBER == "null".
project_sync() {
  local issue="$1" status="$2"
  [ "$PROJECT_NUMBER" = "null" ] && return 0
  local owner="${REPO%%/*}"
  local proj_id field_id opt_id item_id fl
  proj_id=$(gh project view "$PROJECT_NUMBER" --owner "$owner" --format json | jq -er '.id')
  fl=$(gh project field-list "$PROJECT_NUMBER" --owner "$owner" --format json)
  field_id=$(echo "$fl" | jq -er --arg n "$PROJECT_STATUS_FIELD" '.fields[] | select(.name==$n) | .id')
  opt_id=$(echo "$fl" | jq -er --arg n "$PROJECT_STATUS_FIELD" --arg v "$status" \
    '.fields[] | select(.name==$n) | .options[] | select(.name==$v) | .id')
  item_id=$(gh project item-list "$PROJECT_NUMBER" --owner "$owner" --format json \
    | jq -er --argjson num "$issue" '.items[] | select(.content.number==$num) | .id')
  gh project item-edit --id "$item_id" --project-id "$proj_id" --field-id "$field_id" --single-select-option-id "$opt_id"
}

# perm_rank <permission> — comparable rank; unknown/none == -1 (never trusted).
perm_rank() {
  case "$1" in
    admin) echo 4 ;; maintain) echo 3 ;; write) echo 2 ;;
    triage) echo 1 ;; read|pull) echo 0 ;; *) echo -1 ;;
  esac
}

# is_trusted <login> — exit 0 if trusted, 1 otherwise. Allowlist OR permission threshold.
# Queried at call time (== conversion time) so a user who lost access is no longer trusted.
is_trusted() {
  local user="$1"
  if [ -n "${REVIEWER_ALLOWLIST:-}" ] && printf '%s\n' "$REVIEWER_ALLOWLIST" | grep -qxF -- "$user"; then
    return 0
  fi
  local perm have need
  perm=$(gh api "repos/$REPO/collaborators/$user/permission" --jq '.permission' 2>/dev/null) || return 1
  have=$(perm_rank "$perm")
  need=$(perm_rank "$REVIEWER_PERM_THRESHOLD")
  [ "$have" -ge 0 ] && [ "$have" -ge "$need" ]
}

# bot_marker_pending <openPrefix> <resolvePrefix> — reads a {comments:[...]} JSON on
# stdin; prints "yes" if the LATEST bot marker matching either prefix is an open one.
bot_marker_pending() {
  local open="$1" resolve="$2"
  jq -r --arg b "$BOT" --arg o "$open" --arg r "$resolve" '
    [.comments[] | select(.author.login==$b and ((.body|startswith($o)) or (.body|startswith($r))))] as $m
    | if ($m|length)==0 then "no"
      else (if ($m[-1].body|startswith($o)) then "yes" else "no" end) end'
}
