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

1. **Skill format.** Antigravity CLI discovers workspace skills at
   `.agents/skills/<skill-name>/SKILL.md` with YAML frontmatter carrying
   `name:` and `description:`. This is **byte-compatible with what ganpan's
   Codex target already ships** — same path, same layout, same frontmatter.
   (Source: codelabs.developers.google.com/antigravity/how-to-create-agent-skills-for-antigravity-cli)
2. **Invocation.** Skills are auto-activated by intent match on the
   frontmatter `description` (no slash command required); `/skills` inside the
   `agy` TUI lists what was discovered.
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
  skills/AGENTS.md/config sections key on `wants_agents_payload()`
  (codex ∨ antigravity ∨ both ∨ all) so the copy loop stays single-sourced.
- The final **next-steps hint** becomes target-aware: for `antigravity` it
  says to run `agy` in the repo, check `/skills` for the `ganpan-*` skills,
  and invoke lanes by asking for them by name (auto-match on description).

Documentation:

- `docs/SETUP.md`: add an Antigravity CLI subsection next to the Codex one
  (install command, `/skills` verification, invocation model).
- `README.md`: mention Antigravity CLI as a supported runtime where Codex is
  mentioned.
- `plugins/ganpan-codex/assets/AGENTS.md`: keep shared; wording stays
  runtime-neutral ("agent skills") — audit for Codex-only phrasing and
  generalize where trivial.

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
  values (updated list).
- **AC6** `docs/SETUP.md` and `README.md` document the Antigravity install
  path.
- **AC7** bats coverage for AC1–AC5 (new `tests/antigravity.bats` or extension
  of `tests/install.bats`/`tests/codex-skills.bats` following their stub
  patterns); full suite green.
