# PROJECT CONTEXT — LA GRAN IMPLOSIÓN

> **Purpose:** compact operational memory for continuing development safely across sessions.
>
> This file is the project's **operational control panel**, not its encyclopedia. It records the current state, active decisions, OPEN/CLOSED work, canonical rules and navigation. Durable technical knowledge belongs in the specialized README files and living monitors linked below.

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
9. After meaningful work, update the specialized README/monitor when durable knowledge changes and update this file when operational state, decisions or OPEN/CLOSED status changes.

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
SPECIALIZED PROJECT DOCUMENTATION / LIVING MONITORS
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

Runtime boundary:

```text
src/       → presentation/client integration
worker/    → Cloudflare HTTP/assets boundary
supabase/  → authoritative game engine/schema/migrations
```

Important architectural decisions:

- Universe evolution and galaxy/system expansion are different systems.
- Rate-modifiable gameplay functions apply their normal/classic modifiers first and then the applicable universe-evolution modifier.
- The universe clock is persistent/server-independent and must recover missed work after downtime.
- Test objects/data remain isolated from the production universe.
- Game rules must not be duplicated in the frontend.

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

Detailed formulas and modifier semantics belong in the living rate/fleet monitor and evolution documentation.

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

The **first-pass OGameX → L.G.I. subsystem map is now established**. The current high-value deep-audit targets are fleet mission lifecycle, temporal events, combat boundaries and deferred processing.

Detailed methodology and map: [`reference/README_OGAMEX.md`](reference/README_OGAMEX.md) → [`reference/OGAMEX_LGI_MAP.md`](reference/OGAMEX_LGI_MAP.md)

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

The current engine manifest records the temporal engine as implemented in Supabase: persisted `universe_clock`, `process_universe_clock(uuid)`, `process_universe_heartbeat()`, a one-minute `universe-heartbeat` `pg_cron` job and a separate fleet-event worker. The remaining work is validation/convergence, not assuming the scheduler is the source of game time. [`supabase/ENGINE_MANIFEST.md`](../supabase/ENGINE_MANIFEST.md)

Detailed formulas, scheduling, catch-up and unresolved evolution issues: [`systems/README_UNIVERSE_EVOLUTION.md`](systems/README_UNIVERSE_EVOLUTION.md) and [`UNIVERSE_RATE_AND_FLEET_ENGINE_MONITOR.md`](UNIVERSE_RATE_AND_FLEET_ENGINE_MONITOR.md)

### Protected UI area

Wallpaper/background behavior is a protected area. Gameplay work must not casually alter established CSS/background authority. Create a dedicated UI/CSS README when a frontend audit makes that worthwhile.

---

## 8. Current OPEN Work

### OPEN — Fleet / mission convergence — HIGH

Audit fleet dispatch, mission state transitions, arrival/return resolution and persisted travel times against the current implementation and the OGameX mission lifecycle reference.

### OPEN — OGameX subsystem deep audits

The structural map is complete at first-pass level. Deep comparison is now performed only where it can expose a concrete architectural gap, beginning with fleet missions/events and then combat/background processing.

### OPEN — Economy semantics — MEDIUM

Audit resource balances, production/consumption semantics and modifier ordering against the current database/functions. The canonical rate/fleet monitor identifies `resource_economy_scale` vs `resource_production_scale` as an unresolved semantic audit.

### OPEN — Universe evolution validation — MEDIUM

The persistent clock/catch-up/heartbeat architecture exists in the current Supabase engine. Validate ordering, idempotency, overdue processing and scheduler/runtime contracts rather than redesigning the clock from scratch.

### OPEN — Final security/RLS hardening — LOW / FINAL PHASE

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
- The first-pass OGameX → L.G.I. structural map is established; subsystem-specific audits remain open.

Detailed architectural history: [`architecture/README_ARCHITECTURE.md`](architecture/README_ARCHITECTURE.md)

---

## 10. Documentation & Memory System

The project uses a three-layer continuity model:

```text
Persistent ChatGPT memory
        ↕
PROJECT_CONTEXT_PROMPT.md
        ↕
Specialized READMEs / living monitors
        ↕
Real repository + Supabase state
```

Use each layer for its intended purpose:

- **Persistent memory:** cross-session principles, important decisions and continuity.
- **PROJECT_CONTEXT_PROMPT.md:** compact current state, active decisions, OPEN/CLOSED work and navigation.
- **Specialized READMEs/monitors:** detailed durable knowledge and system-specific audit state.
- **Repository/Supabase:** actual implementation and live state.

When a document becomes too large, **segregate before deleting**. Move durable detail to an appropriate README, leave a concise summary/link here, and preserve traceability. Only remove information after it has been confirmed obsolete, duplicated or genuinely useless.

System rules: [`README_MEMORY_SYSTEM.md`](README_MEMORY_SYSTEM.md)

---

## 11. Session Recovery

At the beginning of a substantial session:

1. Recover persistent memory/context.
2. Read this file.
3. Follow only the specialized README/monitor links relevant to the task.
4. Inspect current Git/repository state.
5. Inspect Supabase when backend state matters.
6. Reconcile documentation with reality before modifying anything.

At the end of meaningful work:

1. Update the relevant specialized README/monitor if durable knowledge changed.
2. Update this file if operational state or OPEN/CLOSED decisions changed.
3. Preserve traceability for superseded decisions.
4. Leave the repository testable and recoverable.

---

## 12. Specialized Documentation Index

| Area | Document | Role |
|---|---|---|
| Memory/documentation | [`README_MEMORY_SYSTEM.md`](README_MEMORY_SYSTEM.md) | Rules for memory and documentation segregation |
| Architecture | [`architecture/README_ARCHITECTURE.md`](architecture/README_ARCHITECTURE.md) | Durable architecture and design decisions |
| OGameX | [`reference/README_OGAMEX.md`](reference/README_OGAMEX.md) | OGameX reference index and method |
| OGameX map | [`reference/OGAMEX_LGI_MAP.md`](reference/OGAMEX_LGI_MAP.md) | Concrete OGameX → L.G.I. subsystem comparison |
| Universe evolution | [`systems/README_UNIVERSE_EVOLUTION.md`](systems/README_UNIVERSE_EVOLUTION.md) | Evolution formulas, clock, catch-up, galaxies and AI |
| Rate/fleet monitor | [`UNIVERSE_RATE_AND_FLEET_ENGINE_MONITOR.md`](UNIVERSE_RATE_AND_FLEET_ENGINE_MONITOR.md) | Canonical scaling, travel-time and fleet integration audit |
| Development workflow | [`tools/README_DEVELOPMENT_WORKFLOW.md`](tools/README_DEVELOPMENT_WORKFLOW.md) | ChatGPT, Cline, Qwen, Copilot and tool responsibilities |
| Production DB | [`PRODUCTION_DB_BASELINE.md`](PRODUCTION_DB_BASELINE.md) | Production database/source-of-truth baseline |
| Supabase engine | [`../supabase/ENGINE_MANIFEST.md`](../supabase/ENGINE_MANIFEST.md) | Current backend engine/runtime boundary and scheduler status |

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
