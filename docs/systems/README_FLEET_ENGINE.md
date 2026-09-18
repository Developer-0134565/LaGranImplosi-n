# FLEET ENGINE — LA GRAN IMPLOSIÓN

> **Status:** OPEN — backend movement lifecycle and mission-speed convergence verified; browser certification remains OPEN.
>
> Canonical durable record for ship prerequisites, propulsion/technology modifiers, cargo, fuel, distance and fleet-dispatch integration. OGameX is a reference pattern; L.G.I. keeps its own schema and balance.

## 1. Audit method
```
OGameX reference
    ↓
current Supabase definitions/functions
    ↓
identify duplicated or divergent rules
    ↓
apply only confirmed L.G.I. fixes
    ↓
live verification
    ↓
document
```

Never copy Laravel/PHP architecture or blindly import OGame values.

## 2. Current ship prerequisite graph

The live `ship_prerequisites` table contains **41 prerequisite rows** for the current ship catalog. Live referential audit found **no dangling research or building references**.

The authoritative availability path is `check_ship_requirements(planet_id, ship_id)`. Dispatch/build entrypoints must use this contract rather than reimplementing prerequisites.

## 3. Propulsion model

`calculate_player_ship_speed(player_id, ship_id)` is the centralized player-aware speed helper.

| Ship | Current transition logic |
|---|---|
| `small_cargo` | Combustion until Impulse Drive >= 5, then Impulse |
| `bomber` | Impulse until Hyperspace Drive >= 8, then Hyperspace |
| `recycler` | Combustion baseline; Impulse >= 17; Hyperspace >= 15 takes precedence |
| `large_cargo`, `light_fighter`, `espionage_probe` | Combustion scaling |
| `heavy_fighter`, `cruiser`, `colony_ship` | Impulse scaling |
| `battleship`, `destroyer`, `deathstar`, `battlecruiser`, `reaper`, `pathfinder` | Hyperspace scaling |

The exact base values remain owned by `ship_definitions`; the helper applies player research to those definitions.

## 4. Fleet mission-speed model — NEW, 2026-09-18

OGame's current universe model separates fleet speed into **peaceful**, **war** and **holding** settings. Official OGame documentation lists transport/deployment/colonisation/expedition under peaceful speed, attack/espionage/harvesting under war speed, and ACS hold under holding speed. citeturn0search0turn0search5

L.G.I. now exposes the same conceptual separation without copying OGame's implementation:

```
universes.fleet_speed                  legacy/common fallback
universes.peaceful_fleet_speed         civil missions
universes.war_fleet_speed              offensive/war missions
universes.holding_fleet_speed          ACS/holding missions
```

Mission mapping:

```
PEACEFUL
  TRANSPORT
  DEPLOY
  COLONIZE
  EXPEDITION

WAR
  ATTACK
  ESPIONAGE
  RECYCLE / HARVEST

HOLDING
  ACS_HOLD
  HOLDING
  DEFEND
```

Canonical selector:

`calculate_mission_fleet_speed_multiplier(universe_id, mission_type)`.

The current production universe has all three explicit settings at `1.0`, preserving existing behaviour while removing the architectural single-speed limitation.

## 5. Modifier ordering

The canonical ordering is now:

```
ship base speed
    ↓
propulsion technology
    ↓
mission fleet-speed setting
    ↓
universe evolution scale E^(1/3)
    ↓
item / lifeform fleet-speed modifiers
    ↓
expedition-specific speed modifier (EXPEDITION only)
    ↓
calculate_fleet_travel_time()
    ↓
persisted arrives_at
```

This is important: **universe evolution does not replace the classic modifier; it is applied after the classic mission-speed layer**, matching the project's evolution design.

## 6. Distance model

```
same coordinate:              5
same system:                  1000 + 5 * |Δposition|
different system:             2700 + 95 * |Δsystem|
different galaxy:             20000 * |Δgalaxy|
```

The same canonical helpers are used for normal planets and coordinate-only targets such as colonisation/recycling.

## 7. Fuel model — corrected, 2026-09-18

The previous fleet-fuel calculation contained:

```
1 - (0.003 × Hyperspace Technology)
```

This was identified as a semantic bug. The `0.03%) per-level fuel reduction belongs to the project's Lifeform `fuel_reduction_percent` effects, not to Hyperspace Technology.

The live function now uses:

```
base ship consumption
    ↓
active propulsion transition
    ↓
distance + actual flight time
    ↓
Lifeform fuel_reduction_percent
    ↓
ceil / minimum 1
```

The effect is capped defensively at 30%.

The live database contains fuel-reduction effects for the Lifeform system, including `kalesh_heat_recovery` and `mecha_efficiency_module`. A player with no active fuel-reduction effect currently returns 0% from `get_player_lifeform_effect(...)`.

## 8. Propulsion/fuel verification

The live guest test player currently produced:

```
small cargo speed = 8000
bomber speed      = 6400
small cargo fuel  = 10
bomber fuel       = 700
```

These results are consistent with the player's current propulsion research state and demonstrate that ordinary fuel consumption no longer receives a hidden Hyperspace Technology reduction.

The canonical OGameX reference also calculates fleet consumption from each ship's active speed/consumption and calculates fleet travel time from the slowest ship. citeturn0search1

## 9. Mixed fleets

`start_fleet_mixed()` validates every ship independently: existence, prerequisites, quantity, effective speed and mission restrictions.

Travel time uses the slowest effective ship speed. Fuel is accumulated per ship type using the same persisted flight time. Composition is persisted in `fleet_movement_ships`.

## 10. Dispatch entrypoints

Known fleet dispatch surface:

- `start_fleet`
- `start_fleet_mixed`
- `start_colonize_fleet`
- expedition dispatch
- recycle dispatch / debris-field targeting

All audited dispatch paths now select the mission-speed class before evolution scaling.

`start_colonize_fleet()` is explicitly mapped to **PEACEFUL**.

`start_fleet()` maps:
- ATTACK → WAR
- ESPIONAGE → WAR
- RECYCLE → WAR
- TRANSPORT → PEACEFUL
- DEPLOY → PEACEFUL
- EXPEDITION → PEACEFUL

## 11. OGameX comparison targets

Useful OGameX lessons:

- mission creation/validation is distinct from arrival resolution;
- propulsion/technology rules should be centralized;
- fleet speed is determined by the slowest effective ship;
- mission type selects the appropriate universe fleet-speed class;
- mission state must survive downtime;
- arrival and return are durable temporal transitions;
- workers execute due events but do not define game time.

OGameX's open-source fleet implementation exposes the same conceptual separation between `FlightDistance`, `FlightSpeed`, `FlightCons` and `FlightTime`. citeturn0search1

These are architectural patterns, not instructions to reproduce OGameX's PHP classes.

## 12. Movement lifecycle / idempotency — 2026-09-18

The shared worker was attacked specifically for downtime recovery, duplicate execution and concurrent workers.

Current live `process_fleet_movements()` semantics:

```
persisted arrives_at / returns_at
        ↓
worker selects only due events
        ↓
row lock + global transaction advisory lock
        ↓
OUTBOUND → ARRIVED
        ↓
mission-specific resolver
        ↓
ARRIVED → RETURNING or COMPLETED
        ↓
persisted return timestamp
        ↓
return settlement
        ↓
RETURNING → COMPLETED
```

Verified properties:

1. Game time is persisted.
2. Late workers preserve original movement duration.
3. Arrival processing is transactionally claimed.
4. Arrival resolvers are state-gated.
5. Return settlement is state-gated.
6. Concurrent workers are serialized.
7. Mission-specific resolver side effects are protected by state/event identity.
8. Worker APIs are private.

A transactional double-run test processed a synthetic due return exactly once; the whole test was rolled back.

## 13. Remaining OPEN audit

### A. Technology graph — MEDIUM

Confirm every current ship's referenced propulsion technology participates correctly in speed and fuel semantics. The prerequisite graph itself is coherent.

### B. Mission-specific modifiers — MEDIUM

Audit expedition, recycle, deploy, colonize and attack modifiers separately. They must be applied after the common movement pipeline and must not duplicate universe evolution.

### C. Browser fleet flow — OPEN

Backend correctness is not browser certification. Verify fleet selection, dispatch, persisted countdown, arrival, mission resolution and return in the browser.

### D. ACS / holding — OPEN

The database now has a dedicated holding-speed channel, but ACS holding behaviour must be certified before it is considered complete.

## 14. Guardrails

- Do not put ship technology rules into `calculate_universe_scaling(E)`.
- Do not maintain per-mission copies of the travel-time formula.
- Do not use Hyperspace Technology as a generic fuel-reduction modifier.
- Do not let the frontend become authoritative for speed, fuel, cargo or prerequisites.
- Do not change OGameX-like balance values merely for parity.
- Do not certify the fleet subsystem until persisted state and browser flow have been tested.
- Keep worker/resolver entrypoints private; only approved player-facing dispatch RPCs should be exposed.
- Update this document whenever a canonical fleet formula or integration boundary changes.
