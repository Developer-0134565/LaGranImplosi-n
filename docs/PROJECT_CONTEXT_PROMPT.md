# PROJECT CONTEXT — LA GRAN IMPLOSIÓN

> **Purpose:** compact operational memory for continuing development safely across sessions.
>
> This file is the project's **operational control panel**, not its encyclopedia. Durable technical knowledge belongs in specialized README files and living monitors.

---

## 1. Mission

La Gran Implosión is an OGame-like browser game built with React/TypeScript/Vite on the frontend and Supabase/Postgres as the game backend.

The project may use established genre concepts while keeping its own mechanics, architecture and universe-evolution model. OGameX is a reference, never a dependency or authority over L.G.I. rules.

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
9. Implementation-agent prompts must be bounded to the known task and should not repeat repository-wide discovery after the initial map exists.
10. Before sending a Cline/DeepSeek prompt, state the Intelligence level and an expected cost band; use deeper/high-cost audits only when they materially reduce uncertainty.
11. Before implementing, reviewing, auditing or modifying anything, explicitly choose the most appropriate tool/agent for the task (ChatGPT, Cline + DeepSeek, Copilot, or Qwen/LM Studio) based on scope, difficulty, required access and cost. This choice is mandatory before execution.
12. After meaningful work, update the specialized README/monitor when durable knowledge changes and update this file when operational state, decisions or OPEN/CLOSED status changes.

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

Gameplay layers are validated in this order:

```text
1. BASIC GAME ENGINE
   construction / research / fleet / transport / attack / combat

2. TEMPORAL LAYER
   persistent clock / workers / events / catch-up / downtime recovery

3. UNIVERSE EVOLUTION
   evolving rates / expansion / special galaxies / AI population
```

The basic engine must be coherent and playable before temporal/evolution work is allowed to hide underlying gameplay defects.

Detailed durable architecture: [`architecture/README_ARCHITECTURE.md`](architecture/README_ARCHITECTURE.md)

---

## 5. Development Environment

Current responsibility model:

```text
ChatGPT              = architecture + audit + interpretation + coordination + tool/agent selection
Cline + DeepSeek     = primary heavy-duty execution/reasoning vessel for complex, multi-file, debugging and repository-wide-but-bounded operations
Copilot              = fast scoped implementation/refactoring for localized tasks
Qwen / LM Studio     = local laboratory, experimentation and alternative reasoning without API cost
OGameX               = pattern/reference knowledge
Supabase             = live backend/game-state authority
GitHub               = code/history/documentation authority
Memory               = cross-session continuity
PROJECT_CTX          = current operational context
```

### Mandatory tool-selection gate

Before **every** task that will implement, review, audit or modify project material, ChatGPT must first make an explicit tool/agent selection.

Decision principles:

- **ChatGPT:** architecture, system-level interpretation, audit design, cross-system decisions and final verification.
- **Cline + DeepSeek:** complex or multi-file implementation, difficult debugging, deep bounded audits and operations requiring repository execution. DeepSeek is the project's heavy-duty reasoning vessel, but must still be used cost-consciously.
- **Copilot:** small/localized implementation, UI components, CSS, TypeScript changes, straightforward refactors and mechanical fixes.
- **Qwen / LM Studio:** local experiments, prototypes, alternative reasoning and tasks where avoiding API cost is useful.

The selected tool is not automatically the one that performs the whole task: ChatGPT remains responsible for choosing the mission, defining boundaries and verifying the result.

For Cline/DeepSeek missions, always state:

- **🧠 Intelligence:** None / Low / Medium / High / Extra
- **💰 Cost expected:** LOW / MEDIUM / HIGH
- **🎯 Why:** short justification

Do not deploy the most powerful agent merely because it is available. Match the agent to the task, while reserving DeepSeek/Cline for missions where its additional reasoning/execution capability materially helps.

No tool is the project's independent brain. Agents execute approved work; they do not redefine canonical gameplay or architecture without an explicit project decision.

Detailed workflow: [`tools/README_DEVELOPMENT_WORKFLOW.md`](tools/README_DEVELOPMENT_WORKFLOW.md)

---

## 6. OGameX Reference Layer

OGameX is a permanent architectural/gameplay-pattern reference, not a dependency.

Use:

`study → understand → compare → adapt → validate`

The first-pass OGameX → L.G.I. subsystem map is established. Deep audits use it only where comparison can expose a concrete architectural gap.

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

**CLOSED — 2026-09-18:** Universe Evolution engine + observability + production deployment are validated end-to-end. Live engine tests covered clock catch-up, overdue batching, concurrency, failure/recovery, normal/special expansion, galaxy rolls and AI reconciliation. The monitor recovered from CATCHING_UP to HEALTHY, and the deployed production Overview showed lag 0s, 0 pending ticks, 0 expansion backlog, 0 galaxy rolls due and 0 AI deficit.

Detailed formulas, scheduling, catch-up, observability and deployment evidence:
- [`systems/README_UNIVERSE_EVOLUTION.md`](systems/README_UNIVERSE_EVOLUTION.md)
- [`systems/README_UNIVERSE_EVOLUTION_MONITOR.md`](systems/README_UNIVERSE_EVOLUTION_MONITOR.md)

### Protected UI area

Wallpaper/background behavior is a protected area. Gameplay work must not casually alter established CSS/background authority. Create a dedicated UI/CSS README when a frontend audit makes that worthwhile.

---

## 8. Current OPEN Work

### OPEN — BASIC GAME ENGINE AUDIT — HIGH

Current order:

1. 🏗️ Construction — **backend + integration validated; pending the user's browser test**
2. 🔬 Research — **CLOSED: backend/security contract + browser functional flow validated**
3. 🚀 Fleet movement — **OPEN / HIGH: propulsion + cargo + fuel integrated; colonize convergence fixed; remaining dispatch/return verification and browser certification**
4. 📦 Transport
5. ⚔️ Attack
6. 💥 Combat

Construction: the full lifecycle (validación → coste/tiempo → descuento atómico de recursos → cola → procesado → completado → persistencia de nivel → producción) is audited, with documented concurrency/idempotency guarantees (planet row lock + active-queue guard; queue row lock + `COMPLETED` early-return + `target = current+1` guard + PK upsert + `SKIP LOCKED` processors). The Buildings UI now consumes the authoritative `can_start_building()` contract (cost of the next level, level, availability + reason) and settles temporal state with `sync_current_planet_resources()`. Tests: `scripts/verify-buildings.mjs` (live, read-only) and `supabase/tests/buildings_lifecycle.sql` (transactional, non-committing). Remaining for certification: the user's browser functional test.

Living audit: [`systems/README_GAME_ENGINE_AUDIT.md`](systems/README_GAME_ENGINE_AUDIT.md)

### OPEN — OGameX subsystem deep audits

The structural map is complete at first-pass level. Deep comparison continues where it can expose a concrete architectural gap. Fleet is the current deep-audit target: propulsion technologies, ship prerequisites, cargo/fuel modifiers, distance and mission lifecycle are being compared against OGameX patterns.

### OPEN — Economy semantics — MEDIUM

Audit resource balances, production/consumption semantics and modifier ordering against the current database/functions. Do not mix future evolution semantics into the base-engine certification unless a concrete dependency requires it.

### CLOSED — Universe Evolution engine + monitor validation

Universe Evolution is now implemented and directly validated in live Supabase. The persistent clock, catch-up, normal/special galaxy expansion, galaxy-roll processing, AI reconciliation and heartbeat were tested with controlled overdue/concurrency/failure-recovery scenarios.

The operational monitor is also validated end-to-end. Active Universe 1 reached HEALTHY after a temporary CATCHING_UP state, with lag 0s, ticks due 0, expansion backlog 0, galaxy rolls due 0 and AI deficit 0.

Production deployment is also validated: Cloudflare Worker `lagranimplosion`, version `a5cba4c6-b82f-4c73-b445-f32fb887614`, served the Overview monitor successfully with the same healthy live state.

Detailed evolution and monitor state:
- [systems/README_UNIVERSE_EVOLUTION.md](systems/README_UNIVERSE_EVOLUTION.md)
- [systems/README_UNIVERSE_EVOLUTION_MONITOR.md](systems/README_UNIVERSE_EVOLUTION_MONITOR.md)

### CLOSED — Ownership Hardening — 2026-09-18

The ownership-hardening migration `20260918030000` is applied LIVE. Exactly six owned action/state RPCs were hardened: `start_building`, `start_research`, `start_ship`, `start_defense`, `start_fleet`, `sync_current_planet_resources`. Live verification confirms authenticated owners can enter the functions, foreign-player calls are rejected, and NULL `auth.uid()` is rejected. No unintended mutation was observed in the transactional rejection tests. Detailed evidence: [`systems/README_OWNERSHIP_HARDENING.md`](systems/README_OWNERSHIP_HARDENING.md).

### OPEN — Final security/RLS hardening — LOW / FINAL PHASE

Security remains a final hardening phase unless a concrete defect requires earlier intervention. Deferred hardening is not permission to ignore an actual security issue.

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
- Universe Evolution engine validation is closed for the currently implemented clock/catch-up/expansion/roll/AI/heartbeat surface.
- Universe Evolution Monitor validation is closed: sanitized public RPC + React UI + authenticated execution + recovery-to-HEALTHY were verified.
- Production deployment validation is closed for the current Universe Evolution monitor: Cloudflare Worker deployment + public Overview verification succeeded.
- Public monitor backend is versioned by migrations 20260918020000 through 20260918020300; the public RPC is intentionally callable by anon and authenticated, while the full monitor remains private.
- Basic-engine certification includes a user-performed web functional test; backend existence alone is insufficient.
- Research is now functionally closed: authoritative `can_start_research()` contract, security/ownership checks, regression battery and browser level-up/resource-deduction flow were validated.
- Ownership hardening is closed for the six critical player/planet action RPCs; the final security/RLS phase remains separate.
- Fleet engine deep audit is OPEN: player-aware propulsion/cargo/fuel integration is implemented; the live prerequisite graph is coherent; a real colonization travel-time divergence was found and corrected to the canonical movement pipeline; remaining dispatch/return verification and browser certification remain.
- The first DeepSeek/Cline recognition audit is an initial map, not a template for future broad scans: later prompts must be bounded and cost-aware.
- Production verification confirmed active pg_cron jobs for `universe-heartbeat` (1 minute) and `deuteria-fleet-worker` (1 second); the repository/dump alone did not expose those cron rows.

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
| Game engine audit | [`systems/README_GAME_ENGINE_AUDIT.md`](systems/README_GAME_ENGINE_AUDIT.md) | Living audit of construction/research/fleet/transport/attack/combat |
| Ownership hardening | [`systems/README_OWNERSHIP_HARDENING.md`](systems/README_OWNERSHIP_HARDENING.md) | Durable ownership/security audit for owned RPC entrypoints |
| OGameX | [`reference/README_OGAMEX.md`](reference/README_OGAMEX.md) | OGameX reference index and method |
| OGameX map | [`reference/OGAMEX_LGI_MAP.md`](reference/OGAMEX_LGI_MAP.md) | Concrete OGameX → L.G.I. subsystem comparison |
| Universe evolution | [`systems/README_UNIVERSE_EVOLUTION.md`](systems/README_UNIVERSE_EVOLUTION.md) | Evolution formulas, clock, catch-up, galaxies and AI |
| Universe evolution monitor | [`systems/README_UNIVERSE_EVOLUTION_MONITOR.md`](systems/README_UNIVERSE_EVOLUTION_MONITOR.md) | Read-only observability, public RPC contract, status semantics, validation and production deployment |
| Rate/fleet monitor | [`UNIVERSE_RATE_AND_FLEET_ENGINE_MONITOR.md`](UNIVERSE_RATE_AND_FLEET_ENGINE_MONITOR.md) | Canonical scaling, travel-time and fleet integration audit |
| Fleet engine | [`systems/README_FLEET_ENGINE.md`](systems/README_FLEET_ENGINE.md) | Ship prerequisites, propulsion, cargo, fuel and fleet-dispatch audit |
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
