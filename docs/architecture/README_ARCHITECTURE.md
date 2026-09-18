# ARCHITECTURE — LA GRAN IMPLOSIÓN

## Purpose

Durable architecture knowledge that should not be repeated in full inside `docs/PROJECT_CONTEXT_PROMPT.md`.

## Authority

Architecture decisions must be verified against current code, migrations and live Supabase state. This document records the intended/canonical design after verification.

## Core separation

```text
PROJECT_CONTEXT_PROMPT.md
→ operational state and decisions

README_ARCHITECTURE.md
→ detailed durable architecture knowledge

CODE + SUPABASE
→ actual implementation/state
```

## Core gameplay layering

The game engine is treated as three layers, validated in order:

```text
1. BASIC GAME ENGINE
   construction / research / fleet / transport / attack / combat

2. TEMPORAL LAYER
   persistent clock / workers / events / catch-up / downtime recovery

3. UNIVERSE EVOLUTION
   evolving rates / expansion / special galaxies / AI population
```

The basic engine must be coherent and playable before temporal/evolution work is used to mask defects in the underlying mechanics.

## Current architectural principles

- Keep a single source of truth for player, active planet and universe resolution.
- Do not create parallel state systems when an existing source can be reused.
- Separate universe evolution scaling from galaxy/system expansion.
- Centralize reusable formulas instead of duplicating them across consumers.
- Keep gameplay rules independent from frontend presentation.
- Treat Supabase/Postgres as the authoritative live game backend.
- Use bounded implementation tasks for Cline/Qwen/Copilot.
- Use OGameX for conceptual comparison, not direct architectural transplantation.
- A gameplay domain is not certified merely because its functions exist: execution, persistence, transitions, idempotency, concurrency, integration, documentation and browser validation must also be covered.
- The user is the final validator of the web/UI functional test for each gameplay domain.

## Runtime / deployment boundary

```text
React + Vite
    ↓
Cloudflare Worker + assets
    ↓
Supabase/Postgres
```

Cloudflare is the public HTTP/assets delivery boundary. Supabase remains the authoritative game-state and engine boundary.

The 2026-09-18 Universe Evolution production validation confirmed the full path from the deployed Cloudflare Worker through the React Overview monitor to the sanitized Supabase RPC and live Universe 1 state.

## Construction architecture

Construction follows the canonical pipeline:

```text
Planet
  ↓
start_building()
  ↓
validation
  ↓
cost + time
  ↓
resource deduction
  ↓
building_queue
  ↓
process_building_queue_for_planet()
  ↓
complete_building()
  ↓
planet_buildings
  ↓
production
```

The current construction audit is maintained separately in [`../systems/README_GAME_ENGINE_AUDIT.md`](../systems/README_GAME_ENGINE_AUDIT.md). The next validation targets are production after level-up, transactional concurrency/repeated completion, and the user's browser test.

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

Keep `PROJECT_CONTEXT_PROMPT.md` concise. Move detailed architecture explanations here when they remain useful but are no longer required to recover the immediate project state.

## Universe Evolution observability boundary

Universe Evolution execution and observability are deliberately separated:

Evolution engine
→ private monitor RPC
→ sanitized public monitor RPC
→ React Overview monitor
→ Cloudflare production boundary

The frontend never calls the full internal monitor. The public function is a read-only SECURITY DEFINER with an empty search_path and a fixed safe response whitelist. It is callable by both anon and authenticated because the game supports guest and authenticated UI sessions.

The monitor reports operational state; it does not infer engine health solely from a timestamp and never executes repair work.
