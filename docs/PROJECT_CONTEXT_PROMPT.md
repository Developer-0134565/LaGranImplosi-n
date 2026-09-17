# PROJECT CONTEXT PROMPT — LA GRAN IMPLOSIÓN

> **Read this file at every new session and whenever project context is uncertain before making substantial decisions.**
>
> This is the project's persistent memory and living anti-drift document. It exists to prevent session-memory loss, obsolete assumptions, duplicated work, accidental reversion of completed fixes, and ambiguity between similarly named systems.

## 1. Mission

We are building **La Gran Implosión**, an OGame-like browser game with React/TypeScript/Vite on the frontend and Supabase/Postgres as the game backend.

The objective is not to copy OGameX. OGameX and other open-source OGame implementations are references for understanding established formulas and architecture. Our game rules are our own unless explicitly adopted.

## 2. Mandatory operating procedure

Before proposing or applying a substantial change:

1. **Read this file completely enough to recover the current canonical context. This step is mandatory at every new session.**
2. Read the relevant living monitor document(s).
3. Inspect the current repository/Supabase state rather than relying on old conversation memory.
4. Identify whether the requested work is already completed.
5. Search for existing implementations before creating a new function, table, formula, state store, or duplicate query.
6. Preserve completed work unless there is a documented reason to change it.
7. Do not resurrect obsolete architecture because it appeared in an older conversation.
8. If current code contradicts this document, treat the contradiction as an audit finding and verify the live code/database before changing anything.
9. After every important architectural, gameplay, database, tooling, or integration step, update this document and the relevant monitor with the new canonical state.
10. Use this document as active feedback during implementation: before creating or renaming anything, check its terminology, CLOSED decisions, OPEN audits, and existing implementation notes to avoid duplication and preserve cohesion.

## 3. Source-of-truth hierarchy

When sources disagree, verify in this order:

```text
LIVE SUPABASE GAME STATE / DEFINITIONS
        ↓
CURRENT GITHUB CODE + CHECKED-IN MIGRATIONS
        ↓
CURRENT LIVING DOCS IN docs/
        ↓
RECENT AUDIT RESULTS
        ↓
OLD SESSION CONVERSATIONS
        ↓
GENERAL MEMORY / ASSUMPTIONS
```

Conversation history is context, not proof of the current repository state.

## 4. Tools and implementation workflow

The project uses the following tools as part of its development workflow:

### 4.1 GitHub

GitHub is the repository/source-control layer and the canonical home for checked-in application code, migrations, and project documentation.

Repository:

```text
Developer-0134565/LaGranImplosi-n
```

Main branch:

```text
main
```

### 4.2 GitHub Copilot

**GitHub Copilot is the primary implementation assistant for scoped code changes.**

Copilot is used to execute bounded implementation/refactor tasks after architecture, formulas, naming, and intended behavior have been established.

Copilot must follow this context document and must not invent gameplay mechanics, formulas, architecture, or parallel implementations.

### 4.3 DeepSeek

**DeepSeek is used occasionally as a secondary development/reasoning aid.**

DeepSeek does not override this project's source-of-truth hierarchy. Any suggestion from DeepSeek must be checked against the live Supabase state, current GitHub code/migrations, and this document before being adopted.

### 4.4 Supabase

Supabase/Postgres is the authoritative live backend and game-state source of truth.

Database changes must be verified against the live project and represented by appropriate checked-in migrations when they are part of the repository's persistent schema/history.

### 4.5 Frontend/deployment tooling

The frontend stack is:

```text
React
TypeScript
Vite
Cloudflare
```

The deployed frontend is connected to the GitHub repository. Frontend changes must preserve the existing React architecture and must not casually modify unrelated visual/CSS systems.

### 4.6 Tool-selection rule

Use the appropriate tool for the job rather than creating overlapping implementations. The tool itself does not become the source of truth: project code, live Supabase state, migrations, and this document remain authoritative according to the hierarchy above.

## 5. Current project rules

- Do not invent historical Supabase migrations.
- Do not reset or destructively modify production data for cleanup.
- Do not change RLS/security merely because it is convenient while working on gameplay; security hardening is a final phase unless explicitly required by the current task.
- Do not create parallel state systems when an existing source of truth can be reused.
- Do not create duplicate SQL formulas in multiple consumers.
- Do not create duplicate frontend identity/planet resolution paths.
- GitHub Copilot may perform scoped implementation and mechanical refactors. Copilot must not invent gameplay mechanics or architecture.
- DeepSeek may be used occasionally for analysis/reasoning, but its suggestions are not authoritative until verified against project sources.
- Architecture, formulas, balance rules and Supabase integration decisions are reviewed before implementation.

## 6. Completed / accepted architectural decisions

### 6.1 Player → active planet → universe contract

The frontend refactor moved GalaxyView away from discovering the player/universe/homeworld independently.

Current intended flow:

```text
App
  ↓
activePlanet
  ├── playerId
  ├── universeId
  └── activePlanetId
       ↓
GalaxyView
```

GalaxyView must not independently query `players` to rediscover `universe_id` or query the homeworld to rediscover its origin planet.

### 6.2 Universe evolution and galaxy expansion are different systems

Never use one generic `evolution` formula to govern both.

```text
UNIVERSE EVOLUTION
    E(t)
    → rate/scaling changes

GALAXY/SYSTEM EXPANSION
    → creates systems/galaxies according to expansion rules
```

### 6.3 Central universe scaling

Canonical function:

```text
calculate_universe_scaling(E)
```

Canonical exponents:

```text
resource_economy_scale    = E^1
resource_production_scale = E^1
building_speed_scale      = E^0.5
research_speed_scale      = E^0.5
fleet_movement_scale      = E^(1/3)
lifeform_speed_scale      = E^0.5
```

Example:

```text
E = 100

resource economy    = 100
resource production = 100
building            = 10
research             = 10
fleet movement      = 4.6415888336
lifeform             = 10
```

The scaling function performs only the transformation from `E` to category-specific scaling factors.

It must not contain:

- classic rates
- technologies
- planet bonuses
- lifeform bonuses
- items
- events
- alliances
- mission-specific modifiers

### 6.4 Modifier pipeline

Conceptual order:

```text
classic/base rate
    → universe evolution scaling
    → technology / planet / lifeform modifiers
    → item / event / alliance modifiers
    → mission-specific modifiers
    → final effective rate
```

Future modifiers must declare whether they are multiplicative, additive percentage, cap, or override.

### 6.5 Resource naming warning

`economy` and `production` are semantically ambiguous.

Canonical names are:

```text
resource_economy_scale
resource_production_scale
```

Both currently scale with `E^1` and may produce an intentional `E²` contribution when both classic stages are applied.

Do not merge them without auditing their real consumers first.

### 6.6 Fleet movement and expeditions

There is one evolution movement scaling:

```text
fleet_movement_scale = E^(1/3)
```

Normal fleet missions and expeditions share this scaling.

Expeditions may have mission-specific modifiers, but must not have a second evolution exponent.

### 6.7 Fleet travel time

The engine uses a centralized travel-time helper based structurally on the non-linear OGame/OGameX model.

Reference geometry:

```text
same coordinate:       5
same system:           1000 + 5 * |Δposition|
different system:      2700 + 95 * |Δsystem|
different galaxy:      20000 * |Δgalaxy|
```

Reference time formula:

```text
FlightTime =
    round(
        (
            (35000 / speed_percent)
            * sqrt(distance * 10 / slowest_ship_speed)
            + 10
        )
        / effective_fleet_rate
    )
```

This is a reference/adaptation, not a command to copy every OGame mechanic.

## 7. Universe evolution process

The universe has an internal time/evolution process that must continue correctly across downtime by comparing stored timestamps and catching up pending work. Do not replace this with a client-only timer.

The heartbeat/clock chain has already been audited so the universe tick routes through the full planet tick rather than bypassing building/research completion logic.

Do not reintroduce the old local-only path into the universe tick without a new audit proving why it is required.

## 8. Galaxy expansion rules currently agreed

Normal galaxies:

```text
systems generated sequentially
new-system interval = 8 × G^0.75 hours
```

Production universe scope currently includes 100 normal galaxies.

Special galaxy event:

- global roll every 12 real hours;
- 1% success chance;
- successful event creates one special galaxy after G100;
- special galaxy starts with 10 systems;
- special-system generation uses its own formula and must not reuse the normal-galaxy expansion formula.

Do not confuse these expansion formulas with `calculate_universe_scaling(E)`.

## 9. AI planet population

AI planet population should scale with total available universe space and target roughly 5–10% occupied slots, within a defined tolerance.

When universe space expands, population logic should evaluate whether additional AI planets are required.

Do not invent a new population table if existing universe population state can represent the required process.

## 10. Current open audits

### OPEN — fleet dispatch convergence

Every fleet dispatch entrypoint must use the canonical travel-time helper for the persisted arrival time.

Audit at minimum:

```text
start_fleet
start_fleet_mixed
start_colonize_fleet
expedition dispatch
future mission-specific dispatch
```

### OPEN — resource semantics

Audit all consumers of `resource_economy_scale` and `resource_production_scale`.

Determine whether they are truly separate classic stages or whether one name is obsolete. Do not change the formula until the consumers are understood.

### OPEN — modifier ordering

For every final rate, document exactly where classic rate, evolution scaling, technology, planet, lifeform, item, event, alliance and mission modifiers enter.

### OPEN — base fleet travel-time calibration

At `E = 1`, validate actual travel times for:

```text
1:1:1 → 1:1:2
1:1:1 → 1:2:1
1:1:1 → 2:1:1
```

using real ship definitions from this project.

## 11. Completed work that must NOT be accidentally repeated

- GalaxyView no longer independently resolves `universe_id` from `players`.
- GalaxyView no longer independently resolves the homeworld as the fleet origin.
- The universe tick was routed through the full `process_planet_tick` path after an audit of completion ordering and locks.
- Central universe scaling was introduced rather than scattering roots/cube roots through consumers.
- Fleet and expedition evolution scaling were unified.
- Wallpaper/CSS work must not be casually rewritten. If visual-layer changes are proposed, inspect the current CSS architecture and existing wallpaper authority first.

## 12. Wallpaper / CSS protection rule

A previous wallpaper/CSS regression consumed significant development time. Therefore:

> **Never change wallpaper, background authority, overlay order, or global CSS reset rules while performing unrelated gameplay work.**

Before any CSS/wallpaper change:

1. inspect the current implementation;
2. identify the authoritative layer;
3. preserve the existing working behavior;
4. make the smallest possible change;
5. run the relevant build/test check;
6. document the result.

## 13. Documentation protocol — persistent project memory

`docs/PROJECT_CONTEXT_PROMPT.md` is the persistent memory of the project.

After **every important step** — especially architectural decisions, formula decisions, database changes, refactors, audits, tool/workflow changes, and completed fixes — update:

1. this file with the new canonical state;
2. the relevant subsystem monitor;
3. the README only when project-level orientation changes.

The document must be used as feedback, not merely stored passively. Before implementing a change, consult it to determine whether the concept already exists, which function/table/naming is canonical, and what work is already CLOSED or OPEN.

When something is deliberately deferred, record it as `OPEN` rather than silently forgetting it.

When something is finished, record it as `CLOSED` and include enough detail to prevent it from being repeated.

When a decision is superseded, mark the old decision as `SUPERSEDED` and point to the replacement.

## 14. Copilot task protocol

Give GitHub Copilot small, bounded tasks.

Every task should specify:

```text
SCOPE
FILES
DO NOT TOUCH
EXPECTED RESULT
VALIDATION
```

Copilot must not:

- invent formulas;
- rename canonical concepts without instruction;
- create parallel Supabase functions;
- change security while doing unrelated work;
- rewrite CSS/wallpaper while doing gameplay work;
- delete code merely because it looks unused without tracing consumers.

## 15. Session recovery protocol

If context is uncertain, stop and re-read this file plus the relevant monitor. Do not answer from an old remembered state.

At every new session, use this sequence:

```text
1. Read docs/PROJECT_CONTEXT_PROMPT.md.
2. What is the current HEAD?
3. What changed since the last documented checkpoint?
4. Which decisions are CLOSED?
5. Which audits are OPEN?
6. Is the requested change already implemented?
7. What is the smallest safe next step?
8. What documentation must be updated after it?
```

This protocol applies even when previous conversation context appears to be available: the repository documentation remains the persistent project memory.

## 16. Golden rule

> **Never solve a problem twice because the session forgot that it was already solved. Never create a second implementation because the first one was not discovered. Never change a working subsystem while solving an unrelated problem.**

This file is a living contract and persistent project memory. When an important architectural decision changes, update it immediately.
