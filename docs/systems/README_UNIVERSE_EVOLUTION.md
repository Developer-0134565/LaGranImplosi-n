# UNIVERSE EVOLUTION — LA GRAN IMPLOSIÓN

## Purpose

Detailed durable knowledge for universe evolution, internal time, catch-up processing, galaxy/system expansion and AI population. `PROJECT_CONTEXT.md` keeps only the operational summary.

## Separation of systems

```text
UNIVERSE EVOLUTION
E(t)
→ rate/scaling changes

GALAXY/SYSTEM EXPANSION
→ creates systems/galaxies according to expansion rules
```

These systems must not be collapsed into one generic evolution formula.

## Universe scaling

Canonical transformation:

```text
calculate_universe_scaling(E)
```

Current category exponents:

```text
resource_economy_scale    = E^1
resource_production_scale = E^1
building_speed_scale      = E^0.5
research_speed_scale      = E^0.5
fleet_movement_scale      = E^(1/3)
lifeform_speed_scale      = E^0.5
```

The scaling function transforms `E` into category-specific factors. It does not contain technology, planet, lifeform, item, event, alliance or mission-specific modifiers.

## Modifier pipeline

```text
classic/base rate
    → universe evolution scaling
    → technology / planet / lifeform modifiers
    → item / event / alliance modifiers
    → mission-specific modifiers
    → final effective rate
```

Each future modifier must declare whether it is multiplicative, additive percentage, cap or override.

## Internal clock

Universe evolution must continue correctly across downtime. The server/client must not rely on a continuously running browser timer as the authoritative clock.

Use persisted timestamps/event state to detect elapsed real time and catch up pending work when processing resumes.

The universe heartbeat must route through the complete planet tick path when that path is responsible for building/research completion. Do not reintroduce an older local-only shortcut without a new audit.

## Normal galaxy expansion

Current agreed rule:

```text
new-system interval = 8 × G^0.75 hours
```

Systems are generated sequentially. Production scope currently includes 100 normal galaxies.

## Special galaxies

Every 12 real hours:

```text
1% global roll
```

On success:

- create one special galaxy after G100;
- start with 10 systems;
- use a separate system-expansion formula;
- do not reuse the normal-galaxy formula automatically.

## AI population

Target AI occupancy is approximately 5–10% of available universe slots, within a defined tolerance.

Whenever universe space expands, population logic should evaluate whether additional AI planets are required.

Do not create a second population state if existing universe population state can represent the process.

## Open implementation concerns

The following remain useful future hardening/audit topics, but they are **not blockers for the currently validated engine surface**:

- refine long-downtime batching beyond the tested limits;
- deepen idempotency and event-ordering coverage for extreme overdue workloads;
- expand AI placement/collision audit coverage;
- continue monitoring/observability improvements as new evolution features are added.

The current clock/catch-up, expansion, galaxy-roll, AI reconciliation, heartbeat and monitor surface is validated and closed.

## 2026-09-17 — Initial production/runtime audit

The first DeepSeek/Cline recognition audit established this implementation surface:

```text
universes
  ↓
universe_clock
  ↓
process_universe_clock()
  ↓
process_universe_tick()
  ↓
process_universe_heartbeat()
  ├─ process_universe_galaxy_roll()
  ├─ process_universe_system_expansion()
  └─ reconcile_universe_ai_population()
```

Known persistent state includes `universe_clock` (`last_tick_at`, `next_tick_at`, `tick_interval_seconds`, `is_processing`), `universe_expansion_state`, `universe_population_state` and `universe_galaxies`.

Live Supabase verification confirmed active scheduler jobs: `universe-heartbeat` every minute and `deuteria-fleet-worker` every second. The repository/dump did not contain the `cron.job` rows, so scheduler status must be verified against live Supabase rather than inferred from repository files.

### Critical formula convergence finding

The initial audit found multiple evolution application patterns in the existing engine:

```text
calculate_universe_rates()      → E^1 in its universe-rate component
some building-time paths         → sqrt(E)
some fleet/expedition paths      → E^(1/3)
temporal production integral     → integrates E²
population/lifeform integral     → integrates sqrt(E)
```

This is an audit finding, not yet a decision to change formulas. The existing `UNIVERSE_RATE_AND_FLEET_ENGINE_MONITOR.md` describes centralized category scaling, so actual production consumers must be reconciled with that documented model before implementation changes.

### Clock/catch-up finding

`process_universe_clock()` uses persisted timestamps and advances `next_tick_at` according to due ticks rather than simply resetting to `now + interval`. This is the required architectural direction for downtime recovery. The controlled 2026-09-18 tests validated catch-up, bounded overdue processing and failure/recovery for the current implementation.

### Expansion state already present

The current engine contains the agreed parameters: normal expansion base `28800` seconds, curve exponent `0.75`, global galaxy roll interval `43200` seconds, special-galaxy probability `0.01`, initial normal galaxies `100`, special initial systems `10`, special growth factor `5%`, AI target density about `0.075` and tolerance about `0.0025`.

These values are evidence of current implementation state, not permission to assume every future consumer is correct.

### Audit rule after this discovery

Do not launch another repository-wide recognition prompt for Universe Evolution. Future Cline/DeepSeek work should be directed and limited to a concrete evolution-rate/scaling consumer, clock/tick/heartbeat change, galaxy/system rule change, AI reconciliation change, or contradiction between implementation and live state.

## 2026-09-18 — Directed validation and monitor closure

Controlled live tests completed the current evolution-engine validation surface:

- persistent clock catch-up after approximately 48 hours of inactivity;
- long-overdue expansion batching with the 10,000-work cap;
- 7-day expansion + AI reconciliation simulation;
- heartbeat failure/recovery after removing/restoring the clock;
- concurrent heartbeat execution without duplicate/corrupt expansion;
- normal G100 expansion using the agreed 8 × G^0.75 hour interval;
- special galaxy expansion using the separate 1.05 growth factor;
- overdue galaxy-roll processing with bounded roll catch-up.

The engine returned to a healthy live state after testing. Active Universe 1 was observed with 101 galaxies (100 normal + 1 special), 207 systems, 3105 positions and 226 AI planets at 7.28% density against a 7.50% target with ±0.25% tolerance.

Detailed observability is maintained separately in [README_UNIVERSE_EVOLUTION_MONITOR.md](README_UNIVERSE_EVOLUTION_MONITOR.md). The monitor is read-only and distinguishes schedule backlog from actual work backlog.

The full monitor RPC is private. The frontend consumes only the sanitized public RPC, callable by anon and authenticated. The monitor passed an end-to-end CATCHING_UP → HEALTHY recovery test with lag and pending ticks returning to zero.

## 2026-09-18 — Production deployment validation

After the live engine and monitor validation, the frontend was built and deployed to the canonical Cloudflare Worker:

- production build: PASS;
- Cloudflare Worker deployment: PASS;
- Worker: `lagranimplosion`;
- production URL: `https://lagranimplosion.lagranimplosion.workers.dev`;
- deployed version: `a5cba4c6-b82f-4c73-b445-f32fb887614`;
- public Overview monitor: PASS;
- authenticated RPC execution: PASS;
- production monitor state: `HEALTHY`;
- production clock lag: `0s`;
- production ticks pending: `0`;
- production expansion backlog: `0`;
- production galaxy rolls due: `0`;
- production AI deficit: `0`.

The production UI observed Universe 1 at:

```text
Galaxies       101
Normal         100
Special        1
Systems        207
Positions      3105
AI planets     226
AI density     7.28%
Target         7.50%
Tolerance      ±0.25%
Clock interval 60s
```

This closes the current Universe Evolution implementation/observability/deployment phase. The bundle-size warning (~543 kB minified client chunk) is a future optimization item, not a functional deployment failure.

### Migration state caveat

The monitor SQL is versioned in GitHub migrations 20260918020000–20260918020300. Live SQL objects and privileges were verified. Supabase migration-history synchronization previously showed these versions absent from the queried history table, so migration state must be reconciled carefully before any future CLI migration replay.
