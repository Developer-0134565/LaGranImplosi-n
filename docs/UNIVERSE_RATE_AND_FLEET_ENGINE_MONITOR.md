# Universe Rate & Fleet Engine Monitor

> **Living document.** Update this file whenever the rate/evolution/fleet architecture changes materially.

## Purpose

This document is the canonical monitor for the universe-evolution rate engine and fleet travel model. It exists to prevent distributed formulas, ambiguous names, accidental double scaling, and session-to-session context loss.

## Canonical concepts

```text
E(t) = current universe evolution state

calculate_universe_scaling(E)
        |
        +-- resource_economy_scale    = E^1
        +-- resource_production_scale = E^1
        +-- building_speed_scale      = E^0.5
        +-- research_speed_scale      = E^0.5
        +-- fleet_movement_scale      = E^(1/3)
        +-- lifeform_speed_scale      = E^0.5
```

`calculate_universe_scaling(E)` contains only the transformation from evolution `E` to category-specific scaling factors. It does **not** contain classic rates, technologies, planet bonuses, lifeforms, items, events, alliances, or mission-specific modifiers.

### Example: E = 100

```text
resource_economy_scale    = 100
resource_production_scale = 100
building_speed_scale      = 10
research_speed_scale      = 10
fleet_movement_scale      = 4.6415888336
lifeform_speed_scale      = 10
```

## Evolution vs expansion

These are different systems and must never be collapsed into one generic `evolution` formula:

```text
UNIVERSE EVOLUTION
    E(t)
    -> rate/scaling changes over time

GALAXY/SYSTEM EXPANSION
    -> creates new systems/galaxies according to expansion timing rules
```

Galaxy expansion has its own formulas and state machine. A change to expansion timing must not silently change production, construction, research, or fleet scaling.

## Modifier pipeline

The conceptual pipeline is:

```text
classic/base rate
        -> universe evolution scaling
        -> technology / planet / lifeform modifiers
        -> item / event / alliance modifiers
        -> mission-specific modifiers
        -> final effective rate
```

The ordering is part of the architecture even where multiplication is mathematically commutative. Future modifiers must declare whether they are multiplicative, additive percentage, cap, or override before being inserted into the pipeline.

## Resource semantics

`economy` and `production` were considered too ambiguous. The canonical names are now:

- `resource_economy_scale`
- `resource_production_scale`

Both currently use `E^1`.

They remain separate because the current engine has two classic resource-rate stages. If both are applied to resource output, the evolution contribution is deliberately:

```text
E × E = E²
```

This is a gameplay/architecture decision, not a hidden exponent inside `calculate_universe_scaling`.

Do not rename or merge these stages merely because `E²` looks unusual. First audit their real consumers and determine whether they represent genuinely separate rate stages.

Solar energy is not multiplied by resource production scaling.

## Construction / research / lifeforms

```text
building_speed_scale = E^0.5
research_speed_scale  = E^0.5
lifeform_speed_scale  = E^0.5
```

These are speed multipliers. Higher scaling means shorter completion time when converted into the relevant effective speed/rate.

Consumers must not independently call `sqrt(E)` or recreate the exponent. They consume the centralized scaling result.

## Fleet movement

Fleet and expedition movement share one evolution scaling:

```text
fleet_movement_scale = E^(1/3)
```

There is **no separate expedition evolution exponent**. Expeditions can have expedition-specific modifiers, but their evolution component is the same movement scaling as normal fleet missions.

Conceptually:

```text
normal fleet speed
    = classic ship speed
    × fleet_movement_scale
    × later modifiers

expedition speed
    = classic ship speed
    × fleet_movement_scale
    × later modifiers
    × expedition-specific modifiers (if any)
```

## Non-linear travel time

The OGame/OGameX formula is used as a reference for structure, not as an authority for our gameplay balance.

Reference form:

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

Our public convention is `speed_percent = 100` for 100% speed. The implementation must document any internal normalization separately.

The important property is non-linearity: distance and ship speed interact through a square root rather than a simple `distance / speed` calculation.

## Coordinate distance model

Current reference geometry:

```text
same coordinate:              5
same system:                  1000 + 5 * |Δposition|
different system:             2700 + 95 * |Δsystem|
different galaxy:             20000 * |Δgalaxy|
```

Examples from `1:1:1`:

```text
1:1:1 -> 1:1:2 = 1005
1:1:1 -> 1:2:1 = 2795
1:1:1 -> 2:1:1 = 20000
```

These values are a reference baseline for our movement model. They are not permission to import every OGame mechanic.

## Base-speed investigation

Before changing fleet balance, establish the actual base travel-time behavior at:

```text
E = 1
fleet_movement_scale = 1
```

The test matrix must include:

```text
1:1:1 -> 1:1:2   same system / position change
1:1:1 -> 1:2:1   system change
1:1:1 -> 2:1:1   galaxy change
```

Use representative real ship speeds from our own ship definitions and verify the exact persisted arrival time path, not only a UI preview.

## Database implementation status

The centralized scaling/travel migration has been applied in Supabase.

Known implemented components:

- `calculate_universe_scaling(E)`
- timestamp-aware scaling lookup
- centralized universe-rate calculation
- canonical fleet travel-time helper
- building/research/shipyard/lifeform speed scaling
- shared fleet/expedition movement scaling

**Important:** the implementation is not considered fully closed until every fleet dispatch entrypoint uses the canonical travel-time helper for the persisted mission arrival time.

## Current open audit

### A. Fleet dispatch convergence — OPEN

Audit every mission entrypoint, including:

- `start_fleet`
- `start_fleet_mixed`
- `start_colonize_fleet`
- expedition dispatch
- any future mission-specific dispatch

Goal:

```text
one canonical travel-time formula
        ↓
all persisted fleet missions
```

No dispatch function may maintain a second copy of the travel-time formula.

### B. Resource naming/semantics — OPEN

Audit every consumer of:

- `resource_economy_scale`
- `resource_production_scale`

Confirm whether both represent distinct classic stages. Do not merge them until this audit is complete.

### C. Modifier ordering — OPEN

For every effective rate, identify the exact order and semantics of:

```text
classic
universe scaling
technology
planet
lifeform
item
event
alliance
mission-specific
```

### D. Expansion separation — CLOSED as a design rule

Universe evolution and galaxy/system expansion are separate systems. Never introduce a single formula intended to govern both.

## Audit guardrails

1. Do not put roots/cube roots back into individual consumers.
2. Do not put technology, item, planet, alliance, or event bonuses into `calculate_universe_scaling`.
3. Do not create a separate expedition evolution exponent.
4. Do not apply resource production scaling to solar energy.
5. Do not confuse galaxy/system expansion timing with resource/movement evolution.
6. Keep evolution calculations timestamp-aware where historical event resolution requires it.
7. Any future rate modifier must declare its mathematical type before insertion into the final-rate pipeline.
8. Fleet dispatch entrypoints must use the canonical travel-time helper.
9. Never copy an OGameX formula into the engine without first mapping its inputs to our own schema and gameplay rules.
10. Update this monitor whenever a canonical formula, name, modifier order, or integration point changes.

## Change log

### 2026-09-17 — Central scaling/fleet model

- Centralized category scaling around `calculate_universe_scaling(E)`.
- Standardized resource, construction, research, fleet movement and lifeform scaling semantics.
- Unified fleet and expedition evolution scaling under `fleet_movement_scale`.
- Documented non-linear travel-time reference and coordinate distances.
- Explicitly separated universe evolution from galaxy/system expansion.
- Recorded dispatch convergence as the next audit target.
