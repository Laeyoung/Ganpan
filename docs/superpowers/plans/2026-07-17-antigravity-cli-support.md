# Antigravity CLI (agy) Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `./install.sh <target> --target antigravity|all` installs the shared agents-skills payload so Antigravity CLI (agy) users can run ganpan lanes, with every target/runtime enumeration in the docs updated.

**Architecture:** Reuse the existing Codex payload (`.agents/skills/ganpan-*/SKILL.md` + `AGENTS.md`) — agy's workspace-skill contract is byte-compatible per the Google codelab. install.sh gains two target values wired through all five `TARGET_MODE` branch points; no new source tree, no engine changes.

**Tech Stack:** Bash (`set -euo pipefail`), bats ≥1.5.0, shellcheck, jq.

**Spec:** `docs/superpowers/specs/2026-07-17-antigravity-cli-support.md` (review-hardened, 38 fixes). Read it before starting.

## Global Constraints

- Never rename engine internals (`scripts/orchestration/`, `orchestration.json` filename, `ganpan-orchestration` sentinel).
- Existing invocations byte-identical: bare `./install.sh <t>`, `--target codex`, `--target both` — including their stdout (AC3: no additive lines on `both`).
- Every new copy path keeps sentinel/`needs_write` semantics.
- SemVer **minor** bump: `plugins/orchestration/.claude-plugin/plugin.json` `1.12.3` → `1.13.0` (AC8).
- Conventional Commits; footer `Refs #74` (non-closing — QA owns the close).
- Work in the worktree `wt-issue-74` on branch `issue-74`.

---

### Task 1: install.sh target plumbing (`antigravity`, `all`)

**Files:**
- Modify: `install.sh` (lines 5, 52, 66-67, 81-82, 100, 113, 221-224)
- Test: `tests/antigravity.bats` (create — AC7 pins this filename)

**Interfaces:**
- Produces: `wants_antigravity()` (true for `antigravity|all`), `wants_agents_payload()` (true for `codex|both|antigravity|all`), `wants_claude()` now also true for `all`. Sections 5 (skills) and 6 (AGENTS.md) gate on `wants_agents_payload`; config-creation `case` gains `antigravity|all` arm; next-steps `case` gains `antigravity)` and `all)` arms.

- [ ] **Step 1: Write the failing tests**

Create `tests/antigravity.bats`:

```bash
#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$BATS_TEST_DIRNAME/.."
  TARGET="$BATS_TEST_TMPDIR/target"
  mkdir -p "$TARGET/.git"
}

@test "--target antigravity installs the agents-skills payload without Claude commands" {
  run bash "$REPO_ROOT/install.sh" "$TARGET" --target antigravity
  [ "$status" -eq 0 ]
  for name in ganpan-triage ganpan-work-issue ganpan-review-queue ganpan-qa-check ganpan-setup ganpan-update; do
    [ -f "$TARGET/.agents/skills/$name/SKILL.md" ]
  done
  [ -f "$TARGET/scripts/orchestration/claim.sh" ]
  [ -f "$TARGET/references/lanes/work-issue.md" ]
  [ -f "$TARGET/docs/SETUP.md" ]
  [ -f "$TARGET/.ganpan/orchestration.json" ]
  run grep -qF '<!-- ganpan-codex-conventions -->' "$TARGET/AGENTS.md"
  [ "$status" -eq 0 ]
  [ ! -d "$TARGET/.claude/commands" ]
}

@test "installed SKILL.md files carry name/description frontmatter (agy discovery contract)" {
  run bash "$REPO_ROOT/install.sh" "$TARGET" --target antigravity
  [ "$status" -eq 0 ]
  for skill in "$TARGET"/.agents/skills/ganpan-*/SKILL.md; do
    run sed -n '1,3p' "$skill"
    [[ "$output" == ---$'\n'name:*$'\n'description:* ]]
  done
}

@test "--target all installs Claude commands plus the agents-skills payload" {
  run bash "$REPO_ROOT/install.sh" "$TARGET" --target all
  [ "$status" -eq 0 ]
  [ -f "$TARGET/.claude/commands/work-issue.md" ]
  [ -f "$TARGET/.agents/skills/ganpan-work-issue/SKILL.md" ]
  run grep -qF '<!-- orchestration-conventions -->' "$TARGET/CLAUDE.md"
  [ "$status" -eq 0 ]
  run grep -qF '<!-- ganpan-codex-conventions -->' "$TARGET/AGENTS.md"
  [ "$status" -eq 0 ]
}

@test "--target antigravity next steps mention agy and /skills, no /ganpan: commands" {
  run bash "$REPO_ROOT/install.sh" "$TARGET" --target antigravity
  [ "$status" -eq 0 ]
  [[ "$output" == *"agy"* ]]
  [[ "$output" == *"/skills"* ]]
  [[ "$output" != *"/ganpan:"* ]]
}

@test "invalid --target dies listing the accepted values" {
  run bash "$REPO_ROOT/install.sh" "$TARGET" --target nope
  [ "$status" -ne 0 ]
  [[ "$output" == *"claude, codex, antigravity, both, all"* ]]
}

@test "--target both stdout has no antigravity leakage (narrow guard — full byte-identity is covered by tests/install.bats plus code review, not this test)" {
  run bash "$REPO_ROOT/install.sh" "$TARGET" --target both
  [ "$status" -eq 0 ]
  [[ "$output" != *"agy"* ]]
  [ -f "$TARGET/.claude/commands/work-issue.md" ]
  [ -f "$TARGET/.agents/skills/ganpan-work-issue/SKILL.md" ]
}
```

- [ ] **Step 2: Run and confirm they fail**

Run: `bats tests/antigravity.bats`
Expected: first/2nd/3rd/4th tests FAIL with `--target must be one of: claude, codex, both` in output; 5th FAILS on the new message text; last PASSES (both path unchanged).

- [ ] **Step 3: Implement install.sh changes**

Apply these exact edits (line refs are pre-edit):

Line 5 usage comment:
```bash
#   ./install.sh <target-repo-path> [--target claude|codex|antigravity|both|all] [--force]
```

Line ~52 (`--target` missing-arg die):
```bash
      [ "$#" -gt 0 ] || die "--target requires claude, codex, antigravity, both, or all"
```

Lines 66-67 (validation case):
```bash
  claude|codex|antigravity|both|all) ;;
  *) die "--target must be one of: claude, codex, antigravity, both, all" ;;
```

Lines 81-82 (predicates — add two, extend one; keep `wants_codex` untouched):
```bash
wants_claude()  { [ "$TARGET_MODE" = "claude" ] || [ "$TARGET_MODE" = "both" ] || [ "$TARGET_MODE" = "all" ]; }
wants_codex()   { [ "$TARGET_MODE" = "codex" ] || [ "$TARGET_MODE" = "both" ]; }
wants_antigravity() { [ "$TARGET_MODE" = "antigravity" ] || [ "$TARGET_MODE" = "all" ]; }
wants_agents_payload() { wants_codex || wants_antigravity; }
```

Config-creation `case` (~line 100): change the second arm to
```bash
    codex|both|antigravity|all)
```

`LEGACY_CONFIG_FALLBACK` check (~line 113): `wants_codex` → `wants_agents_payload`.

Section 5 (Codex skills, `if wants_codex; then`) and section 6 (AGENTS.md, `if wants_codex; then`): both become `if wants_agents_payload; then`.

Next-steps `case` (~lines 221-224) — add two arms (existing arms untouched):
```bash
  antigravity) CONFIG_PATH=".ganpan/orchestration.json"; LANE_HINT="Run agy in the repo — /skills should list the ganpan-* skills; invoke a lane by asking for it by name (or try /ganpan-<lane>)" ;;
  all) CONFIG_PATH=".ganpan/orchestration.json"; LANE_HINT="/loop /ganpan:work-issue · /loop 10m /ganpan:triage · /loop 5m /ganpan:review-queue · /ganpan:qa-check · (all at once) /loop 20m /ganpan:run-all — plus Codex/agy skills: ganpan-work-issue · ganpan-triage · ganpan-review-queue · ganpan-qa-check" ;;
```

- [ ] **Step 4: Run tests + full guards**

Run: `bats tests/antigravity.bats && bats tests/install.bats tests/codex-skills.bats && shellcheck install.sh`
Expected: all PASS (install.bats/codex-skills.bats prove claude/codex/both unchanged).

- [ ] **Step 5: Commit**

```bash
git add tests/antigravity.bats install.sh
git commit -m "feat(install): --target antigravity|all installs the shared agents-skills payload

agy discovers .agents/skills/<name>/SKILL.md with name/description
frontmatter — byte-compatible with the Codex payload — so antigravity
reuses it; all five TARGET_MODE branch points gain arms (set -u makes a
missed arm a fatal unbound-variable crash after copies).

Refs #74"
```

---

### Task 2: Generalize Codex-only phrasing in shipped skill/lane text

**Files:**
- Modify: `plugins/ganpan-codex/skills/ganpan-setup/SKILL.md:12`
- Modify: `plugins/orchestration/references/lanes/setup.md:12`
- Modify: `plugins/ganpan-codex/skills/ganpan-setup/references/setup.md:12` (must stay identical to the lane copy — `tests/codex-skills.bats` "codex lane references match the shared source" enforces it)
- Test: existing `tests/codex-skills.bats` (no new test; the match-the-shared-source test is the guard)

- [ ] **Step 1: Edit the three lines**

`ganpan-setup/SKILL.md` line 12:
```markdown
3. Prefer `.ganpan/orchestration.json` for new installs. Legacy `.claude/orchestration.json` remains a fallback.
```

Both `setup.md` copies, line 12 (identical text in both files):
```markdown
4. Merge Ganpan conventions into the agent instructions file once — `CLAUDE.md` for the Claude Code surface, `AGENTS.md` for the Codex and Antigravity surfaces.
```

- [ ] **Step 2: Audit the other five SKILL.md bodies**

Run: `grep -n -i 'codex' plugins/ganpan-codex/skills/*/SKILL.md`
Generalize any remaining runtime-exclusive phrasing the same way (leave names like `ganpan-codex` paths alone). Expected from spec review: only ganpan-setup's line is exclusive.

- [ ] **Step 3: Run the guard suite**

Run: `bats tests/codex-skills.bats`
Expected: PASS (esp. "codex lane references match the shared source").

- [ ] **Step 4: Commit**

```bash
git add plugins/ganpan-codex plugins/orchestration/references/lanes/setup.md
git commit -m "docs(skills): generalize Codex-only phrasing for the shared agy payload

Refs #74"
```

---

### Task 3: Documentation sweep (every target/runtime enumeration)

**Files:** `docs/SETUP.md`, `README.md`, `CLAUDE.md` (root), `AGENTS.md` (root), `docs/RELEASE_CHECKLIST.md`, `docs/RELEASE_PLAYBOOK.md`, `docs/CODEX_ADAPTER_RULES.md`, `docs/CODEX_RUNBOOK.md`

- [ ] **Step 1: docs/SETUP.md** — Support matrix (line ~112) gains a row after the Codex row:
```markdown
| Antigravity CLI skills | Phase 1 (shared payload) | `.agents/skills/ganpan-*` via `--target antigravity` |
```
Add an "Antigravity CLI" subsection next to the Codex install notes:
```markdown
### Antigravity CLI (agy)

```bash
./install.sh <target-repo-path> --target antigravity
```

Installs the same repo-local agents-skills payload as the Codex target —
`.agents/skills/ganpan-*`, `AGENTS.md` conventions block, engine scripts,
`.ganpan/orchestration.json` template. Existing `--target codex`/`both`
installs are **already agy-compatible on disk** (identical payload); no
reinstall needed. Verify with `agy` in the repo: `/skills` should list the
six `ganpan-*` skills. Invoke a lane by asking for it by name (agy
auto-matches on the skill description) or try the `/<skill-name>` slash
form — sources disagree on the invocation mechanism; both are documented.
```

- [ ] **Step 2: README.md** — top tagline (line 3): "Claude Code + Codex 지원 툴킷" → "Claude Code + Codex + Antigravity CLI 지원 툴킷". Then the "지원 표면" table (line ~54) gains:
```markdown
| Antigravity CLI skills | Phase 1 (shared payload) | `.agents/skills/ganpan-*` |
```
After 방법 C, add a runnable subsection (AC6 requires the command example, not just prose):
```markdown
### 방법 D — Antigravity CLI (agy) repo-local skills

Codex와 동일한 agents-skills payload를 설치합니다 (agy는 `.agents/skills/<name>/SKILL.md`를 읽습니다):

```bash
./install.sh <대상-레포-경로> --target antigravity
```

설치되는 항목:
- `.agents/skills/ganpan-*`
- `AGENTS.md` Ganpan conventions block
- `scripts/orchestration/*.sh`
- `.ganpan/orchestration.json` 템플릿 (기존 `.claude/orchestration.json`만 있으면 legacy fallback 유지)
- `.github/labels.yml` + issue template

이미 `--target codex`/`both`로 설치했다면 디스크 상태가 동일하므로 재설치가 필요 없습니다. 설치 후 대상 레포에서 `agy` 실행 → `/skills`에 `ganpan-*` 6종이 보이면 성공. 레인은 이름으로 요청하거나 `/<skill-name>` 슬래시 형태로 호출합니다. Claude + Codex + Antigravity를 한 번에 설치하려면 `--target all`.
```

- [ ] **Step 3: root CLAUDE.md** — line 20: ``--target claude|codex|both`` → ``--target claude|codex|antigravity|both|all``; Development-section test note "(includes codex-skills.bats)" → "(includes codex-skills.bats, antigravity.bats)".

- [ ] **Step 4: root AGENTS.md** — line 5 "for Claude Code and Codex" → "for Claude Code, Codex, and Antigravity CLI"; smoke-test block gains `./install.sh /path/to/target --target antigravity`; Testing Guidelines line gains "Antigravity install validation belongs in `tests/antigravity.bats`."

- [ ] **Step 5: docs/RELEASE_CHECKLIST.md** — header "Ganpan ships four surfaces" → "five surfaces"; add after the Copy-in Codex bullet:
```markdown
- [ ] **Copy-in Antigravity** (`./install.sh <target> --target antigravity`): installs `.agents/skills/ganpan-*` (covered by `tests/antigravity.bats`).
```

- [ ] **Step 6: docs/RELEASE_PLAYBOOK.md** — §7 copy-in line: "(and `--target codex` / `--target both`)" → "(and `--target codex` / `--target both` / `--target antigravity`)"; surfaces table gains:
```markdown
| Copy-in Antigravity | `./install.sh <target> --target antigravity` | `tests/antigravity.bats` |
```

- [ ] **Step 7: docs/CODEX_ADAPTER_RULES.md** — after line 75's `--target both` rule add:
```markdown
- `--target antigravity` installs the identical agents-skills payload; every `--target codex` invariant above applies to it verbatim (antigravity parity).
```

- [ ] **Step 8: docs/CODEX_RUNBOOK.md** — after the install commands (~line 43) add:
```markdown
Antigravity CLI (agy) reads the same `.agents/skills/ganpan-*` payload — `--target antigravity` installs it identically, and this runbook applies unchanged.
```

- [ ] **Step 9: Verify enumeration coverage & commit**

Run: `grep -rn -- '--target codex' README.md docs/ CLAUDE.md AGENTS.md | grep -v antigravity` — every hit should be a line that also now mentions antigravity nearby or is historical (docs/PHASE1_DEV_LOG.md is out of scope).

```bash
git add docs/SETUP.md README.md CLAUDE.md AGENTS.md docs/RELEASE_CHECKLIST.md docs/RELEASE_PLAYBOOK.md docs/CODEX_ADAPTER_RULES.md docs/CODEX_RUNBOOK.md
git commit -m "docs: document the Antigravity CLI install surface everywhere targets are enumerated

Refs #74"
```

---

### Task 4: Version bump + full verification

**Files:** `plugins/orchestration/.claude-plugin/plugin.json`

- [ ] **Step 1:** Set `"version": "1.13.0"` (feat → minor, from 1.12.3).
- [ ] **Step 2:** Run the full gate:
```bash
bats tests/*.bats tests/orchestration/*.bats
shellcheck plugins/orchestration/scripts/orchestration/*.sh install.sh
jq . .claude-plugin/marketplace.json plugins/orchestration/.claude-plugin/plugin.json
```
Expected: all green (≥215 bats tests incl. the 6 new ones).
- [ ] **Step 3:** Commit:
```bash
git add plugins/orchestration/.claude-plugin/plugin.json
git commit -m "chore(release): bump plugin to 1.13.0 for the antigravity install target

Refs #74"
```

---

### Task 5: AC9 release gate (PR mechanics — binds THIS implementing session)

Not a code task; obligations from spec AC9:
- [ ] Create the PR **as a draft**: `gh pr create --draft ...` (the generic lane command has no `--draft`; this is an explicit obligation of this run).
- [ ] Check for a local `agy` binary (`command -v agy`). If present: run the smoke test in a scratch install (`/skills` lists the six `ganpan-*` skills), record the result in the PR body, then `gh pr ready <n>` and transition the issue normally.
- [ ] If absent: PR body states the smoke test was NOT run + restates the hold; do **not** transition the issue to `status:in-review` (skip work-issue.md steps 9–10 — project sync and label move held together); leave it `status:in-progress` with an explanatory issue comment. The human either runs the smoke test then flips the label, or merges manually. Contingency if agy rejects the payload: exclude `agents/openai.yaml` from the antigravity copy path in a follow-up.

## Self-Review (done at authoring)

1. **Spec coverage**: AC1-AC5 → Task 1; SKILL.md/lane wording → Task 2; AC6 (all eight doc surfaces incl. tables, §7 line, header count, runnable README example) → Task 3; AC8 → Task 4; AC9 → Task 5; AC7 → Task 1 Step 1 + Task 4 Step 2. AC2 → Task 1 test 2.
2. **Placeholders**: none — every step carries exact text/code.
3. **Consistency**: predicate names (`wants_antigravity`, `wants_agents_payload`) used identically in Task 1 steps; `tests/antigravity.bats` filename consistent with RELEASE_CHECKLIST/PLAYBOOK lines in Task 3.
