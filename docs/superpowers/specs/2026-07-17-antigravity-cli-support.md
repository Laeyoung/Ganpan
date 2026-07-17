# Antigravity CLI (agy) support (Spec)

Issue: #74

## Problem

Ganpan installs into two agent runtimes today:

- **Claude Code** — as a marketplace plugin (`ganpan@laeyoung`) or via the
  copy-in path (`./install.sh <repo>`, `--target claude`), producing
  `.claude/commands/*.md` lane commands.
- **Codex** — via `./install.sh <repo> --target codex`, producing repo-local
  skills at `.agents/skills/ganpan-*/SKILL.md` plus an `AGENTS.md`
  conventions block.

Users of **Google Antigravity CLI (`agy`)** have no documented or supported
install path, so they cannot run the Triager/Coder/Reviewer/QA lanes from that
runtime (issue #74 acceptance criterion: "Antigravity CLI (agy)에서도 Claude
Code나 Codex처럼 ganpan을 설치하고 사용 가능").

## Research findings (2026-07-17)

Verified against Google's codelab and third-party writeups (the official docs
site is JS-rendered and not fetchable headlessly):

1. **Skill format — layout disputed between sources; we follow the codelab.**
   Google's own codelab demonstrates workspace skills at
   `.agents/skills/<skill-name>/SKILL.md` with YAML frontmatter carrying
   `name:` and `description:` — **byte-compatible with what ganpan's Codex
   target already ships** (same path, layout, frontmatter). The dev.to
   hands-on guide instead shows a *flat* file (`.agents/skills/lint.md` →
   `/lint`, no subdirectory/SKILL.md/frontmatter). We bet on the codelab (the
   primary, Google-authored source; the two layouts are also not mutually
   exclusive — agy may accept both), and AC9's smoke test is the only real
   check of which layout `agy` honors; if the directory form is not
   discovered, that surfaces there before release.
   (Sources: codelabs.developers.google.com/antigravity/how-to-create-agent-skills-for-antigravity-cli;
   dev.to/arindam_1729 hands-on guide)
2. **Invocation — mechanism contested between sources.** The codelab shows
   natural-language intent activation against the frontmatter `description`
   (with a permission prompt); the dev.to hands-on guide instead describes
   filename→slash-command mapping ("`.agents/skills/lint.md` becomes
   `/lint`"). We do not pick a winner: user-facing wording (SETUP.md, the
   next-steps hint) must mention **both** invocation styles ("ask for the
   lane by name, or try `/<skill-name>`"), and the AC9 smoke test resolves
   which one (or both) is real. `/skills` inside the `agy` TUI lists what was
   discovered — both sources agree on that.
3. **AGENTS.md.** `agy` reads a root `AGENTS.md` and prepends it to every
   prompt in that workspace — the same file the Codex target already
   creates/appends. (Source: dev.to/arindam_1729 hands-on guide)
4. **Global skill paths are unstable.** Sources disagree
   (`~/.gemini/antigravity-cli/skills/` vs `~/.gemini/skills/`; one author
   found the officially-documented path non-functional). We therefore target
   **workspace-level installs only** and stay out of the global-path business.
5. Extra files inside a skill directory (e.g. the Codex-specific
   `agents/openai.yaml`) are not part of agy's contract but nothing indicates
   they break discovery; the codelab only requires `SKILL.md`.

## Design

**Reframe the Codex payload as the shared "agents-skills" payload** consumed by
both Codex and Antigravity. Do **not** fork a `plugins/ganpan-antigravity/`
source tree — the payloads are identical, and a copy would rot (same reasoning
as `references/lanes/` being canonical).

`install.sh` changes:

- `--target` accepts **`claude | codex | antigravity | both | all`**.
  - `antigravity` installs exactly what `codex` installs today: engine
    scripts, `references/lanes/`, `.agents/skills/ganpan-*`,
    `.ganpan/orchestration.json` (if absent), `docs/SETUP.md` (if absent), and
    the `AGENTS.md` conventions block.
  - `both` keeps its current meaning (claude + codex) for back-compat; since
    the antigravity payload is identical to codex's, `both` already covers
    agy users on disk.
  - `all` = claude + codex + antigravity (today: same files as `both`; exists
    so the CLI surface stays honest if the payloads ever diverge).
- Internal predicate `wants_codex()` is joined by `wants_antigravity()`; the
  boolean-gated skills and AGENTS.md sections key on `wants_agents_payload()`
  (codex ∨ antigravity ∨ both ∨ all) so the copy loop stays single-sourced.
  (Config creation is path-selecting, not boolean — see the branch-point list
  below.)
- **Every `TARGET_MODE` branch point must gain arms for the new values** —
  the script runs `set -u`, so a missed arm is a fatal unbound-variable
  crash, not a silent skip:
  - The **arg-validation `case`** (lines ~65-68) is the front door: without
    an `antigravity|all` arm there, the script dies at "--target must be one
    of: claude, codex, both" before anything else runs. Both `die` usage
    strings (lines ~52 and ~67) update to the new value list.
  - `wants_claude()` (line ~81) must also match `all` (else `--target all`
    skips `.claude/commands`, CLAUDE.md, and the mkdir — violating AC3).
  - The config-creation `case` (lines ~95-105) stays a raw `case` on
    `TARGET_MODE` (it selects **which path** to create, not just whether) and
    gains an `antigravity|all` arm mirroring `codex|both` (else
    `.ganpan/orchestration.json` is never created for the new targets —
    violating AC1). `wants_agents_payload()` gates only the boolean-gated
    sections: the skills copy loop and the AGENTS.md block.
  - The final next-steps `case` (lines ~221-224) needs `antigravity)` and
    `all)` arms; with none matching, `LANE_HINT` stays unset and the closing
    heredoc dies with "unbound variable" **after** all file copies have
    happened. (`CONFIG_PATH` happens to be recovered by the existing
    `SELECTED_CONFIG_PATH` fallback at lines ~225-227 — incidental, not a
    substitute for adding the arms.) **`all)` arm content, pinned:** it
    mirrors `codex|both`'s `CONFIG_PATH` (`.ganpan/orchestration.json`) and
    its `LANE_HINT` is the union — the `/ganpan:*`-style Claude lane loop
    hints **plus** the agy/Codex skills line — since `all` installs both
    surfaces.
  - The `LEGACY_CONFIG_FALLBACK` check (line ~113) switches from
    `wants_codex` to `wants_agents_payload` — the legacy-config semantics
    follow the payload, not the runtime.
- The final **next-steps hint** becomes target-aware: for `antigravity` it
  says to run `agy` in the repo, check `/skills` for the `ganpan-*` skills,
  and invoke lanes by asking for them by name **or** via the
  `/<skill-name>` slash form (both styles quoted until AC9 settles which is
  real — see Research §2).
- **AC3 stdout semantics, decided:** `--target both` terminal output stays
  **byte-identical** to today — no additive lines. The "codex/both installs
  are already agy-compatible" message lives in the docs (SETUP.md/README),
  not in install.sh output; a stdout diff would weaken the regression guard
  for the most-used path.

Documentation (every place that enumerates targets or runtimes):

- `docs/SETUP.md`: add an Antigravity CLI subsection next to the Codex one
  (install command, `/skills` verification, invocation model). Note that
  `--target codex`/`both` installs are **already agy-compatible on disk**
  (identical payload) so existing Codex installs need no reinstall.
- `README.md`: mention Antigravity CLI as a supported runtime where Codex is
  mentioned, **and** add an Antigravity CLI skills row to the "지원 표면"
  table (it mirrors SETUP.md's Support matrix — both tables gain the row).
- Root `CLAUDE.md` (Layout section, "`--target claude|codex|both`"; also the
  Development section's "full test suite (includes codex-skills.bats)" note)
  and root `AGENTS.md` ("for Claude Code and Codex", the smoke-test block,
  and the Testing-Guidelines test-file-ownership line): update the target
  enumeration, runtime list, and test-suite mentions to include antigravity.
- `install.sh` line-5 usage comment: update alongside the `die` usage string.
- `docs/RELEASE_CHECKLIST.md` "deploy surfaces": add a 5th line —
  "Copy-in Antigravity (`./install.sh <target> --target antigravity`):
  installs `.agents/skills/ganpan-*` (covered by `tests/antigravity.bats`)" —
  and bump the section header's "ships four surfaces" to "five".
- `docs/RELEASE_PLAYBOOK.md`: add the matching "Copy-in Antigravity" row to
  the release-surfaces table, **and** extend the §7 manual-verification
  checklist's copy-in line ("and `--target codex` / `--target both`") to
  include `--target antigravity`.
- `docs/SETUP.md` "Support matrix" table (separate from the install
  subsection): add an Antigravity CLI skills row alongside the Codex
  repo-local skills row.
- `docs/CODEX_ADAPTER_RULES.md` and `docs/CODEX_RUNBOOK.md`: both enumerate
  `--target codex`/`both` install-time invariants (no-`.claude/commands`
  rule, smoke file-list, legacy-config fallback). CODEX_ADAPTER_RULES.md
  gains an antigravity-parity rule (the shared payload means every codex
  invariant holds for `--target antigravity` too); CODEX_RUNBOOK.md gets a
  one-line shared-payload note pointing agy users at the same runbook.
- `plugins/ganpan-codex/assets/AGENTS.md` **and**
  `plugins/ganpan-codex/skills/*/SKILL.md` bodies: audit for Codex-only
  phrasing and generalize where trivial (e.g. ganpan-setup's "Prefer
  `.ganpan/orchestration.json` for new Codex installs" → "for new installs").
  AGENTS.md itself was audited and is already runtime-neutral.
- `plugins/orchestration/references/lanes/setup.md` line 12 **and its Codex
  copy** `plugins/ganpan-codex/skills/ganpan-setup/references/setup.md`:
  "`AGENTS.md` for the Codex surface" → "`AGENTS.md` for the Codex and
  Antigravity surfaces" (the shared payload ships this reference to agy
  installs too).

Out of scope (YAGNI, recorded for the log):

- Global (`~/.gemini/...`) skill installation — path contract is unstable.
- An agy *plugin* (`agy plugin validate` flow) — workspace skills satisfy the
  issue's acceptance criterion; a plugin adds a second distribution channel
  with its own manifest to maintain.
- Renaming `plugins/ganpan-codex/` — it is the deployed runtime contract's
  source dir; renaming risks the same class of breakage as engine renames
  (CLAUDE.md "Never rename engine internals").

## Constraints

- **Never rename engine internals** — no changes to `scripts/orchestration/`,
  config filename, or the `ganpan-orchestration` sentinel.
- `install.sh` must keep the sentinel/`needs_write` semantics for every new
  copy path (idempotent re-runs, `--force` overwrite, user-owned skip).
- Existing invocations must not change behavior: bare `./install.sh <t>`
  (claude), `--target codex`, `--target both` produce byte-identical results
  to today.
- Shipped-artifact change ⇒ SemVer **minor** bump (feat) of
  `plugins/orchestration/.claude-plugin/plugin.json`.

## Acceptance criteria

- **AC1** `./install.sh <t> --target antigravity` installs
  `.agents/skills/ganpan-{triage,work-issue,review-queue,qa-check,setup,update}/SKILL.md`,
  engine scripts, lane references, `docs/SETUP.md` (if absent),
  `.ganpan/orchestration.json` (if absent), and the `AGENTS.md`
  `<!-- ganpan-codex-conventions -->` block — and does **not** create
  `.claude/commands/`.
- **AC2** Every installed `SKILL.md` carries `name:` and `description:` YAML
  frontmatter (agy's discovery contract).
- **AC3** `--target all` additionally installs the Claude command set;
  `--target both` output is unchanged vs. current main (regression-guarded).
- **AC4** `--target antigravity` next-steps output mentions `agy` and
  `/skills`; it does not tell the user to run `/ganpan:*` Claude commands.
- **AC5** Invalid targets still die with a usage error listing the accepted
  values (updated list); the line-5 usage comment matches.
- **AC6** All target/runtime enumerations are updated: `docs/SETUP.md`
  (install subsection **and** Support-matrix row, incl. the "codex/both
  installs are already agy-compatible" note), `README.md`, root `CLAUDE.md`,
  root `AGENTS.md`, `docs/RELEASE_CHECKLIST.md` (5th deploy surface + header
  count), `docs/RELEASE_PLAYBOOK.md` (surfaces-table row **and** the §7
  manual-verification copy-in line),
  `docs/CODEX_ADAPTER_RULES.md` (antigravity-parity rule),
  `docs/CODEX_RUNBOOK.md` (shared-payload note), the setup lane
  reference pair (`plugins/orchestration/references/lanes/setup.md` +
  `plugins/ganpan-codex/skills/ganpan-setup/references/setup.md`, runtime
  enumeration line), and `plugins/ganpan-codex/skills/*/SKILL.md` bodies
  (audited and generalized for Codex-only phrasing per the Design bullet).
- **AC7** bats coverage for AC1–AC5 in a **new `tests/antigravity.bats`**
  (pinned — the RELEASE_CHECKLIST surface line names this file) following the
  `tests/install.bats`/`tests/codex-skills.bats` stub patterns; full suite
  green.
- **AC8** `plugins/orchestration/.claude-plugin/plugin.json` is bumped to the
  next **minor** version in the same PR (feat).
- **AC9** Before release, one manual smoke test against a real `agy` install
  (run `agy`, confirm `/skills` lists the six `ganpan-*` skills). If agy's
  discovery chokes on the extra `agents/openai.yaml` files, the recorded
  contingency is to exclude `agents/openai.yaml` from the antigravity copy
  path in a follow-up — the shared-payload design deliberately keeps that
  change one `find`-filter wide. This AC is a release gate, not a bats gate.
  **Enforcement (this repo has `reviewer.autoMerge: true`; verified against
  `review-queue.md` R-D + `auto-merge.sh`, neither a `merge-requested:`
  comment nor a bare `status:needs-decision` label actually blocks the
  auto-merge path — the marker guard is unreachable once autoMerge is on and
  a label without a bot gate is auto-stripped):** the gate must live in what
  the lanes genuinely honor — the **issue's lane state**. If the smoke test
  has not been run by PR time, the implementer does **not** transition the
  issue to `status:in-review` (it stays `status:in-progress`, PR open, with
  an explanatory issue comment); the Reviewer lane never picks the PR up, so
  auto-merge cannot fire. The human either runs the smoke test (then flips
  the label to `status:in-review` for the normal flow) or merges manually.
  If the implementer *can* run `agy` locally, run the smoke test before the
  transition and record the result in the PR body — then the normal
  auto-merge flow is fine. **Binding scope:** the generic lane protocol
  (`work-issue.md` steps 9–10 — the project sync to "In Review" and the
  label move, held **together** so board and label never disagree)
  transitions unconditionally and is deliberately NOT modified — encoding a one-shot release gate into the permanent lane
  instructions would outlive its purpose (recorded out-of-scope). Instead
  this condition binds the session implementing *this spec*: the deep lane's
  transition step is executed by the same agent that executes this spec, so
  "hold the transition until the smoke test or human handoff" is a step of
  this implementation, verified at PR review time by checking the issue's
  label state against the PR body's smoke-test section. **Time decay of the
  hold (verified against `reclaim.sh`):** if the hold outlasts
  `reclaim.timeoutMinutes` without a heartbeat, the orphan sweep flips the
  issue to `status:blocked` (open PR exists → "사람 확인 필요" comment) —
  an acceptable degraded state: still never `status:in-review`, so the
  Reviewer/auto-merge path stays closed, and a human is explicitly
  summoned. The gate therefore holds in both the fresh and the timed-out
  state; no work-issue.md change is needed for either. The PR body must
  still restate the hold instruction — but honestly scoped: for a plain
  re-claim (human relabels the blocked issue back to `status:agent-ready`),
  the lane protocol reaches steps 9–10 without any step that forces reading
  the PR body first, so the restatement relies on session/human diligence,
  not a wired check. **The draft-PR backstop below is the only mechanical
  guard on that path** (no lane script marks a PR ready-for-review), and it
  is sufficient: labels may flip, but the merge cannot. **Technical backstop (covers a violated hold):**
  the PR is opened as a **draft** and marked ready-for-review only once the
  smoke test passes (or the human takes over). Binding, same technique as
  the label hold: the implementing session (the one executing this spec)
  passes `--draft` on its own `gh pr create` invocation — the generic
  work-issue-deep.md step-7 command has no `--draft` flag, so this is an
  explicit obligation of this implementation, not an inherited default —
  and runs `gh pr ready <n>` only after the smoke test passes or the human
  hands off. `auto-merge.sh` merges only
  on `mergeStateStatus == CLEAN`, and a draft PR reports `DRAFT`, never
  `CLEAN` — so even if the labels are flipped erroneously and the Reviewer
  lane reaches its R-D auto-merge rule, the merge cannot fire. No lane code
  changes needed; the backstop rides entirely on existing fail-closed
  checks.
