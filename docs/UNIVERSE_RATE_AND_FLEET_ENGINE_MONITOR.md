# Universe Rate & Fleet Engine Monitor

## Purpose

This document is the living reference for the universe-evolution rate engine and fleet travel model. It records the canonical formulas, semantic names, modifier order, audit findings, and implementation status so future migrations do not reintroduce distributed evolution logic.

## Canonical model

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

The scaling function contains **only** the transformation from evolution `E` to category-specific scaling factors. It does not know about classic universe rates, technologies, planet bonuses, lifeforms, items, events, alliances, or mission-specific modifiers.

### Example

For `E = 100`:

```text
resource_economy_scale    = 100
resource_production_scale = 100
building_speed_scale      = 10
research_speed_scale      = 10
fleet_movement_scale      = 4.6415888336
lifeform_speed_scale      = 10
```

## Modifier order

The semantic order is now explicit:

```text
classic/base universe rate
        -> universe evolution scaling
        -> technology / planet / lifeform modifiers
        -> item / event / alliance modifiers
        -> final effective rate
```

For multiplicative modifiers the mathematical multiplication is commutative, but keeping this conceptual order prevents future features from accidentally becoming part of `calculate_universe_scaling`.

## Resource semantics

The old `economy` and `production` names were ambiguous. The canonical scaling names are now:

- `resource_economy_scale`
- `resource_production_scale`

Both currently use `E^1`. They remain separate because the engine intentionally has two classic resource-rate stages. Their product therefore produces `E^2` when both are applied to resource output.

This is **intentional and documented**, not a hidden exponent inside the scaling function.

Solar energy is not multiplied by resource production scaling.

## Fleet movement

Fleet and expedition movement use one evolution scaling:

```text
fleet_movement_scale = E^(1/3)
```

There is no separate evolution exponent for expedition movement. Expeditions may still have expedition-specific modifiers, but their evolution component is the same movement scaling used by normal fleets.

### Non-linear travel time

The canonical helper is:

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

Our public convention is `speed_percent = 100` for 100% speed. This is numerically equivalent to the classic/OGameX convention where the internal value `10` represents 100%.

The effective rate is assembled as:

```text
classic fleet/expedition speed
    × universe evolution movement scaling
    × later player/planet/lifeform/item modifiers
```

Distance remains coordinate-based:

```text
same coordinate:             5
same system:                 1000 + 5 * |Δposition|
different system:            2700 + 95 * |Δsystem|
different galaxy:            20000 * |Δgalaxy|
```

No donut-system/donut-galaxy behavior is currently enabled in our engine.

## Reference used

OGameX was used as an implementation reference, not as the authority for our game design. Its current `FleetMissionService` uses the same square-root distance/speed interaction and the same coordinate-distance constants. The older open-source OGame implementation exposes the canonical `FlightTime` function explicitly.

Our engine deliberately adapts that structure to the dynamic universe-evolution model instead of copying OGame mechanics wholesale.

## Database implementation

Migration applied:

```text
centralize_universe_scaling_and_fleet_travel_formula
```

Implemented in Supabase:

- `calculate_universe_scaling(E)`
- `calculate_universe_scaling_at(universe_id, timestamp)`
- centralized effective `calculate_universe_rates(...)`
- `calculate_fleet_travel_time(...)`
- building time uses `E^0.5` through the scaling helper
- research time uses `E^0.5` through the scaling helper
- shipyard build time uses `E^0.5` through the scaling helper
- lifeform building/research time uses `E^0.5` through the scaling helper
- fleet time uses `E^(1/3)` through the scaling helper
- expedition time uses the same `E^(1/3)` movement scaling
- expedition delay uses the same fleet movement scaling

## Validation snapshot

With `E = 100` the database returns:

```text
resource_economy_scale    = 100
resource_production_scale = 100
building_speed_scale      = 10
research_speed_scale      = 10
fleet_movement_scale      = 4.6415888336
lifeform_speed_scale      = 10
```

Using a representative ship speed of `10000`, effective fleet rate `1`, and 100% speed:

```text
distance 1005  -> 360.8739 s
distance 2795  -> 595.1389 s
distance 20000 -> 1575.2476 s
```

These values demonstrate the intended non-linear distance interaction.

## Audit guardrails

1. Do not put roots/cube roots back into individual consumers.
2. Do not put technology, item, planet, alliance, or event bonuses into `calculate_universe_scaling`.
3. Do not create a separate expedition evolution exponent.
4. Do not apply resource production scaling to solar energy.
5. Do not confuse galaxy/system expansion timing with universe production evolution.
6. Keep `calculate_universe_evolution_rate_at(...)` timestamp-aware for historical event resolution.
7. Any future rate modifier must declare whether it is a multiplier, additive percentage, cap, or override before being inserted into the final-rate pipeline.
8. Fleet dispatch entrypoints must use the canonical `calculate_fleet_travel_time(...)` helper rather than maintaining their own travel-time formula.

## Next audit target

The remaining high-value consistency check is to route every fleet-dispatch entrypoint (`start_fleet`, `start_fleet_mixed`, `start_colonize_fleet`, and any future mission-specific dispatch) through the canonical travel-time helper. This prevents the database from having one formula for preview/calculation and another formula for persisted mission arrival times.

Until that audit is closed, this file should be treated as the monitor for the movement-engine migration and not as permission to introduce a second travel formula.
