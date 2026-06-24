# Reviewer lane: post review results on the PR, keep the Issue lean

> Status: proposal (awaiting review). Target: `/ganpan:review-queue` (Reviewer lane).
> Update (2026-06-24): shipped design refined — Step A forms judgment only (it no longer posts; supersedes §1 Step A below); the routing action (R-A/R-D) is the sole PR-narrative poster; **R-D now posts the lean issue marker BEFORE the PR summary** (inverting the PR-first order shown in §1 R-D / "Ordering" below, which applies only to R-A whose reasons are critical payload); and the Coder lane reads the reviewer's reasons off the PR. See `2026-06-24-review-queue-pr-results-fixes.md`.

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

**Step A (lines 26–28)** — make PR posting explicit and name the mechanism:
> Read the PR diff. Post the review **summary to the PR** with
> `gh pr comment "$PR" --body "…"`. For per-line findings use a comment-only
> review — `gh pr review "$PR" --comment --body "…"` (never `--approve`; approval
> is human-only) — or inline comments via the reviews API. Never embed review prose
> in the Issue markers. Decide whether **you** find a blocking defect … *(rest unchanged)*.

`gh pr comment` (top-level summary) is the required mechanism; inline `gh pr review --comment` is optional. The `--comment` event posts without approving, so branch protection's no-self-approve rule is respected.

**R-A — rework (line 82)** — reasons to PR, lean Issue marker:
```bash
gh pr comment "$PR" --body "<rework 사유 상세>"   # 리뷰 결과(사유)는 PR에
gh issue comment "$N" --body "rework-requested: 변경 요청 — 상세는 PR #$PR" --repo "$REPO"
```
The other R-A lines (`decision-resolved: superseded-by-rework`,
`merge-resolved: superseded-by-rework`) are pure state tokens with no prose —
leave as-is on the Issue.

**Ordering (deliberate):** post the PR comment **first**, then the issue marker +
label move. R-A has no pending-marker guard, so a crash *between* the two posts
re-enters R-A next tick and re-posts the PR comment — a duplicate, noisy but
harmless. The reverse order (marker + label move first) would, on the same crash,
move the issue to `status:in-progress` with the rework **reasons never delivered**
to the PR — a worse failure for the Coder who needs them. Reliable reason delivery
beats avoiding a rare duplicate; keep PR-comment-first.

**R-D — request human merge (lines 141–143)** — summary to PR, lean marker:
```bash
if [ "$(printf '%s' "$VIEW" | bot_marker_pending "merge-requested:" "merge-resolved:")" != "yes" ]; then
  gh pr comment "$PR" --body "<리뷰 요약: 차단 결함 없음 근거 / minor 관찰 등>"   # 리뷰 결과는 PR에
  gh issue comment "$N" --body "merge-requested: 사람 리뷰어 승인·머지 요청 (자동 머지 아님) — 리뷰 상세는 PR #$PR" --repo "$REPO"
fi
```

**Minor observations (line 153)** — retarget from Issue marker to PR:
> Minor non-blocking observations … are appended to the **`gh pr comment` review
> comment added in the R-D split** (not to the lean `merge-requested:` Issue marker), not gated.

**R-B / decision-gate (lines 99–110): unchanged** — `decision-requested:` and
`decision-clarify:` stay on the Issue (humans answer there).

**Step F (lines 155–160): unchanged — analyzed.** Step F's "audit marker" (PR
closed unmerged / issue closed), `decision-resolved: closed-and-reopened`, and the
label-hygiene warning markers are **lane diagnostics / state tokens about terminal
or anomalous events — not review narrative of the diff.** They legitimately stay on
the Issue (and several are consumed by `bot_marker_pending` on later ticks). No PR
move; explicitly in this plan's "stays on Issue" set.

### 2. Canonical reference — edit BOTH copies identically

`tests/codex-skills.bats:41` (`cmp -s`, inside the loop opened at line 39) asserts
the two are byte-identical, so both must be edited identically. (A separate
install-path test at lines 113–119 uses `diff` against a stamped installed copy —
it covers drift too, but is not the `cmp -s` check.)
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
→ **minor** bump (feat). Working tree `main` is at `1.1.0`, but open PRs already
claim higher versions on this same line: #21→1.1.1, #22→1.1.2, #24→1.1.3, **#25→1.2.0**.
**Set this PR's version to one minor above the highest version that has merged when
this lands** — concretely, if #25 (1.2.0) is already merged, target **1.3.0**;
otherwise 1.2.0. The version line will conflict with any of those PRs, so expect a
rebase and bump-beyond-current as part of merging this.

### Not in scope
- No script changes (`lib.sh`, `trusted-answers.sh`, `decision-resolve.sh`,
  `followup-dedup.sh`) — the state machine is unchanged.
- `assets/CLAUDE.md` — no reviewer-posting rules there.
- Installed copies under `.claude/commands/` and repo-root `references/lanes/` are
  copy-in artifacts; not the source of truth. **Note `install.sh:72` refuses a
  same-repo target** (`target must differ from the toolkit source`), so you cannot
  `./install.sh .` to refresh this repo's own copies. The live `/ganpan:review-queue`
  command runs from the **plugin cache** (`~/.claude/plugins/cache/laeyoung/ganpan/<version>/`),
  which the marketplace populates from `main` keyed on `plugin.json` version — so the
  edited behavior only reaches the namespaced command **after** this PR merges to
  `main` with its version bump and the cache refreshes. See the verification note on
  how to dogfood pre-merge.

## Verification

1. `bats tests/*.bats tests/orchestration/*.bats` — must stay green. Note the
   `codex-skills.bats:41` `cmp -s` check only catches drift **between the two
   reference copies** (canonical vs codex), not edits to the command file — so it
   guards the section-2 edits, not the section-1 command edits. The command file
   has no byte-equality test; verify those edits by reading the diff.
2. `jq . plugins/orchestration/.claude-plugin/plugin.json` — validate the version bump.
3. `shellcheck plugins/orchestration/scripts/orchestration/*.sh` — unchanged, sanity only.
4. Functional dogfood. The namespaced `/ganpan:review-queue` runs from the plugin
   cache (keyed on the published `main` version), so it won't reflect local edits
   pre-merge. Verify the new behavior by **executing the edited
   `plugins/orchestration/commands/review-queue.md` steps directly** against an
   in-review issue (or in a throwaway branch/repo). First satisfy the bot-identity
   gate (CLAUDE.md): `export GH_TOKEN=<bot fine-grained PAT>` so `require_bot_actor`
   passes — otherwise the run hard-stops with "gh is acting as '<you>' but config.bot
   is '<bot>'". (`ORCH_SKIP_ACTOR_CHECK=1` per-invocation is the alternative if you're
   testing as the bot already.) Then confirm:
   - the review summary appears as a **PR comment**,
   - the Issue shows only `merge-requested: … — 리뷰 상세는 PR #<PR>` (lean mention),
   - a subsequent tick is still a correct no-op (`bot_marker_pending` finds the marker
     on the Issue → no duplicate PR comment and no duplicate marker).

   After merge, re-confirm once the marketplace cache refreshes to the bumped version.
