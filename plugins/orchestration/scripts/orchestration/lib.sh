#!/usr/bin/env bash
# lib.sh — shared config + helpers. Source this; do not execute directly.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPT_DIR

log() { printf '[%s] %s\n' "$1" "${*:2}" >&2; }

resolve_config_path() {
  local root="${1:-.}"
  if [ -n "${ORCH_CONFIG:-}" ]; then
    printf '%s\n' "$ORCH_CONFIG"
    return 0
  fi

  if [ -f "$root/.ganpan/orchestration.json" ]; then
    printf '%s\n' "$root/.ganpan/orchestration.json"
    return 0
  fi

  if [ -f "$root/.claude/orchestration.json" ]; then
    printf '%s\n' "$root/.claude/orchestration.json"
    return 0
  fi

  printf '%s\n' "$root/.ganpan/orchestration.json"
}

load_config() {
  local cfg
  cfg="$(resolve_config_path)"
  if [ ! -f "$cfg" ]; then log ERROR "config not found: $cfg"; return 1; fi
  ORCH_CONFIG_PATH="$cfg"
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
  REVIEWER_AUTO_MERGE=$(jq -r '.reviewer.autoMerge // false' "$cfg")
  # Optional branch strategy. Absent block ⇒ "main" (backward compatible: feature PRs
  # target main, the legacy single-branch behavior). branchStrategy.integrationBranch
  # is the branch Coder-lane feature PRs integrate into (e.g. "develop" for git-flow).
  INTEGRATION_BRANCH=$(jq -r '.branchStrategy.integrationBranch // "main"' "$cfg")
  # $RANDOM tail guarantees distinct tokens even when hostname+pid collide across
  # containers (e.g. pid 1 in identical images), preventing a tie-break double-claim.
  WORKER_ID="${BOT}-$(hostname -s 2>/dev/null || echo host)-$$-${RANDOM}"
  export ORCH_CONFIG_PATH REPO BOT CANDIDATE_N WIP_LIMIT RECLAIM_TIMEOUT_MIN HEARTBEAT_MIN WORKTREE_BASE PROJECT_NUMBER PROJECT_STATUS_FIELD WORKER_ID REVIEWER_PERM_THRESHOLD REVIEWER_ALLOWLIST FOLLOWUP_CAP REVIEWER_AUTO_MERGE INTEGRATION_BRANCH
}

# require_bot_actor — assert the gh actor matches config.bot before any write.
# Escape hatch: ORCH_SKIP_ACTOR_CHECK=1 (e.g. CI where the bot PAT *is* the actor).
# Must be set per-invocation, never exported globally.
#
# A *lookup* failure (gh exits non-zero, or returns an empty login) is treated as
# transient — a one-off API blip or rate-limit shouldn't hard-stop the whole lane —
# so the probe is retried a few times before giving up. A *resolved* identity that
# does not match config.bot is NOT transient: it is retried zero times and fails
# immediately, since retrying a genuine mismatch could only mask a wrong actor.
# Override counts via ORCH_ACTOR_RETRIES / ORCH_ACTOR_RETRY_DELAY (seconds).
require_bot_actor() {
  [ "${ORCH_SKIP_ACTOR_CHECK:-}" = "1" ] && { log WARN "ORCH_SKIP_ACTOR_CHECK=1 — actor identity gate bypassed"; return 0; }
  # jq -er in load_config rejects null but NOT an empty JSON string, so config.bot=""
  # yields BOT=""; without this guard an empty actor would compare equal and pass.
  [ -n "$BOT" ] || { log ERROR "config.bot is empty"; return 1; }
  local retries="${ORCH_ACTOR_RETRIES:-2}" delay="${ORCH_ACTOR_RETRY_DELAY:-2}"
  local attempt=0 actor rc
  while :; do
    # `if actor=$(...)` keeps the non-zero exit from tripping `set -e` (a bare
    # `actor=$(...); rc=$?` would exit the script before rc is read) and captures
    # the lookup's success/failure as $rc for the transient-vs-resolved decision.
    if actor=$(gh api user --jq .login 2>/dev/null); then rc=0; else rc=$?; fi
    if [ "$rc" -eq 0 ] && [ -n "$actor" ]; then
      break  # lookup resolved — fall through to the (non-retried) match check
    fi
    if [ "$attempt" -ge "$retries" ]; then
      if [ "$rc" -ne 0 ]; then
        log ERROR "cannot resolve gh identity (gh authenticated?)"
      else
        log ERROR "gh api user returned empty login"
      fi
      return 1
    fi
    attempt=$((attempt + 1))
    log WARN "gh identity lookup failed (transient); retry $attempt/$retries"
    sleep "$delay"
  done
  if [ "$actor" != "$BOT" ]; then
    log ERROR "gh is acting as '$actor' but config.bot is '$BOT'."
    log ERROR "Export the bot PAT first:  export GH_TOKEN=github_pat_...  (HTTPS, not ssh)"
    return 1
  fi
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
  gh project item-edit --id "$item_id" --project-id "$proj_id" --field-id "$field_id" --single-select-option-id "$opt_id" >/dev/null
}

# perm_rank <permission> — comparable rank; unknown/none == -1 (never trusted).
perm_rank() {
  case "$1" in
    admin) echo 4 ;; maintain) echo 3 ;; write) echo 2 ;;
    triage) echo 1 ;; read|pull) echo 0 ;; *) echo -1 ;;
  esac
}

# is_trusted <login> — tri-state. exit 0 trusted | 1 definitively untrusted | 2 lookup
# failed (transient API error). Allowlist OR permission threshold.
# Queried at call time (== conversion time) so a user who lost access is no longer trusted.
# Security callers using `if is_trusted` still fail closed (1 and 2 are both non-zero).
# The distinct 2 lets a collector (trusted-answers.sh) tell a transient failure apart from
# a real "untrusted" and skip the tick instead of silently dropping an answer — note an
# ordinary non-collaborator returns 200/"none" (rank -1 → return 1 below), while a 404 (the
# account was deleted or renamed, so it can never be a collaborator) is also a definitive
# "untrusted" → return 1, NOT 2: otherwise one comment from a vanished account would 404 on
# every tick and the rc-2 abort would stall trusted-answers.sh's decision gate indefinitely.
is_trusted() {
  local user="$1"
  if [ -n "${REVIEWER_ALLOWLIST:-}" ] && printf '%s\n' "$REVIEWER_ALLOWLIST" | grep -qxF -- "$user"; then
    return 0
  fi
  local perm have need out rc
  # Capture stderr (2>&1) so a 404 can be told apart from a transient failure: gh prints
  # "HTTP 404" on a missing account → definitively untrusted (1); any other failure → 2.
  out=$(gh api "repos/$REPO/collaborators/$user/permission" --jq '.permission' 2>&1) && rc=0 || rc=$?
  if [ "$rc" -ne 0 ]; then
    case "$out" in
      *"HTTP 404"*) return 1 ;;
      *) return 2 ;;
    esac
  fi
  perm="$out"
  have=$(perm_rank "$perm")
  need=$(perm_rank "$REVIEWER_PERM_THRESHOLD")
  # Fail closed: a mistyped threshold (need<0, perm_rank returns -1) or an unknown
  # permission (have<0) must reject — never fall open to read/pull. need<0 checked first
  # so a config typo cannot grant trust to a low-privilege collaborator.
  [ "$need" -ge 0 ] && [ "$have" -ge 0 ] && [ "$have" -ge "$need" ]
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
