# Reviewer lane: post review results on the PR, keep the Issue lean

> Status: proposal (awaiting review). Target: `/ganpan:review-queue` (Reviewer lane).

## Context / problem

When `/ganpan:review-queue` reviews an in-review PR, the human-readable review
result (e.g. "Reviewer 검토 결과 차단 결함 없음 — README.md …") lands on the **Issue**,
embedded inside the `merge-requested:` marker body. We want the review result on
the **PR**, with the Issue getting only a mention.

### Investigation findings

- The lane has **always** posted every routing marker via `gh issue comment`.
  There is no git history of a PR→Issue change, and **no `gh pr comment` /
  `gh pr review` anywhere** in the repo. Step A's "leave inline review comments"
  is an un-automated instruction that posts nothing to the PR — so the only place
  review prose ever appeared was the Issue marker body.
- **Hard constraint — markers must stay on the Issue.** Lifecycle markers
  (`merge-requested:`, `rework-requested:`, `decision-requested:`,
  `decision-resolved:`, `merge-resolved:`, `decision-clarify:`,
  `followup-created:`, `cap-exceeded:`) drive the cross-tick state machine:
  - `bot_marker_pending` (`scripts/orchestration/lib.sh`) reads
    `gh issue view --json comments`.
  - `trusted-answers.sh:25` computes its window cutoff from Issue comments (`icmts`).

  Moving the markers off the Issue breaks gate detection and the trusted-answer
  window. So markers stay; only the narrative moves.
- **Safe to post bot prose on the PR.** `trusted-answers.sh:32` drops all
  bot-authored comments from *both* issue and PR, so a bot review comment on the
  PR is never miscollected as a human "answer."

### Decision (scope)

Per review: **summaries and rework reasons move to the PR; decision gates stay on
the Issue.** Decision-gate markers (`decision-requested:` / `decision-clarify:`)
are where humans answer, so they remain on the Issue.

## Approach: "marker stays lean on the Issue, narrative moves to the PR"

Split each affected routing action into a PR comment (the review result) + a lean
Issue marker (state token + PR mention).

### 1. `plugins/orchestration/commands/review-queue.md`

**Step A (lines 26–28)** — make PR posting explicit:
> Read the PR diff and post your review narrative **to the PR**
> (`gh pr comment "$PR" --body "…"`, plus inline review comments where useful).
> Never embed review prose in the Issue markers. Decide whether **you** find a
> blocking defect … *(rest unchanged)*.

**R-A — rework (line 82)** — reasons to PR, lean Issue marker:
```bash
gh pr comment "$PR" --body "<rework 사유 상세>"   # 리뷰 결과는 PR에
gh issue comment "$N" --body "rework-requested: 변경 요청 — 상세는 PR #$PR" --repo "$REPO"
```
The other R-A lines (`decision-resolved: superseded-by-rework`,
`merge-resolved: superseded-by-rework`) are pure state tokens with no prose —
leave as-is on the Issue.

**R-D — request human merge (lines 141–143)** — summary to PR, lean marker:
```bash
if [ "$(printf '%s' "$VIEW" | bot_marker_pending "merge-requested:" "merge-resolved:")" != "yes" ]; then
  gh pr comment "$PR" --body "<리뷰 요약: 차단 결함 없음 근거 / minor 관찰 등>"   # 리뷰 결과는 PR에
  gh issue comment "$N" --body "merge-requested: 사람 리뷰어 승인·머지 요청 (자동 머지 아님) — 리뷰 상세는 PR #$PR" --repo "$REPO"
fi
```

**Minor observations (line 153)** — retarget from Issue marker to PR:
> Minor non-blocking observations … are appended to the **PR review comment**, not gated.

**R-B / decision-gate (lines 99–110): unchanged** — `decision-requested:` and
`decision-clarify:` stay on the Issue (humans answer there).

### 2. Canonical reference — edit BOTH copies identically

`tests/codex-skills.bats:39–41` runs `cmp -s` between the two, so they must stay
byte-identical:
- `plugins/orchestration/references/lanes/review-queue.md`
- `plugins/ganpan-codex/skills/ganpan-review-queue/references/review-queue.md`

Prose changes:
- Step 2: "Review each PR diff; post your review summary and inline comments **to the PR**."
- Step 3 (rework): "post the rework reason **to the PR**, and a lean bot-authored
  `rework-requested:` Issue comment that mentions the PR; then move
  `status:in-review` → `status:in-progress`. Keep the bot assignee and worktree."
- Step 4 (merge): "post the review summary **on the PR** asking a human reviewer to
  approve and merge; leave a lean mention on the Issue."

### 3. Version bump (CLAUDE.md requires it)

Bump `plugins/orchestration/.claude-plugin/plugin.json`. New behavior (PR comments)
→ **minor** bump. Working tree `main` is at `1.1.0`; open PRs #21/#22/#24/#25 already
touch this version line, so reconcile at merge time (next free minor, e.g. `1.2.0`,
rebasing if a concurrent PR lands first).

### Not in scope
- No script changes (`lib.sh`, `trusted-answers.sh`, `decision-resolve.sh`,
  `followup-dedup.sh`) — the state machine is unchanged.
- `assets/CLAUDE.md` — no reviewer-posting rules there.
- Installed copies under `.claude/commands/` and repo-root `references/lanes/` are
  copy-in artifacts regenerated by `install.sh`; not the source of truth. Re-run the
  copy-in / reinstall to make the change live in this self-hosted checkout before it
  ships via the marketplace.

## Verification

1. `bats tests/*.bats tests/orchestration/*.bats` — must stay green; `codex-skills.bats`
   `cmp -s` catches a one-sided reference edit.
2. `jq . plugins/orchestration/.claude-plugin/plugin.json` — validate the version bump.
3. `shellcheck plugins/orchestration/scripts/orchestration/*.sh` — unchanged, sanity only.
4. Functional dogfood: run `/ganpan:review-queue` against an in-review issue and confirm
   - the review summary appears as a **PR comment**,
   - the Issue shows only `merge-requested: … — 리뷰 상세는 PR #<PR>` (lean mention),
   - a subsequent tick is still a correct no-op (`bot_marker_pending` finds the marker
     on the Issue → no duplicate post).
