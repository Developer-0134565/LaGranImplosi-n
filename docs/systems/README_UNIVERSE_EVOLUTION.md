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

- Define the exact catch-up batching/limits for long downtime.
- Define idempotency rules for repeated processing attempts.
- Define event ordering when multiple universe events are overdue.
- Define monitoring/health information for the internal clock.
- Define AI placement constraints and collision handling.

These remain implementation/audit topics and should not be silently invented in the operational context.


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

`process_universe_clock()` uses persisted timestamps and advances `next_tick_at` according to due ticks rather than simply resetting to `now + interval`. This is the required architectural direction for downtime recovery. Exact long-downtime batching, event ordering, idempotency and health monitoring remain open audit questions.

### Expansion state already present

The current engine contains the agreed parameters: normal expansion base `28800` seconds, curve exponent `0.75`, global galaxy roll interval `43200` seconds, special-galaxy probability `0.01`, initial normal galaxies `100`, special initial systems `10`, special growth factor `5%`, AI target density about `0.075` and tolerance about `0.0025`.

These values are evidence of current implementation state, not permission to assume every consumer is correct.

### Audit rule after this discovery

Do not launch another repository-wide recognition prompt for Universe Evolution. The next Cline/DeepSeek task should be a directed, read-only subsystem audit limited to evolution-rate/scaling consumers, universe clock/tick/heartbeat, galaxy roll/system expansion, AI reconciliation, exact formulas/modifier ordering, and contradictions between implementation, live Supabase state and the specialized monitors. It must identify exact files/functions and evidence without modifying code, migrations or database state.
