#!/usr/bin/env bash
# detect-test-cmd.sh <test|build|lint> — print the command (config override or auto-detect).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$DIR/lib.sh"
load_config

kind="${1:?kind required: test|build|lint}"
cfg="${ORCH_CONFIG:-./.claude/orchestration.json}"

# 1. config override
override=$(jq -r --arg k "$kind" '.commands[$k] // empty' "$cfg")
[ -n "$override" ] && { echo "$override"; exit 0; }

# 2. package.json scripts.<kind>
if [ -f package.json ] && jq -e --arg k "$kind" '.scripts[$k] // empty' package.json >/dev/null 2>&1; then
  echo "npm $kind"; exit 0
fi
# 3. Makefile <kind>: target
if [ -f Makefile ] && grep -qE "^${kind}:" Makefile; then
  echo "make $kind"; exit 0
fi
# 4. python: pytest for test
if [ "$kind" = "test" ] && { [ -f pyproject.toml ] || [ -f pytest.ini ] || [ -f tox.ini ]; }; then
  echo "pytest"; exit 0
fi

log WARN "no $kind command detected"
echo ""   # empty → caller (QA) treats as blocked reason
exit 0
