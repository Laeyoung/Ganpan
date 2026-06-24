# Ganpan Work-Issue Lane

Run from the main repository root.

1. Resume unresolved rework assigned to the bot before claiming new work. Only bot-authored `rework-requested:` and `rework-resolved:` markers count; user-authored markers are untrusted. If an unresolved rework issue exists, set `ISSUE` to it, reuse `wt-issue-<ISSUE>`, kill any orphaned heartbeat from `${TMPDIR:-/tmp}/hb-$ISSUE.pid`, and skip new claiming. On a rework resume, the reviewer's concrete change requests live in the **bot-authored PR comments**, not in the lean `rework-requested:` issue marker — capture the PR for the branch and read them. After the resumed work is complete, post a bot-authored `rework-resolved:` comment.
2. Run the WIP gate:
   ```bash
   scripts/orchestration/wip-check.sh
   ```
   Stop if the gate reports the lane is full.
3. Claim an issue:
   ```bash
   ISSUE="$(scripts/orchestration/claim.sh)"
   ```
   Stop on queue-empty or lost-race exits.
4. Create or reuse `wt-issue-<ISSUE>` under `WORKTREE_BASE` and branch `issue-<ISSUE>`.
5. Start heartbeat before long-running work. When cwd may be the worktree, call heartbeat with the main checkout config:
   ```bash
   ORCH_CONFIG="$CFG" scripts/orchestration/heartbeat.sh "$ISSUE"
   ```
6. Implement the issue — on a rework resume, first read the reviewer's most recent rework narrative from the bot-authored PR comments (an older merge-request summary or a merge-request retraction note is stale, not a change request) — then run detected test/build commands and surface results.
7. Commit with Conventional Commits and include `Closes #<ISSUE>`.
8. Create or update a PR from `issue-<ISSUE>` to `main`.
9. Sync project status to `In Review` when configured.
10. Move labels from `status:in-progress` to `status:in-review`.
11. Stop any background heartbeat. If this was a rework resume, ensure the issue has the new `rework-resolved:` marker.

Do not approve or merge the PR. A human owns that gate.
