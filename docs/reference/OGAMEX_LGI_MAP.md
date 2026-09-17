# OGameX → La Gran Implosión — First-Pass Subsystem Map

> **Status:** OPEN — first-pass structural map completed 2026-09-17.
>
> This document is a working bridge between the OGameX reference repository and the real current L.G.I. implementation. It is not a porting plan and does not imply feature parity.

## 1. Method

Use this map in the following order:

```text
OGameX structure
    ↓
concept / responsibility
    ↓
current L.G.I. implementation
    ↓
gap or convergence question
    ↓
L.G.I.-specific decision
```

Never copy Laravel/PHP/Eloquent structure into L.G.I. mechanically.

## 2. Current L.G.I. boundaries

The current repository separates responsibilities broadly as follows:

| Boundary | Current L.G.I. authority | Audit meaning |
|---|---|---|
| Frontend | `src/` | Presentation/client integration only |
| Edge boundary | Cloudflare Worker | HTTP/assets boundary, not the universe scheduler |
| Game engine | `supabase/` migrations + live Supabase | Authoritative gameplay state and rules |
| Documentation | `docs/` + engine manifests/monitors | Durable design and operational context |

The repository's engine manifest records economy, construction, research, shipyard, defense, fleet movement, combat, expeditions, lifeforms, universe evolution/clock/expansion, AI population and guest onboarding as currently audited engine areas. fileciteturn17file0L2-L2

## 3. First-pass mapping

| OGameX reference | Concept studied | Current L.G.I. counterpart | Status / next audit |
|---|---|---|---|
| `app/Models` | Persistent game entities | PostgreSQL/Supabase tables + generated `src/lib/database.types.ts` | **REFERENCE → AUDIT**: map canonical tables by domain |
| `app/GameObjects` | Domain objects / game concepts | SQL functions/RPC + table model | **REFERENCE → AUDIT**: avoid creating an ORM-like duplicate layer |
| `app/Actions` | Explicit operations | Supabase RPC/functions and controlled mutations | **AUDIT**: verify one authoritative entrypoint per operation |
| `app/Services` | Domain/business services | SQL/RPC engine functions, with orchestration in DB | **AUDIT**: identify duplicated business logic |
| `app/GameMissions` | Mission abstraction, mission-specific resolution | Fleet mission RPCs + fleet event/arrival processing | **OPEN — HIGH**: fleet dispatch convergence |
| `app/Jobs` | Deferred/background processing | Supabase `pg_cron` + timestamp-driven processing | **PARTIALLY CONVERGED**: evolution heartbeat and fleet worker exist; audit scheduler/runtime contracts |
| `app/Events` | Domain event processing | Timestamped fleet/universe event queues and settlement functions | **OPEN**: verify event ordering and idempotent resolution |
| `app/GameConstants` | Centralized rules/constants | SQL definitions/configuration and canonical monitor documents | **AUDIT**: locate remaining distributed constants |
| `app/GameMissions/Abstracts/GameMission.php` | Shared mission lifecycle concerns | Shared fleet/event model rather than PHP inheritance | **REFERENCE**: study lifecycle invariants, not class structure |
| `AttackMission.php` | Attack-specific mission resolution | Attack arrival/temporal settlement functions | **OPEN**: compare state transitions and combat boundary |
| `TransportMission.php` | Transport lifecycle and resource transfer | Fleet transport settlement path | **OPEN**: verify resource settlement and return semantics |
| `ColonisationMission.php` | Colonisation lifecycle | `start_colonize_fleet` and destination/universe validation | **OPEN**: audit mission-specific state transitions |
| `ExpeditionMission.php` | Expedition dispatch/outcome lifecycle | Expedition dispatch + expedition outcome processing | **OPEN**: verify shared movement scaling and outcome boundaries |
| `DeploymentMission.php` | Deployment/return semantics | Fleet movement/arrival processing | **REFERENCE → AUDIT** |
| `BattleEngine/` | Combat resolution separated from mission dispatch | Current L.G.I. combat engine | **REFERENCE → AUDIT**: compare boundaries, inputs, outputs and persistence |
| `database/migrations` | Versioned schema evolution | `supabase/migrations` | **CONVERGED**: same conceptual role, different stack |
| `database/seeds` / factories | Controlled test data | Supabase fixtures/seeds/test helpers | **AUDIT**: identify canonical test-data path |
| `resources/js` / `resources/css` | Frontend organization | React/TypeScript `src/` + CSS modules/files | **REFERENCE**: architectural inspiration only |
| `routes` | HTTP/application entrypoints | Cloudflare Worker + Supabase RPC/API boundaries | **REFERENCE**: keep game rules out of client/edge presentation |

OGameX's current repository visibly separates `Actions`, `Events`, `GameConstants`, `GameMissions`, `GameObjects`, `Jobs`, `Models` and `Services` under `app/`, while its mission package contains a shared `GameMission` abstraction plus concrete attack, transport, colonisation, deployment and expedition missions. fileciteturn15file0L2-L2 fileciteturn16file0L2-L2

## 4. High-value architectural findings

### 4.1 Mission lifecycle is the most useful immediate comparison

OGameX gives us a strong conceptual decomposition:

```text
mission creation
    ↓
mission-specific validation
    ↓
flight / scheduled state
    ↓
arrival
    ↓
mission-specific resolution
    ↓
return / final settlement
```

L.G.I. already has a timestamp/event architecture for fleet arrivals and universe processing. The next job is therefore **convergence auditing**, not designing another mission framework.

### 4.2 Jobs/workers map to L.G.I. scheduling, but not 1:1

OGameX has `app/Jobs`; L.G.I. currently uses database scheduling. The engine manifest records:

- `universe_clock` with persisted `last_tick_at` / `next_tick_at`;
- `process_universe_clock(uuid)` for overdue catch-up;
- `process_universe_heartbeat()` for active-universe processing;
- a live one-minute `universe-heartbeat` `pg_cron` job;
- a separate one-second fleet-event worker.

Therefore the useful OGameX lesson is **deferred work as a domain boundary**, not Laravel's queue implementation. fileciteturn17file0L2-L2

### 4.3 Events should be compared as state transitions

Do not create an L.G.I. event bus simply because OGameX has `app/Events`. The useful question is:

> Which state transitions need durable timestamps, ordering, idempotency and atomic settlement?

This is especially relevant to fleet arrival, attack resolution, resource rewards and universe catch-up.

### 4.4 Models are not an invitation to create an ORM layer

OGameX's models represent persistent entities. In L.G.I., PostgreSQL tables, constraints, RPCs and generated types already form the persistence boundary. The mapping should therefore preserve **domain ownership**, not imitate Eloquent classes.

## 5. Current L.G.I. audit targets

### A — Fleet dispatch convergence — OPEN / HIGH

Known dispatch entrypoints in the current architecture/documentation include:

```text
start_fleet
start_fleet_mixed
start_colonize_fleet
expedition dispatch
```

Required invariant:

```text
one canonical travel-time helper
        ↓
all persisted mission arrival timestamps
```

The existing rate/fleet monitor explicitly identifies dispatch convergence as open. fileciteturn7file0L2-L2

### B — Mission lifecycle convergence — OPEN / HIGH

For each mission type, document:

```text
create
validate
reserve resources/fleet
schedule arrival
resolve arrival
settle rewards/costs
schedule return (if applicable)
resolve return
finalize
```

Then compare those invariants with the OGameX mission classes.

### C — Combat boundary — OPEN / MEDIUM

Compare OGameX's `BattleEngine` boundary with the current L.G.I. combat engine. Focus on:

- attacker/defender inputs;
- immutable battle snapshot;
- round/result representation;
- loot/loss/repair side effects;
- persistence boundary;
- relation between mission arrival and combat resolution.

Do not copy the OGameX battle implementation or its PHP/Rust split.

### D — Background processing — OPEN / MEDIUM

The L.G.I. engine already has persisted universe clock/catch-up and live scheduler jobs. The next audit is whether all temporal gameplay events have the same guarantees for:

- ordering;
- idempotency;
- overdue processing;
- atomic settlement;
- retry safety.

The worker must remain an execution mechanism, not the source of game time.

### E — Economy — OPEN / MEDIUM

Compare OGameX service/action boundaries against the existing L.G.I. economy helpers. Focus on identifying duplicated calculations and hidden modifier application, not on copying service classes.

## 6. What OGameX should NOT dictate

OGameX must not determine:

- L.G.I. universe evolution formulas;
- galaxy/system expansion timing;
- AI population targets;
- Supabase schema design;
- RLS/security policy;
- frontend architecture;
- worker/provider choice;
- canonical modifier ordering unless independently adopted as an explicit L.G.I. decision;
- gameplay balance merely because OGameX uses a value.

## 7. First-pass conclusion

The repository comparison does **not** show that L.G.I. needs an OGameX-style rewrite.

It shows that the most valuable immediate use of OGameX is as a **convergence/audit reference for temporal fleet missions, event lifecycles, combat boundaries and deferred processing**.

The current next step is therefore:

```text
OGameX reference map
        ↓
current L.G.I. fleet/event implementation
        ↓
mission lifecycle audit
        ↓
fix only confirmed gaps
```

## 8. Traceability

- OGameX repository: `lanedirt/OGameX`, `main` at the time of this map.
- L.G.I. repository: `Developer-0134565/LaGranImplosi-n`, `main` at commit `36c3ef4447bf99f5763837907873e55b37b3198b`.
- L.G.I. engine manifest: `supabase/ENGINE_MANIFEST.md`.
- L.G.I. rate/fleet monitor: `docs/UNIVERSE_RATE_AND_FLEET_ENGINE_MONITOR.md`.

Update this map when a subsystem comparison becomes concrete. Keep `PROJECT_CONTEXT_PROMPT.md` limited to the operational summary and current OPEN status.
