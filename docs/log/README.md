# Development log

One Markdown file per shipped change, named `YYYY-MM-DD-<slug>.md`. Each entry records *what* changed and *why*, plus the **key decisions** and the **alternatives considered but not chosen** — so future work builds on past reasoning instead of relitigating it. See CLAUDE.md → "Development workflow & history".

This complements `docs/superpowers/` (specs & plans, written *before* implementation): `docs/superpowers/` captures the intended design; `docs/log/` records what actually shipped and the decisions made along the way.

## When to add an entry
Every feature or non-trivial fix. Trivial changes (typo, formatting, version bump) do not need one.

## Entry template

```markdown
# <title> (#<issue>)

- **Date:** YYYY-MM-DD
- **Issue / PR:** #<issue> / #<pr>
- **Type:** feat | fix | docs | refactor | …

## What changed
Short description of the change as shipped.

## Why
The problem or goal it addresses.

## Key decisions
- <decision> — <rationale>

## Alternatives considered (not chosen)
- <alternative> — <why rejected>
```
