# `/ganpan:update` Advisory Command Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an advisory `/ganpan:update` that detects install mode, shows installed vs latest ganpan version, and prints the exact per-mode update steps — never mutating the repo.

**Architecture:** A read-only engine script `update-info.sh` does all the logic (mode detection via the install sentinel, installed-version resolution, latest via `version-check.sh` with an isolated throwaway state dir). A thin Claude command and a Codex skill present its output. `install.sh` ships the command to copy-in installs.

**Tech Stack:** Bash, `jq`, `gh` (read-only GET, via `version-check.sh`), `bats`, `shellcheck`.

## Global Constraints

- Never rename engine internals (`scripts/orchestration/`, `orchestration.json`, the `ganpan-orchestration` sentinel).
- `update-info.sh` is **read-only** and exits 0 in every path (an advisory must never fail a caller).
- Do **not** modify `version-check.sh`. Reuse it with `VERSION_CHECK_INTERVAL_DAYS=0` **and a disposable `GANPAN_STATE_DIR`** (mktemp) so the lanes' shared throttle stamp is never clobbered.
- Keep stdout clean: the script's stdout is its advisory; no mutating `gh` calls (no write-URL leak vector); diagnostics → stderr.
- Advisory-only: never run `install.sh`, the plugin manager, `git`, or any mutating `gh`.
- After changing `plugins/`, bump `plugins/orchestration/.claude-plugin/plugin.json` (feat → minor) against `main` at implementation time (re-check; concurrent PRs move it).
- Work in worktree `wt-issue-55` on branch `issue-55`; tests from repo root.

---

### Task 1: `update-info.sh` engine script (TDD)

**Files:**
- Create: `plugins/orchestration/scripts/orchestration/update-info.sh`
- Test: `tests/orchestration/update-info.bats`

**Interfaces:**
- Produces: a script that prints (stdout) a multi-line advisory: a `mode:` line (`copy-in`|`plugin`), `installed:` (version or `unknown`), `latest:` (version or `unknown`), `status:` line, and a `To update:` block with the per-mode command. Exit 0 always.
- Consumes: `version-check.sh` (sibling), the install sentinel in `./scripts/orchestration/lib.sh`, and (plugin mode) a manifest via `$GANPAN_PLUGIN_MANIFEST` → `$DIR/../../.claude-plugin/plugin.json` → `$CLAUDE_PLUGIN_ROOT`.

- [ ] **Step 1: Write the failing tests**

Create `tests/orchestration/update-info.bats`:

```bash
#!/usr/bin/env bats

# update-info.sh — advisory: install mode, installed vs latest version, per-mode update steps.

setup() {
  load helpers/common
  setup_gh_stub
  SCRIPT="$BATS_TEST_DIRNAME/../../plugins/orchestration/scripts/orchestration/update-info.sh"
  # update-info.sh self-isolates version-check's state dir, but pin one anyway for determinism.
  export GANPAN_STATE_DIR="$BATS_TEST_TMPDIR/state"
}

# build a copy-in target repo (cwd) whose lib.sh carries the install sentinel.
mk_copyin() {
  local root="$1" ver="$2"
  mkdir -p "$root/scripts/orchestration"
  printf '#!/usr/bin/env bash\n# lib\n# ganpan-orchestration: v%s\n' "$ver" > "$root/scripts/orchestration/lib.sh"
}

@test "copy-in: reports mode, sentinel version, and install.sh guidance" {
  mk_copyin "$BATS_TEST_TMPDIR/repo" 1.5.0
  queue_response '{"version":"9.9.9"}'                 # version-check.sh gh api GET
  cd "$BATS_TEST_TMPDIR/repo"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"mode:"*"copy-in"* ]]
  [[ "$output" == *"installed:"*"1.5.0"* ]]
  [[ "$output" == *"latest:"*"9.9.9"* ]]
  [[ "$output" == *"update available"* ]]    # the update-available status (1.5.0 < 9.9.9)
  [[ "$output" == *"install.sh"* ]]
  [[ "$output" == *"--force"* ]]
}

@test "plugin: reports mode, manifest version (via GANPAN_PLUGIN_MANIFEST), and /plugin guidance" {
  mkdir -p "$BATS_TEST_TMPDIR/empty"                   # cwd with no ./scripts/orchestration
  printf '{"version":"1.5.0"}' > "$BATS_TEST_TMPDIR/manifest.json"
  export GANPAN_PLUGIN_MANIFEST="$BATS_TEST_TMPDIR/manifest.json"
  queue_response '{"version":"9.9.9"}'
  cd "$BATS_TEST_TMPDIR/empty"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"mode:"*"plugin"* ]]
  [[ "$output" == *"installed:"*"1.5.0"* ]]
  [[ "$output" == *"/plugin"* ]]
}

@test "same version → up to date" {
  mk_copyin "$BATS_TEST_TMPDIR/repo" 9.9.9
  queue_response '{"version":"9.9.9"}'
  cd "$BATS_TEST_TMPDIR/repo"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"up to date"* ]]
}

@test "latest lookup fails (offline) → could not determine latest, still exits 0" {
  mk_copyin "$BATS_TEST_TMPDIR/repo" 1.5.0
  export GH_EXIT=1                                      # gh api fails → version-check prints unknown
  cd "$BATS_TEST_TMPDIR/repo"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"could not determine latest"* ]]
}

@test "plugin mode, installed version unknown (no manifest) → still prints latest + /plugin" {
  mkdir -p "$BATS_TEST_TMPDIR/empty"
  export GANPAN_PLUGIN_MANIFEST="$BATS_TEST_TMPDIR/does-not-exist.json"
  queue_response '{"version":"9.9.9"}'
  cd "$BATS_TEST_TMPDIR/empty"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"installed:"*"unknown"* ]]
  [[ "$output" == *"latest:"*"9.9.9"* ]]
  [[ "$output" == *"/plugin"* ]]
}
```

> Notes: in bats `$DIR` resolves to the real source tree, so the plugin tests use `GANPAN_PLUGIN_MANIFEST` to exercise plugin resolution without touching the source. `GH_EXIT=1` makes the stub exit non-zero on the `gh api` call so `version-check.sh` prints `unknown` — it is checked *after* the read-branch so it consumes **no** queue slot; the offline test therefore needs **no** `queue_response` (do not add one). `gh-stub.sh` honors `GH_EXIT` (confirm before running).

- [ ] **Step 2: Run tests, expect FAIL**

Run: `bats tests/orchestration/update-info.bats`
Expected: all FAIL — `update-info.sh` does not exist yet (`bash: …: No such file`).

- [ ] **Step 3: Write `update-info.sh`**

Create `plugins/orchestration/scripts/orchestration/update-info.sh`:

```bash
#!/usr/bin/env bash
# update-info.sh — advisory: detect install mode, show installed vs latest ganpan
# version, and print the exact per-mode update steps. READ-ONLY: never mutates the
# repo, never runs the updater/plugin-manager. exit 0 always (an advisory must not fail).
#
# stdout: a human-readable advisory block. stderr: diagnostics only.
set -uo pipefail   # NOT -e: a failed lookup must degrade to "unknown", not abort.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SLUG="${GANPAN_SOURCE_REPO:-Laeyoung/Ganpan}"

# --- install mode + installed version ---
# copy-in iff the local engine lib.sh carries the install sentinel (not mere file
# existence — avoids a false positive for an unrelated ./scripts/orchestration dir).
if [ -f "./scripts/orchestration/lib.sh" ] && grep -q 'ganpan-orchestration:' "./scripts/orchestration/lib.sh" 2>/dev/null; then
  mode="copy-in"
  installed="$(grep -o 'ganpan-orchestration: v[0-9][0-9.]*' "./scripts/orchestration/lib.sh" | head -1 | sed 's/.*v//')"
else
  mode="plugin"
  manifest=""
  if [ -n "${GANPAN_PLUGIN_MANIFEST:-}" ] && [ -f "${GANPAN_PLUGIN_MANIFEST}" ]; then
    manifest="$GANPAN_PLUGIN_MANIFEST"
  elif [ -f "$DIR/../../.claude-plugin/plugin.json" ]; then
    manifest="$DIR/../../.claude-plugin/plugin.json"
  elif [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json" ]; then
    manifest="$CLAUDE_PLUGIN_ROOT/.claude-plugin/plugin.json"
  fi
  if [ -n "$manifest" ]; then
    installed="$(jq -r '.version // empty' "$manifest" 2>/dev/null)"
  fi
fi
[ -n "${installed:-}" ] || installed="unknown"

# --- latest version via version-check.sh, in an isolated throwaway state dir so the
# lanes' shared throttle stamp is never overwritten; days=0 forces a fresh check. ---
state="$(mktemp -d 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/ganpan-update.$$")"
mkdir -p "$state" 2>/dev/null || true
probe="$installed"; [ "$probe" = "unknown" ] && probe="0.0.0"   # 0.0.0 < any real release → forces "update-available: 0.0.0 -> <latest>" so we can read <latest>
vc="$(VERSION_CHECK_INTERVAL_DAYS=0 GANPAN_STATE_DIR="$state" GANPAN_SOURCE_REPO="$SLUG" \
      bash "$DIR/version-check.sh" "$probe" 2>/dev/null)" || vc="unknown"
rm -rf "$state" 2>/dev/null || true

case "$vc" in
  "update-available: "*) latest="${vc##*-> }"; status="update available" ;;
  current)
    if [ "$installed" = "unknown" ]; then
      # installed unknown ⇒ probe was the synthetic 0.0.0; a `current` verdict here means
      # the lookup couldn't give us a real latest to show. Don't claim "up to date".
      latest="unknown"; status="could not determine latest"
    else
      latest="$installed"; status="up to date"
    fi ;;
  *)                     latest="unknown";    status="could not determine latest" ;;
esac

# --- per-mode guidance ---
if [ "$mode" = "copy-in" ]; then
  guidance="  ./install.sh . --target both --force      # re-run from your repo root (use your actual target path)"
else
  guidance='  Run /plugin, then update "ganpan@laeyoung" from the marketplace manager.'
fi

# --- advisory (stdout) ---
cat <<EOF
ganpan update info
  mode:      $mode
  installed: $installed
  latest:    $latest
  status:    $status

To update (run this yourself — /ganpan:update never changes your repo):
$guidance
EOF
exit 0
```

- [ ] **Step 4: `chmod +x` and run tests, expect PASS**

Run: `chmod +x plugins/orchestration/scripts/orchestration/update-info.sh && bats tests/orchestration/update-info.bats`
Expected: all 5 PASS.

- [ ] **Step 5: shellcheck**

Run: `shellcheck plugins/orchestration/scripts/orchestration/update-info.sh`
Expected: exit 0.

- [ ] **Step 6: Commit**

```bash
git add plugins/orchestration/scripts/orchestration/update-info.sh tests/orchestration/update-info.bats
git commit -m "feat(orch): add update-info.sh advisory (mode + version + steps)

Read-only: detects copy-in vs plugin install via the sentinel, shows
installed vs latest (version-check.sh in an isolated state dir so the
lanes' throttle stamp is untouched), prints per-mode update steps.
Refs #55"
```

---

### Task 2: Claude command, Codex skill, and install wiring

**Files:**
- Create: `plugins/orchestration/commands/update.md`
- Create: `plugins/ganpan-codex/skills/ganpan-update/SKILL.md`
- Create: `plugins/ganpan-codex/skills/ganpan-update/agents/openai.yaml`
- Modify: `install.sh` (line ~165 command list + ~170 info line)
- Modify: `tests/install.bats` (add an `update.md` assertion)

**Interfaces:**
- Consumes: `update-info.sh` from Task 1.

- [ ] **Step 1: Write the Claude command**

Create `plugins/orchestration/commands/update.md`:

```markdown
---
description: Advisory — show installed vs latest ganpan version and the exact update steps (never changes your repo).
---

You are running the **advisory** `/ganpan:update`. It is **read-only**: it reports the install mode, the installed vs latest ganpan version, and the exact steps for the user to run. It never updates anything itself.

Run the advisory and show its output verbatim:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/orchestration/update-info.sh
```

Then, in one or two sentences, tell the user whether an update is available and that they must run the printed step themselves (plugin installs update via `/plugin`; copy-in installs re-run `install.sh … --force`). Do **not** run `install.sh`, `/plugin`, or any update action on their behalf.
```

- [ ] **Step 2: Write the Codex skill**

Create `plugins/ganpan-codex/skills/ganpan-update/SKILL.md`:

```markdown
---
name: ganpan-update
description: Advisory — report installed vs latest ganpan version and the exact per-mode update steps. Read-only; never performs the update.
---

# Ganpan Update (advisory)

Use this skill from the target repository root. It is **read-only** — it reports versions and the steps to update, and never performs the update.

1. Run the advisory and show its output:
   ```bash
   scripts/orchestration/update-info.sh
   ```
2. Tell the user whether an update is available and that they run the printed step themselves (plugin: `/plugin`; copy-in: re-run `install.sh … --force`). Never run the updater for them.
```

Create `plugins/ganpan-codex/skills/ganpan-update/agents/openai.yaml`:

```yaml
name: ganpan-update
description: Report installed vs latest ganpan version and the update steps (advisory).
```

- [ ] **Step 3: Wire the command into copy-in installs**

In `install.sh`, add `update` to the lane-command loop list (line ~165):

```bash
  for name in work-issue work-issue-deep triage review-queue qa-check run-all update; do
```

And update the `info` line (~170) to include it:

```bash
  info ".claude/commands/{work-issue,work-issue-deep,triage,review-queue,qa-check,run-all,update}.md"
```

- [ ] **Step 4: Add an install.bats assertion**

In `tests/install.bats`, in the "install copies engine, commands, assets" test (after the existing `work-issue-deep.md` assertion, ~line 17), add:

```bash
  [ -f "$TARGET/.claude/commands/update.md" ]
```

- [ ] **Step 5: Add `ganpan-update` to the hardcoded skill lists in the tests**

Two tests iterate a **hardcoded** skill list (they pass silently without the new skill — false green). Add `ganpan-update`:
- `tests/codex-skills.bats` (~line 10): the required-frontmatter loop `for name in ganpan-triage ganpan-work-issue ganpan-review-queue ganpan-qa-check ganpan-setup` → append ` ganpan-update`.
- `tests/install.bats` (codex-target test, ~line 110): add an assertion `[ -f "$TARGET/.agents/skills/ganpan-update/SKILL.md" ]`.
- Do **not** touch the "installed codex skills resolve references" loop (`for lane in triage work-issue review-queue qa-check setup`) — `ganpan-update` has no `references/` lane file, so it is correctly excluded.

> Verify line numbers by reading the files first (`grep -n 'for name in ganpan-' tests/codex-skills.bats` and `grep -n 'agents/skills' tests/install.bats`).

- [ ] **Step 6: Run install + codex tests + shellcheck**

Run: `bats tests/install.bats tests/codex-skills.bats && shellcheck install.sh`
Expected: PASS; shellcheck exit 0.

- [ ] **Step 7: Commit**

```bash
git add plugins/orchestration/commands/update.md plugins/ganpan-codex/skills/ganpan-update install.sh tests/install.bats tests/codex-skills.bats
git commit -m "feat(orch): /ganpan:update command + Codex skill + install wiring

Advisory command/skill presenting update-info.sh; install.sh ships
update.md to copy-in installs (Codex skill auto-globbed). Refs #55"
```

---

### Task 3: Docs, version bump, dev-log, full gate

**Files:**
- Modify: `docs/SETUP.md`
- Modify: `plugins/orchestration/assets/CLAUDE.md` (only if it enumerates commands)
- Modify: `plugins/orchestration/.claude-plugin/plugin.json`
- Create: `docs/log/2026-06-26-ganpan-update-command.md`

- [ ] **Step 1: Document in `docs/SETUP.md`**

In `docs/SETUP.md`, in the "Run the lanes" area (or a new "Updating" note), add:

```markdown
- **`/ganpan:update`** (advisory): shows your installed vs latest ganpan version and the exact update steps. It never changes your repo — plugin installs update via `/plugin`; copy-in installs re-run `install.sh <repo> --target both --force`.
```

- [ ] **Step 2: Update `assets/CLAUDE.md` if it lists commands**

Run: `grep -n "work-issue\|qa-check\|commands" plugins/orchestration/assets/CLAUDE.md`. If a command list exists, add `/ganpan:update` (advisory) to it. If not, skip (no change).

- [ ] **Step 3: Bump version (feat → minor)**

Run: `git fetch origin main && git show origin/main:plugins/orchestration/.claude-plugin/plugin.json | jq -r .version` to get main's current version `M.m.p`. Set `plugins/orchestration/.claude-plugin/plugin.json` `version` to the next minor `M.(m+1).0`. Validate: `jq . plugins/orchestration/.claude-plugin/plugin.json`.

- [ ] **Step 4: Full gate**

Run: `bats tests/*.bats tests/orchestration/*.bats`  → all green.
Run: `shellcheck plugins/orchestration/scripts/orchestration/*.sh install.sh`  → exit 0.
Run: `jq . plugins/orchestration/.claude-plugin/plugin.json .claude-plugin/marketplace.json`  → valid.

- [ ] **Step 5: Write the dev-log**

Create `docs/log/2026-06-26-ganpan-update-command.md` per `docs/log/README.md`, recording:
- What changed: advisory `update-info.sh`, `/ganpan:update` command + `ganpan-update` Codex skill, install wiring, docs.
- The owner's **advisory-only** decision (overriding the issue's perform-update) and why.
- Key decisions: sentinel-based mode detection; isolated throwaway `GANPAN_STATE_DIR` to avoid clobbering the lanes' throttle stamp; script-relative manifest resolution with a `GANPAN_PLUGIN_MANIFEST` test hook; reuse `version-check.sh` (no duplication of the API call).
- Alternatives rejected: performing the update (owner override); filename-existence mode detection (false positives → sentinel grep); inlining the gh-api call instead of reusing version-check.sh (duplication); `$CLAUDE_PLUGIN_ROOT`-only version (fails when unset → script-relative primary).

- [ ] **Step 6: Commit (log first, then bump — so the log survives a merge-time re-bump)**

```bash
# omit plugins/orchestration/assets/CLAUDE.md from the add if Step 2 left it unchanged (no-op).
git add docs/SETUP.md plugins/orchestration/assets/CLAUDE.md docs/log/2026-06-26-ganpan-update-command.md
git commit -m "docs: document /ganpan:update advisory command (#55)"
git add plugins/orchestration/.claude-plugin/plugin.json
git commit -m "chore(release): bump orchestration for #55 (feat -> minor)"
```

> **Cross-PR version note:** main moves as concurrent PRs merge; compute the bump from `origin/main` at this step and flag in the PR body that a merge-time re-bump may be needed.
