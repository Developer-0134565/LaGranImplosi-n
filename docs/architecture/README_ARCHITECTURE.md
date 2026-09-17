# ARCHITECTURE — LA GRAN IMPLOSIÓN

## Purpose

Durable architecture knowledge that should not be repeated in full inside `docs/PROJECT_CONTEXT_PROMPT.md`.

## Authority

Architecture decisions must be verified against current code, migrations and live Supabase state. This document records the intended/canonical design after verification.

## Core separation

```text
PROJECT_CONTEXT.md
→ operational state and decisions

README_ARCHITECTURE.md
→ detailed durable architecture knowledge

CODE + SUPABASE
→ actual implementation/state
```

## Current architectural principles

- Keep a single source of truth for player, active planet and universe resolution.
- Do not create parallel state systems when an existing source can be reused.
- Separate universe evolution scaling from galaxy/system expansion.
- Centralize reusable formulas instead of duplicating them across consumers.
- Keep gameplay rules independent from frontend presentation.
- Treat Supabase/Postgres as the authoritative live game backend.
- Use bounded implementation tasks for Cline/Qwen/Copilot.
- Use OGameX for conceptual comparison, not direct architectural transplantation.

## Decision record format

For durable architectural decisions use:

```text
ID:
Status: OPEN | CLOSED | SUPERSEDED
Date:
Problem:
Decision:
Reason:
Alternatives considered:
Affected systems:
Implementation:
Validation:
Supersedes:
Superseded by:
```

## Maintenance rule

Keep `PROJECT_CONTEXT.md` concise. Move detailed architecture explanations here when they remain useful but are no longer required to recover the immediate project state.
