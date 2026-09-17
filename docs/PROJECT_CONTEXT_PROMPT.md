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
6. Before designing a substantial new gameplay/backend system, check whether OGameX contains a relevant conceptual pattern.
7. Preserve completed work unless there is a documented reason to change it.
8. Do not resurrect obsolete architecture because it appeared in an older conversation.
9. If current code contradicts this document, treat the contradiction as an audit finding and verify the live code/database before changing anything.
10. After every important architectural, gameplay, database, tooling, or integration step, update this document and the relevant monitor with the new canonical state.
11. Use this document as active feedback during implementation: before creating or renaming anything, check its terminology, CLOSED decisions, OPEN audits, and existing implementation notes to avoid duplication and preserve cohesion.

## 3. Source-of-truth hierarchy

When sources disagree, verify in this order:

```text
LIVE SUPABASE GAME STATE / DEFINITIONS
        ↓
CURRENT GITHUB CODE + CHECKED-IN MIGRATIONS
        ↓
CURRENT LIVING DOCS IN docs/
        ↓
RELEVANT OGameX REFERENCE/PATTERN ANALYSIS
        ↓
RECENT AUDIT RESULTS
        ↓
OLD SESSION CONVERSATIONS
        ↓
GENERAL MEMORY / ASSUMPTIONS
```

OGameX is **not** a source of truth for La Gran Implosión's rules or current implementation. It is a reference library for conceptual patterns, established approaches, formulas and architecture. Conversation history is context, not proof of the current repository state.

## 4. Tools and implementation workflow

The project uses the following tools as part of its development workflow. Tools have different responsibilities and must not become competing sources of truth.

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

### 4.2 ChatGPT / project architecture layer

ChatGPT is the architecture, analysis, audit and coordination layer for the project.

Responsibilities include:

- recovering project context;
- auditing the real repository/Supabase state;
- designing gameplay mechanics and architecture;
- comparing candidate designs against OGameX patterns;
- deciding what should and should not be implemented;
- defining formulas, state transitions, naming and integration contracts;
- reviewing implementation results;
- coordinating Cline/Qwen/Copilot and other development tools;
- updating the persistent project context.

ChatGPT must not treat OGameX as an instruction to copy architecture. It must first understand the problem and then produce a project-specific L.G.I. specification.

### 4.3 OGameX — permanent pattern/reference library

**OGameX is a permanent architectural and gameplay-pattern reference for La Gran Implosión, not a dependency.**

Before designing a substantial new system from scratch, search OGameX for a conceptual equivalent when one is likely to exist.

Study, as applicable:

- domain entities;
- services/actions;
- state models;
- state transitions;
- mission processing;
- events;
- jobs/workers/queues;
- validation and error handling;
- formulas and calculation structure;
- persistence boundaries;
- separation of responsibilities;
- tests and fixtures.

The mandatory principle is:

```text
NEVER COPY BLINDLY

study → understand → compare → adapt → validate
```

OGameX code, Laravel structure, ORM choices and implementation details must not be transplanted directly into L.G.I. unless explicitly justified. We adapt the **problem-solving pattern** to Supabase/Postgres, RPC/Edge Functions/workers, React and TypeScript.

The conceptual map should record, where relevant:

```text
OGameX reference
→ what problem it solves
→ relevant entities/states/transitions
→ L.G.I. equivalent
→ current gap
→ recommended reference area
→ what NOT to copy
→ validation required
```

OGameX is also an **audit reference**, not only a design reference. It may expose missing concepts, duplicated responsibilities or incomplete state handling in L.G.I.; such findings must still be verified against our actual requirements before changes are made.

### 4.4 Cline

**Cline is the repository-level implementation agent.**

Cline works on the local repository under a bounded task specification produced after architecture/design decisions have been established.

Cline is responsible for:

- reading and tracing the current repository;
- modifying scoped files;
- implementing approved specifications;
- running build/tests/checks where available;
- reporting changes and validation results.

Cline must not independently invent gameplay mechanics, formulas, architectural contracts or canonical naming. When OGameX is relevant, Cline should receive the already-interpreted L.G.I. specification rather than being told simply to copy or reproduce OGameX.

### 4.5 Qwen + LM Studio

**Qwen running locally through LM Studio is an execution/reasoning resource used with the local development workflow, including Cline where configured.**

Qwen does not become an independent source of truth. Its output must remain constrained by this context, the repository, the approved task specification and validation results.

For large or risky changes, prefer small tasks and explicit file/scope boundaries so local model output remains auditable.

### 4.6 GitHub Copilot

**GitHub Copilot is an implementation assistant for scoped code changes and mechanical refactors.**

Copilot is used after architecture, formulas, naming, and intended behavior have been established.

Copilot must follow this context document and must not invent gameplay mechanics, formulas, architecture, or parallel implementations.

### 4.7 DeepSeek

**DeepSeek is used occasionally as a secondary development/reasoning aid.**

DeepSeek does not override this project's source-of-truth hierarchy. Any suggestion from DeepSeek must be checked against the live Supabase state, current GitHub code/migrations, relevant OGameX pattern analysis, and this document before being adopted.

### 4.8 Supabase

Supabase/Postgres is the authoritative live backend and game-state source of truth.

Database changes must be verified against the live project and represented by appropriate checked-in migrations when they are part of the repository's persistent schema/history.

### 4.9 Frontend/deployment tooling

The frontend stack is:

```text
React
TypeScript
Vite
Cloudflare
```

The deployed frontend is connected to the GitHub repository. Frontend changes must preserve the existing React architecture and must not casually modify unrelated visual/CSS systems.

### 4.10 Tool-selection rule

Use the appropriate tool for the job rather than creating overlapping implementations. The tool itself does not become the source of truth: project code, live Supabase state, migrations, and this document remain authoritative according to the hierarchy above.

## 5. Integrated development workflow

The complete development loop now combines project continuity, OGameX pattern research, architecture, implementation agents and validation.

```text
MEMORY + PROJECT_CONTEXT.md
              ↓
       RECOVER CURRENT STATE
              ↓
        AUDIT REAL L.G.I.
              ↓
     Does OGameX have a relevant
       conceptual equivalent?
          ↙             ↘
        YES              NO
         ↓                ↓
  STUDY THE PATTERN   DESIGN FROM OUR
         ↓              OWN REQUIREMENTS
         └───────┬────────┘
                 ↓
       DESIGN L.G.I.-SPECIFIC
            ARCHITECTURE
                 ↓
       BOUNDED IMPLEMENTATION TASK
                 ↓
        CLINE + QWEN / COPILOT
                 ↓
          BUILD / TEST / CHECK
                 ↓
          AUDIT IMPLEMENTATION
                 ↓
       VERIFY SUPABASE + INTEGRATION
                 ↓
         UPDATE PROJECT CONTEXT
                 ↓
               MEMORY
                 ↺
```

The key separation is:

```text
OGameX        = pattern/reference knowledge
ChatGPT       = interpretation + architecture + coordination
Cline/Qwen    = repository execution
Copilot       = scoped implementation/refactoring
Supabase      = live backend/game-state authority
GitHub        = code/history/documentation authority
PROJECT_CTX   = operational project memory
Memory        = cross-session continuity
```

### 5.1 Example: implementing a new fleet mission

Do **not** use:

```text
"Look at OGameX and implement fleet missions."
```

Use:

```text
1. Identify the L.G.I. requirement.
2. Find the conceptual OGameX mission pattern.
3. Study states, transitions, validation, persistence, events and workers.
4. Compare those concepts with existing L.G.I. tables/functions.
5. Define the L.G.I.-specific architecture.
6. Define exactly what must not be copied from Laravel/ORM architecture.
7. Give Cline/Qwen or Copilot a bounded implementation task.
8. Build/test/audit the result.
9. Update this document and the relevant monitor.
```

### 5.2 OGameX as an audit lens

When an L.G.I. subsystem already exists, OGameX may be used to ask:

```text
What concepts exist in the reference implementation?
What concepts exist in L.G.I.?
What is intentionally different?
What appears missing?
What appears duplicated?
What requires validation before changing anything?
```

A difference is **not automatically a bug**. L.G.I. has its own rules and architecture. Differences become audit findings only when they conflict with an explicit L.G.I. requirement or reveal an unhandled domain concern.

### 5.3 Bounded agent task protocol

Every implementation task given to Cline/Qwen or Copilot should specify:

```text
SCOPE
FILES / AREAS
DO NOT TOUCH
KNOWN CANONICAL FUNCTIONS/TABLES
EXPECTED RESULT
VALIDATION
```

Agents should receive the **L.G.I. specification**, not an instruction to reproduce an external repository.

## 6. Current project rules

- Do not invent historical Supabase migrations.
- Do not reset or destructively modify production data for cleanup.
- Do not change RLS/security merely because it is convenient while working on gameplay; security hardening is a final phase unless explicitly required by the current task.
- Do not create parallel state systems when an existing source of truth can be reused.
- Do not create duplicate SQL formulas in multiple consumers.
- Do not create duplicate frontend identity/planet resolution paths.
- Do not copy OGameX/Laravel architecture directly into L.G.I.; extract and adapt conceptual patterns.
- Do not assume an OGameX difference is an error in L.G.I. without checking our requirements.
- GitHub Copilot may perform scoped implementation and mechanical refactors. Copilot must not invent gameplay mechanics or architecture.
- Cline/Qwen may implement approved bounded tasks but must not invent gameplay mechanics or architecture.
- DeepSeek may be used occasionally for analysis/reasoning, but its suggestions are not authoritative until verified against project sources.
- Architecture, formulas, balance rules and Supabase integration decisions are reviewed before implementation.

## 7. Completed / accepted architectural decisions

### 7.1 Player → active planet → universe contract

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

### 7.2 Universe evolution and galaxy expansion are different systems

Never use one generic `evolution` formula to govern both.

```text
UNIVERSE EVOLUTION
    E(t)
    → rate/scaling changes

GALAXY/SYSTEM EXPANSION
    → creates systems/galaxies according to expansion rules
```

### 7.3 Central universe scaling

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

### 7.4 Modifier pipeline

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

### 7.5 Resource naming warning

`economy` and `production` are semantically ambiguous.

Canonical names are:

```text
resource_economy_scale
resource_production_scale
```

Both currently scale with `E^1` and may produce an intentional `E²` contribution when both classic stages are applied.

Do not merge them without auditing their real consumers first.

### 7.6 Fleet movement and expeditions

There is one evolution movement scaling:

```text
fleet_movement_scale = E^(1/3)
```

Normal fleet missions and expeditions share this scaling.

Expeditions may have mission-specific modifiers, but must not have a second evolution exponent.

### 7.7 Fleet travel time

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

## 8. Universe evolution process

The universe has an internal time/evolution process that must continue correctly across downtime by comparing stored timestamps and catching up pending work. Do not replace this with a client-only timer.

The heartbeat/clock chain has already been audited so the universe tick routes through the full planet tick rather than bypassing building/research completion logic.

Do not reintroduce the old local-only path into the universe tick without a new audit proving why it is required.

## 9. Galaxy expansion rules currently agreed

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

## 10. AI planet population

AI planet population should scale with total available universe space and target roughly 5–10% occupied slots, within a defined tolerance.

When universe space expands, population logic should evaluate whether additional AI planets are required.

Do not invent a new population table if existing universe population state can represent the required process.

## 11. Current open audits

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

### OPEN — OGameX → L.G.I. subsystem map

Build and maintain a conceptual map for the relevant OGameX areas:

```text
OGameX reference
→ problem/domain
→ entities
→ states/transitions
→ services/actions/jobs/events
→ L.G.I. equivalent
→ gaps
→ intentional differences
→ recommended study area
→ validation
```

This map should be built where it materially helps design or audit work, rather than mechanically mapping every file in OGameX.

## 12. Completed work that must NOT be accidentally repeated

- GalaxyView no longer independently resolves `universe_id` from `players`.
- GalaxyView no longer independently resolves the homeworld as the fleet origin.
- The universe tick was routed through the full `process_planet_tick` path after an audit of completion ordering and locks.
- Central universe scaling was introduced rather than scattering roots/cube roots through consumers.
- Fleet and expedition evolution scaling were unified.
- Wallpaper/CSS work must not be casually rewritten. If visual-layer changes are proposed, inspect the current CSS architecture and existing wallpaper authority first.

## 13. Wallpaper / CSS protection rule

A previous wallpaper/CSS regression consumed significant development time. Therefore:

> **Never change wallpaper, background authority, overlay order, or global CSS reset rules while performing unrelated gameplay work.**

Before any CSS/wallpaper change:

1. inspect the current implementation;
2. identify the authoritative layer;
3. preserve the existing working behavior;
4. make the smallest possible change;
5. run the relevant build/test check;
6. document the result.

## 14. Documentation protocol — persistent project memory

`docs/PROJECT_CONTEXT_PROMPT.md` is the persistent memory of the project.

After **every important step** — especially architectural decisions, formula decisions, database changes, refactors, audits, tool/workflow changes, and completed fixes — update:

1. this file with the new canonical state;
2. the relevant subsystem monitor;
3. the README only when project-level orientation changes.

The document must be used as feedback, not merely stored passively. Before implementing a change, consult it to determine whether the concept already exists, which function/table/naming is canonical, and what work is already CLOSED or OPEN.

When something is deliberately deferred, record it as `OPEN` rather than silently forgetting it.

When something is finished, record it as `CLOSED` and include enough detail to prevent it from being repeated.

When a decision is superseded, mark the old decision as `SUPERSEDED` and point to the replacement.

## 15. Copilot task protocol

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

## 16. Cline/Qwen task protocol

Cline/Qwen tasks follow the same bounded-execution principle, but are intended for repository-level work where local inspection, multi-file tracing or implementation is useful.

Before execution, the task must define:

```text
OBJECTIVE
SCOPE
FILES / AREAS
CANONICAL FUNCTIONS / TABLES
DO NOT TOUCH
EXPECTED RESULT
VALIDATION
```

If the task is based on OGameX, provide the **interpreted L.G.I. pattern and acceptance criteria**. Do not instruct the agent to copy OGameX directly.

After execution, inspect the diff and validation results before accepting the work.

## 17. Session recovery protocol

If context is uncertain, stop and re-read this file plus the relevant monitor. Do not answer from an old remembered state.

At every new session, use this sequence:

```text
1. Read docs/PROJECT_CONTEXT_PROMPT.md.
2. What is the current HEAD?
3. What changed since the last documented checkpoint?
4. Which decisions are CLOSED?
5. Which audits are OPEN?
6. Is the requested change already implemented?
7. Does OGameX contain a relevant conceptual pattern?
8. What is the smallest safe L.G.I.-specific next step?
9. What documentation must be updated after it?
```

This protocol applies even when previous conversation context appears to be available: the repository documentation remains the persistent project memory.

## 18. Golden rule

> **Never solve a problem twice because the session forgot that it was already solved. Never create a second implementation because the first one was not discovered. Never change a working subsystem while solving an unrelated problem. Never copy an external architecture when a project-specific adaptation is required.**

This file is a living contract and persistent project memory. When an important architectural decision changes, update it immediately.
