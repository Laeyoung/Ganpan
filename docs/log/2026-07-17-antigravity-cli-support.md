# Antigravity CLI (agy) support — `--target antigravity|all`

- **Issue/PR:** #74 / (PR opened as draft pending the AC9 smoke test)
- **Version:** 1.12.3 → 1.13.0 (feat → minor)

## What changed

`install.sh` gained two `--target` values. `antigravity` installs the existing
Codex payload unchanged — `.agents/skills/ganpan-*/SKILL.md`, the `AGENTS.md`
conventions block, engine scripts, and the `.ganpan/orchestration.json`
template — because Antigravity CLI's workspace-skill contract
(`.agents/skills/<name>/SKILL.md` with `name`/`description` frontmatter,
optional `references/`) is byte-compatible with what ganpan already ships for
Codex. `all` installs the Claude surface plus that shared payload. All five
`TARGET_MODE` branch points were extended (arg-validation case, `wants_claude`,
config-creation case, `LEGACY_CONFIG_FALLBACK`, next-steps case) — the script
runs `set -u`, so a missed arm is a fatal unbound-variable crash, two of them
*after* all file copies. New `tests/antigravity.bats` (6 tests) covers AC1–AC5;
every target/runtime enumeration across eight docs was updated.

## Key decisions

- **Shared payload, no fork.** No `plugins/ganpan-antigravity/` source tree;
  Codex and agy consume the identical `.agents/skills/` output via a new
  `wants_agents_payload()` predicate. A copy would rot (same reasoning as
  `references/lanes/` being canonical).
- **Sources conflicted; we bet on Google's codelab and were right.** The
  codelab showed dir+SKILL.md with name/description frontmatter; a dev.to
  hands-on guide showed flat `.agents/skills/lint.md` → `/lint` slash mapping.
  During implementation the locally installed agy 1.1.0's builtin
  `agy-customizations` docs confirmed the codelab layout verbatim (including
  `references/` support and description-driven activation).
- **AC9 release gate = label hold + draft PR.** This repo has
  `reviewer.autoMerge: true`; review verified that neither a
  `merge-requested:` comment nor a bare `status:needs-decision` label actually
  blocks the auto-merge path. The gate that works: don't transition the issue
  to `status:in-review` until the live agy smoke test runs, and open the PR as
  a **draft** (auto-merge requires `mergeStateStatus == CLEAN`; a draft reports
  `DRAFT`). The hold decays safely: `reclaim.sh` flips a stale hold to
  `status:blocked`, which still keeps the Reviewer away and summons a human.
- **Smoke-test status:** format verified against agy's own builtin docs; the
  live `/skills` listing could not be completed headlessly because workspace
  skills sit behind agy's folder-trust gate (`trustedFolders.json`), which only
  interactive runs can grant. A human runs `agy` once in an installed repo and
  checks `/skills` (or merges manually accepting the documented evidence).

## Alternatives considered and rejected

- **Documenting "use --target codex for agy" without a new target** — leaves
  the CLI surface dishonest and docs confusing; the two runtimes would drift
  invisibly if payloads ever diverge.
- **A golden-snapshot stdout test for `--target both`** — brittle; replaced by
  a narrow no-antigravity-leakage assertion plus the existing install.bats
  guards (the test name states its scope honestly).
- **Encoding the AC9 hold into work-issue.md** — a one-shot release gate does
  not belong in the permanent lane protocol; it would outlive its purpose.
- **Global (`~/.gemini/...`) skill install & agy plugin distribution** —
  the global path contract is unstable across sources; workspace install
  satisfies the issue. Recorded as possible follow-ups only.
