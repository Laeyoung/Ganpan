#!/usr/bin/env bash
# conflict-resolve.sh [<base-branch>] — conservatively bring the current branch up to date
# with base, resolving ONLY the conflicts git's own 3-way merge handles cleanly.
#
# Run from inside the PR branch's worktree (the issue-<n> branch checked out). It fetches the
# base and attempts `git merge`. A clean auto-merge (no overlapping hunks) is committed; ANY
# real textual conflict is ABORTED and left for a human — the agent must never hand-resolve
# conflict markers or commit a half-merged tree (that is where bad merges come from). Merging
# the PR stays a human action; this only updates the branch.
#
# stdout (the caller branches on this):
#   up-to-date   base is already an ancestor → nothing to do
#   resolved     base merged in cleanly (committed) → caller re-runs tests/build and pushes
#   conflict     a real conflict (or non-clean merge) → merge aborted; caller escalates to a
#                human via PR comment and does NOT force a resolution
# exit 0 for all three; exit 2 on a fetch/setup error (caller treats as transient).
set -euo pipefail
base="${1:-main}"
remote="${ORCH_GIT_REMOTE:-origin}"

git fetch "$remote" "$base" >/dev/null 2>&1 || { echo "error"; exit 2; }

# Branch already contains the base tip → up to date, no merge needed.
if git merge-base --is-ancestor "$remote/$base" HEAD >/dev/null 2>&1; then
  echo "up-to-date"; exit 0
fi

# Attempt the merge. git auto-resolves non-overlapping changes and commits; on any conflict it
# exits non-zero and leaves an in-progress merge, which we abort so the tree is never left with
# conflict markers or a partial commit.
if git merge --no-edit "$remote/$base" >/dev/null 2>&1; then
  echo "resolved"; exit 0
fi
git merge --abort >/dev/null 2>&1 || true
echo "conflict"; exit 0
