# FLEET ENGINE — LA GRAN IMPLOSIÓN

> **Status:** OPEN — backend movement lifecycle hardened; browser certification remains OPEN.
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

Current families include Shipyard, Combustion Drive, Impulse Drive, Hyperspace Drive, Hyperspace Technology, Ion, Plasma, Espionage, Armour and Graviton prerequisites.

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

## 4. Fleet movement scaling

Canonical universe movement scaling:

```
fleet_movement_scale = E^(1/3)
```

Pipeline:

```
ship base speed
    ↓
propulsion technology
    ↓
universe fleet_movement_scale
    ↓
item/lifeform/mission modifiers
    ↓
canonical travel-time helper
    ↓
persisted arrives_at
```

## 5. Distance model

```
same coordinate:              5
same system:                  1000 + 5 * |Δposition|
different system:             2700 + 95 * |Δsystem|
different galaxy:             20000 * |Δgalaxy|
```

Examples: `1:1:1 → 1:1:2 = 1005`, `1:1:1 → 1:2:1 = 2795`, `1:1:1 → 2:1:1 = 20000`.

## 6. Cargo

`calculate_player_ship_cargo_capacity(player_id, ship_id)` is player-aware.

```
effective cargo = ship base cargo × (1 + 0.05 × Hyperspace Technology level)
```

Fleet cargo is the sum of each participating ship's effective cargo.

## 7. Deuterium consumption

`calculate_player_ship_fuel_consumption(player_id, ship_id)` is player-aware and accounts for propulsion transitions before fleet fuel is calculated. Hyperspace Technology's current fleet-fuel reduction is applied in the fleet fuel calculation.

## 8. Mixed fleets

`start_fleet_mixed()` validates every ship independently: existence, prerequisites, quantity, effective speed and mission restrictions. Travel time uses the slowest effective ship speed. Fuel is accumulated per ship type. Composition is persisted in `fleet_movement_ships`.

## 9. Dispatch entrypoints

Known fleet dispatch surface:

- `start_fleet`
- `start_fleet_mixed`
- `start_colonize_fleet`
- expedition dispatch
- recycle dispatch / debris-field targeting

Dispatch convergence is now implemented around the canonical distance/speed/time/fuel helpers. The remaining certification item is browser execution across the complete mission lifecycle.

## 10. OGameX comparison targets

Useful OGameX lessons: mission creation/validation is distinct from arrival resolution; propulsion/technology rules should be centralized; mission state must survive downtime; arrival and return are durable temporal transitions; mission-specific resolution belongs after shared movement; workers execute due events but do not define game time.

These are architectural patterns, not instructions to reproduce OGameX's PHP classes.

## 11. Dispatch convergence finding — 2026-09-18

The first convergence pass found a real divergence in `start_colonize_fleet`: it previously used a linear travel-time calculation, static colony-ship speed and the legacy static fuel helper. This was corrected live.

`start_colonize_fleet()` now uses:

- `calculate_player_ship_speed()`;
- the canonical galaxy/system/position distance model;
- `calculate_fleet_travel_time()`;
- `calculate_player_fleet_fuel_for_distance()`;
- the same fleet-evolution scaling and speed modifiers as the shared fleet path.

A second sweep found the legacy `calculate_fleet_fuel_for_distance(distance, ship_id, quantity)` entrypoint. It has no remaining legitimate caller and EXECUTE has been revoked from `PUBLIC`, `anon` and `authenticated`.

The same sweep converged `calculate_fleet_time()` on player-aware propulsion, universe evolution scaling and the canonical travel-time helper. `calculate_fleet_fuel()` and mixed-fleet fuel now use the player-aware fuel path.

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

Important properties verified in the live function:

1. **Game time is persisted.** The worker compares stored event timestamps with `clock_timestamp()`; it does not reconstruct elapsed time from worker execution time.
2. **Late workers preserve the original timeline.** Non-expedition return time is derived from `arrives_at - started_at`, not from "now + travel time".
3. **Arrival processing is transactionally claimed.** The worker changes `OUTBOUND` to `ARRIVED` under row lock before invoking the mission resolver. If resolution fails, the surrounding transaction rolls back the claim and side effects together.
4. **Resolvers are state-gated.** Arrival resolvers require `ARRIVED`; a second call after successful resolution sees `RETURNING` or `COMPLETED` and cannot repeat the arrival side effect.
5. **Return settlement is state-gated.** The return loop selects only `RETURNING` rows due for processing, locks the row, applies ships/resources, then changes the row to `COMPLETED`. A second worker pass cannot select the completed row.
6. **Concurrent workers are serialized.** `process_fleet_movements()` takes the transaction advisory lock `fleet-processing-global`; due-row queries additionally use `FOR UPDATE SKIP LOCKED`.
7. **Mission-specific idempotency exists at the resolver boundary.** Expedition results use the fleet identity as the unique event key; transport/deploy/colonize/attack/espionage resolvers are state-gated before their mutations.
8. **Worker API is private.** `process_fleet_movements()` and `run_fleet_worker()` are not executable by `anon` or `authenticated`.

Live transactional idempotency test on 2026-09-18:

- created a synthetic due `RETURNING` transport inside a transaction;
- executed `process_fleet_movements()` twice;
- first pass processed the movement;
- second pass processed zero rows;
- final movement state was `COMPLETED`;
- the whole test was rolled back, leaving no test mutation.

Live integrity scan at the same point:

- 54 historical fleet movements;
- 0 due `OUTBOUND` rows with NULL `arrives_at`;
- 0 `RETURNING` rows with NULL `returns_at`;
- 0 return timestamps earlier than arrival timestamps;
- 0 `COMPLETED` rows retaining undelivered movement resources.

The existing due-event indexes are present:

- `fleet_movements_outbound_arrival_idx` on `(arrives_at, id)` for `OUTBOUND`;
- `fleet_movements_returning_idx` on `(returns_at, id)` for `RETURNING`.

No additional worker index was added because the existing indexes already match the due-event access pattern.

## 13. Remaining OPEN audit

### A. Dispatch convergence — BACKEND VERIFIED

Canonical distance/speed/time/fuel integration is live for the audited dispatch paths. Browser certification remains open.

### B. Return-time convergence — BACKEND VERIFIED

Return scheduling is anchored to persisted movement duration and event timestamps. Downtime/idempotency behavior has been transactionally exercised.

### C. Technology graph — MEDIUM

Compare all current ship definitions against prerequisites and propulsion family. Confirm every referenced technology participates correctly in effective speed/consumption where applicable.

### D. Mission-specific modifiers — MEDIUM

Audit expedition, recycle, deploy, colonize and attack modifiers separately. They must be applied after the common movement pipeline and must not duplicate universe scaling.

### E. Browser fleet flow — OPEN

Backend correctness is not browser certification. A user-performed browser test must verify fleet selection, dispatch, persisted countdown, arrival, mission resolution and return.

## 14. Changes applied during current audit — 2026-09-18

- centralized player-aware ship speed calculation;
- encoded propulsion transitions for Small Cargo, Bomber and Recycler;
- centralized player-aware fuel consumption;
- centralized player-aware cargo capacity;
- mixed-fleet cargo/fuel/speed integration;
- fleet dispatch ownership remains protected;
- canonical galaxy/system/position distance model remains in the movement path;
- removed public execution of the legacy static fleet-fuel helper;
- converged fleet time/fuel helpers on player-aware calculations;
- no dangling ship prerequisite references found;
- verified movement worker state transitions and idempotency under a transactional double-run test.

## 15. Verification evidence — 2026-09-18

A transactional live test executed `start_colonize_fleet()` with the guest test player, a real colony ship and an empty target coordinate. The function returned a persisted-style `COLONIZE` fleet with a non-null `arrives_at`, and the transaction was rolled back, so no ship/resources/fleet state was mutated.

The first test exposed two implementation defects in the new path — the fuel-consumption CASE had no fallback for ordinary ships, and `planet_ships.ship_id` was ambiguous inside the PL/pgSQL update. Both were corrected and the same transactional test then passed.

A second live sweep verified the movement worker's persisted-event/idempotency behavior as documented in section 12. The synthetic transport test was fully rolled back after verification.

## 16. Guardrails

- Do not put ship technology rules into `calculate_universe_scaling(E)`.
- Do not maintain per-mission copies of the travel-time formula.
- Do not let the frontend become authoritative for speed, fuel, cargo or prerequisites.
- Do not change OGameX-like balance values merely for parity.
- Do not certify the fleet subsystem until persisted state and browser flow have been tested.
- Keep worker/resolver entrypoints private; only approved player-facing dispatch RPCs should be exposed.
- Update this document whenever a canonical fleet formula or integration boundary changes.
