#!/usr/bin/env bash
# labels-check.sh [labels.yml] — read-only drift detector for the status labels.
# Compares the label set DEFINED in labels.yml against the labels that actually EXIST
# on config.repo, and names the ones that are missing. READ-ONLY: mutates nothing —
# creating the missing labels is bootstrap-labels.sh's job (idempotent, --force).
#
# Why this exists (issue #81): labels are bootstrapped ONCE at /ganpan:orch-setup. A repo
# installed before a label was added to assets/labels.yml never receives it on upgrade, and
# the gap only surfaces when a lane tries to apply the label and the write fails mid-run.
# `status:needs-decision` (added with the reviewer decision gate) hit exactly that.
#
# exit 0: every defined label exists.   exit 1: drift, or the check was inconclusive.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$DIR/lib.sh"
load_config || {
  # /ganpan:update runs this as an advisory step and may be invoked from a repo that
  # was never set up; say so on stdout (load_config only logs to stderr) rather than
  # exiting silently with a bare non-zero.
  echo "ganpan labels-check: FAIL — no usable ganpan config (see the error above). Run /ganpan:orch-setup first."
  exit 1
}
# Intentionally NOT gated with require_bot_actor — same rationale as bootstrap-labels.sh:
# labels are repo config, and this may run at setup time before the bot PAT exists. It is
# also read-only, so there is no write to attribute to the wrong actor.

# Resolve the label definitions: explicit arg → the installed copy in the target repo →
# the plugin's own asset (script-relative, so it works from any cwd in a plugin install).
labels_file="${1:-}"
if [ -z "$labels_file" ]; then
  if [ -f ".github/labels.yml" ]; then
    labels_file=".github/labels.yml"
  elif [ -f "$DIR/../../assets/labels.yml" ]; then
    labels_file="$DIR/../../assets/labels.yml"
  fi
fi
if [ -z "$labels_file" ] || [ ! -f "$labels_file" ]; then
  echo "ganpan labels-check: FAIL — no labels.yml found (looked for an explicit argument, ./.github/labels.yml, and the plugin asset)."
  echo "  Run /ganpan:orch-setup from the repo root, or pass the path explicitly."
  exit 1
fi

want=$(yq -r '.[].name' "$labels_file" 2>/dev/null)
if [ -z "$want" ]; then
  echo "ganpan labels-check: FAIL — could not read any label names from $labels_file (malformed YAML, or yq is missing)."
  exit 1
fi

# --limit 1000: the default page size is 30, which would silently report labels as
# "missing" on any repo carrying more than a page of them.
have=$(gh label list --repo "$REPO" --limit 1000 --json name --jq '.[].name' 2>/dev/null) || {
  echo "ganpan labels-check: FAIL — could not list labels on $REPO (API error, or the token lacks repo read access)."
  echo "  Inconclusive, not proof of drift — re-run once the API is reachable."
  exit 1
}

missing=()
while IFS= read -r name; do
  [ -n "$name" ] || continue
  printf '%s\n' "$have" | grep -qxF "$name" || missing+=("$name")
done <<< "$want"

total=$(printf '%s\n' "$want" | grep -c .)
if [ "${#missing[@]}" -eq 0 ]; then
  echo "ganpan labels-check: OK — all $total label(s) defined in $labels_file exist on $REPO."
  exit 0
fi

echo "ganpan labels-check: DRIFT — ${#missing[@]} of $total label(s) defined in $labels_file are missing on $REPO: ${missing[*]}"
echo "  A lane that tries to apply a missing label fails mid-run (e.g. the Reviewer's"
echo "  human-decision gate needs status:needs-decision). Labels are bootstrapped once at"
echo "  setup, so an install predating a new label never receives it."
echo "  Fix — re-run the bootstrap. It is idempotent (gh label create --force = create-or-update)"
echo "  and never deletes or renames anything, so running it on an up-to-date repo is a no-op:"
echo "    scripts/orchestration/bootstrap-labels.sh .github/labels.yml"
exit 1
