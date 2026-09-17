# PROJECT CONTEXT — LA GRAN IMPLOSIÓN

> **Purpose:** compact operational memory for continuing development safely across sessions.
>
> This file is the project's **operational control panel**, not its encyclopedia. It records the current state, active decisions, OPEN/CLOSED work, canonical rules and navigation. Durable technical knowledge belongs in the specialized README files linked below.

---

## 1. Mission

La Gran Implosión is an OGame-like browser game built with React/TypeScript/Vite on the frontend and Supabase/Postgres as the game backend.

The project aims to reproduce useful genre concepts while allowing its own mechanics, architecture and universe-evolution model. OGameX is a reference, never a dependency or authority over L.G.I. rules.

---

## 2. Operating Rules

Before substantial work:

1. Recover this context and the relevant specialized documentation.
2. Inspect the real repository/Git state and Supabase state when applicable.
3. Check whether the requested functionality already exists before creating anything new.
4. Preserve completed work unless there is a documented reason to change it.
5. Treat contradictions between documentation and implementation as audit findings; verify before changing anything.
6. For substantial new systems, check OGameX for a useful conceptual pattern before designing from scratch.
7. Give implementation agents bounded, project-specific specifications; do not delegate architecture invention implicitly.
8. Do not delete useful historical knowledge merely to reduce document size. Segregate durable detail into the appropriate README first.
9. After meaningful work, update the specialized README when durable knowledge changes and update this file when operational state, decisions or OPEN/CLOSED status changes.

Core loop:

`Context → audit → plan → implement → test → verify → document → update context`

Detailed tooling workflow: [`tools/README_DEVELOPMENT_WORKFLOW.md`](tools/README_DEVELOPMENT_WORKFLOW.md)

---

## 3. Source of Truth

Use the following hierarchy when sources disagree:

```text
LIVE SUPABASE STATE / DEFINITIONS
        ↓
CURRENT GITHUB CODE + CHECKED-IN MIGRATIONS
        ↓
SPECIALIZED PROJECT DOCUMENTATION
        ↓
PROJECT_CONTEXT_PROMPT.md
        ↓
OGameX REFERENCE / PATTERN ANALYSIS
        ↓
OLD SESSION CONVERSATIONS / ASSUMPTIONS
```

OGameX does **not** define L.G.I. rules. It is a reference library for conceptual patterns, established approaches, formulas and architecture.

Memory/documentation architecture: [`README_MEMORY_SYSTEM.md`](README_MEMORY_SYSTEM.md)

---

## 4. Current Architecture

Canonical high-level model:

`Player → active Planet → Universe`

Backend: Supabase/PostgreSQL.
Frontend: React/TypeScript/Vite.

Important architectural decisions:

- Universe evolution and galaxy/system expansion are different systems.
- Rate-modifiable gameplay functions apply their normal/classic modifiers first and then the applicable universe-evolution modifier.
- The universe clock is persistent/server-independent and must recover missed work after downtime.
- Test objects/data remain isolated from the production universe.

Detailed durable architecture: [`architecture/README_ARCHITECTURE.md`](architecture/README_ARCHITECTURE.md)

### Canonical scaling concepts

```text
calculate_universe_scaling(E)
resource_economy_scale
resource_production_scale
building_speed_scale
research_speed_scale
fleet_movement_scale
lifeform_speed_scale
```

Detailed formulas and modifier semantics belong in the architecture/evolution documents, not here.

---

## 5. Development Environment

Current responsibility model:

```text
ChatGPT       = architecture + audit + interpretation + coordination
OGameX        = pattern/reference knowledge
Cline + Qwen  = bounded repository execution
Copilot       = scoped implementation/refactoring
Supabase      = live backend/game-state authority
GitHub        = code/history/documentation authority
Memory        = cross-session continuity
PROJECT_CTX   = current operational context
```

No tool is the project's independent brain. Agents execute approved work; they do not redefine canonical gameplay or architecture without an explicit project decision.

Detailed workflow: [`tools/README_DEVELOPMENT_WORKFLOW.md`](tools/README_DEVELOPMENT_WORKFLOW.md)

---

## 6. OGameX Reference Layer

OGameX is a permanent architectural/gameplay-pattern reference, not a dependency.

Use:

`study → understand → compare → adapt → validate`

Compare concepts rather than files: entities, states, transitions, events, jobs/workers, validation, persistence boundaries, responsibilities, formulas and tests.

The output of OGameX research must be an **L.G.I.-specific specification** before implementation.

Detailed methodology and OGameX → L.G.I. mapping: [`reference/README_OGAMEX.md`](reference/README_OGAMEX.md)

---

## 7. Current Gameplay / Universe Decisions

### Universe evolution

- Persistent internal clock.
- Must progress conceptually while the site/server is offline.
- Resume processing detects elapsed time and catches up missed events.
- Normal galaxy system-expansion timing: `8 × G^0.75` hours per new system.
- Every 12 real hours: one global 1% roll for a special galaxy after G100.
- Special galaxies start with 10 systems and use a separate expansion formula.
- AI population targets roughly 5–10% of available universe slots, with tolerance and reconciliation as space expands.

Detailed formulas, scheduling, catch-up and unresolved evolution issues: [`systems/README_UNIVERSE_EVOLUTION.md`](systems/README_UNIVERSE_EVOLUTION.md)

### Protected UI area

Wallpaper/background behavior is a protected area. Gameplay work must not casually alter established CSS/background authority. Create a dedicated UI/CSS README when a frontend audit makes that worthwhile.

---

## 8. Current OPEN Work

### OPEN — OGameX → L.G.I. subsystem map

Build the useful conceptual mapping against the **real current L.G.I. implementation**. Do not map mechanically; prioritize systems where the reference can prevent architectural mistakes.

### OPEN — Fleet / mission convergence

Audit fleet dispatch, mission state transitions and arrival/resolution behavior against the current implementation and relevant OGameX patterns.

### OPEN — Economy semantics

Audit resource balances, production/consumption semantics and modifier ordering against the current database/functions.

### OPEN — Universe evolution process monitor

Design and validate the persistent clock/worker/catch-up process so universe evolution does not depend on a continuously running browser session.

### OPEN — Final security/RLS hardening

Security remains a final hardening phase unless a concrete defect requires earlier intervention. Deferred hardening is not permission to ignore an actual security issue.

Domain detail belongs in specialized documentation; this section records only active work and current priority.

---

## 9. Established / CLOSED Decisions

- Supabase is the backend authority.
- GitHub/repository state is the code/history authority.
- The project follows `Context → Audit → Plan → Implement → Test → Verify → Document`.
- OGameX is a reference layer, not a dependency.
- Player → active planet → universe is the canonical frontend/domain contract.
- Universe evolution is separate from galaxy/system expansion.
- Durable detail is segregated into specialized documentation.
- Historical decisions remain traceable; moving detail out of this file is not deletion.

Detailed architectural history: [`architecture/README_ARCHITECTURE.md`](architecture/README_ARCHITECTURE.md)

---

## 10. Documentation & Memory System

The project uses a three-layer continuity model:

```text
Persistent ChatGPT memory
        ↕
PROJECT_CONTEXT_PROMPT.md
        ↕
Specialized README files
        ↕
Real repository + Supabase state
```

Use each layer for its intended purpose:

- **Persistent memory:** cross-session principles, important decisions and continuity.
- **PROJECT_CONTEXT_PROMPT.md:** compact current state, active decisions, OPEN/CLOSED work and navigation.
- **Specialized READMEs:** detailed durable knowledge.
- **Repository/Supabase:** actual implementation and live state.

When a document becomes too large, **segregate before deleting**. Move durable detail to an appropriate README, leave a concise summary/link here, and preserve traceability. Only remove information after it has been confirmed obsolete, duplicated or genuinely useless.

System rules: [`README_MEMORY_SYSTEM.md`](README_MEMORY_SYSTEM.md)

---

## 11. Session Recovery

At the beginning of a substantial session:

1. Recover persistent memory/context.
2. Read this file.
3. Follow only the specialized README links relevant to the task.
4. Inspect current Git/repository state.
5. Inspect Supabase when backend state matters.
6. Reconcile documentation with reality before modifying anything.

At the end of meaningful work:

1. Update the relevant specialized README if durable knowledge changed.
2. Update this file if operational state or OPEN/CLOSED decisions changed.
3. Preserve traceability for superseded decisions.
4. Leave the repository testable and recoverable.

---

## 12. Specialized Documentation Index

| Area | Document | Role |
|---|---|---|
| Memory/documentation | [`README_MEMORY_SYSTEM.md`](README_MEMORY_SYSTEM.md) | Rules for memory and documentation segregation |
| Architecture | [`architecture/README_ARCHITECTURE.md`](architecture/README_ARCHITECTURE.md) | Durable architecture and design decisions |
| OGameX | [`reference/README_OGAMEX.md`](reference/README_OGAMEX.md) | OGameX patterns and OGameX → L.G.I. comparison |
| Universe evolution | [`systems/README_UNIVERSE_EVOLUTION.md`](systems/README_UNIVERSE_EVOLUTION.md) | Evolution formulas, clock, catch-up, galaxies and AI |
| Development workflow | [`tools/README_DEVELOPMENT_WORKFLOW.md`](tools/README_DEVELOPMENT_WORKFLOW.md) | ChatGPT, Cline, Qwen, Copilot and tool responsibilities |

Create another specialized README only when a domain contains enough durable knowledge to justify independent maintenance.

---

## 13. Golden Rule

> **Do not guess when the project can be inspected.**
>
> **Do not duplicate durable knowledge when it can be referenced.**
>
> **Do not delete useful history merely to make the context smaller.**
>
> Inspect → compare → decide → implement → test → document → preserve continuity.
