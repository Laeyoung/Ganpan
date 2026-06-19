#!/usr/bin/env bash
# bootstrap-labels.sh <labels.yml> — idempotently create status labels.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$DIR/lib.sh"
load_config
# Intentionally NOT gated with require_bot_actor (spec §4.3): runs during
# /orch-setup when the bot PAT may not exist yet, and labels are repo config,
# not bot runtime activity. Do not add the actor gate here.

labels_file="${1:-$DIR/../../assets/labels.yml}"
count=$(yq -o=json '. | length' "$labels_file")
for i in $(seq 0 $((count - 1))); do
  name=$(yq -r ".[$i].name" "$labels_file")
  color=$(yq -r ".[$i].color" "$labels_file")
  desc=$(yq -r ".[$i].description" "$labels_file")
  # --force makes it idempotent: create or update.
  gh label create "$name" --color "$color" --description "$desc" --force --repo "$REPO"
  log INFO "label ensured: $name"
done
