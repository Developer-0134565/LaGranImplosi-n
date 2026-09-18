# FLEET ENGINE — LA GRAN IMPLOSIÓN

> **Status:** OPEN — deep audit in progress.
>
> Canonical durable record for ship prerequisites, propulsion/technology modifiers, cargo, fuel, distance and fleet-dispatch integration. OGameX is a reference pattern; L.G.I. keeps its own schema and balance.

## 1. Audit method
```text
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

```text
fleet_movement_scale = E^(1/3)
```

Pipeline:

```text
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

```text
same coordinate:              5
same system:                  1000 + 5 * |Δposition|
different system:             2700 + 95 * |Δsystem|
different galaxy:             20000 * |Δgalaxy|
```

Examples: `1:1:1 → 1:1:2 = 1005`, `1:1:1 → 1:2:1 = 2795`, `1:1:1 → 2:1:1 = 20000`.

## 6. Cargo

`calculate_player_ship_cargo_capacity(player_id, ship_id)` is player-aware.

```text
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

The audit remains OPEN until every dispatch path is proven to persist arrival timestamps through the same canonical travel-time calculation.

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

`process_fleet_movements()` already resolves due arrivals from persisted `arrives_at` and derives non-expedition return time from the persisted flight duration, preserving downtime/catch-up semantics.

This closes the identified colonization formula divergence, but the dispatch audit remains open until all mission entrypoints and browser flow are certified.

## 12. Remaining OPEN audit

### A. Dispatch convergence — HIGH
One canonical travel-time formula must feed all persisted `arrives_at` timestamps.

### B. Return-time convergence — HIGH
Verify every returning mission derives `returns_at` from persisted event state and does not create a second travel-time implementation.

### C. Technology graph — MEDIUM
Compare all current ship definitions against prerequisites and propulsion family. Confirm every referenced technology participates correctly in effective speed/consumption where applicable.

### D. Mission-specific modifiers — MEDIUM
Audit expedition, recycle, deploy, colonize and attack modifiers separately. They must be applied after the common movement pipeline and must not duplicate universe scaling.

### E. Browser fleet flow — OPEN
Backend correctness is not browser certification. A user-performed browser test must verify fleet selection, dispatch, persisted countdown, arrival, mission resolution and return.

## 13. Changes applied during current audit — 2026-09-18

- centralized player-aware ship speed calculation;
- encoded propulsion transitions for Small Cargo, Bomber and Recycler;
- centralized player-aware fuel consumption;
- centralized player-aware cargo capacity;
- mixed-fleet cargo/fuel/speed integration;
- fleet dispatch ownership remains protected;
- canonical galaxy/system/position distance model remains in the movement path;
- no dangling ship prerequisite references found.

## 14. Verification evidence — 2026-09-18

A transactional live test executed `start_colonize_fleet()` with the guest test player, a real colony ship and an empty target coordinate. The function returned a persisted-style `COLONIZE` fleet with a non-null `arrives_at`, and the transaction was rolled back, so no ship/resources/fleet state was mutated.

The first test exposed two implementation defects in the new path — the fuel-consumption CASE had no fallback for ordinary ships, and `planet_ships.ship_id` was ambiguous inside the PL/pgSQL update. Both were corrected and the same transactional test then passed.

The propulsion thresholds are consistent with classic OGame reference material: Small Cargo switches at Impulse 5, Bomber at Hyperspace 8, and Recycler at Impulse 17 / Hyperspace 15; the classic speed increments are +10% Combustion, +20% Impulse and +30% Hyperspace. citeturn0search0turn0search3

## 15. Guardrails

- Do not put ship technology rules into `calculate_universe_scaling(E)`.
- Do not maintain per-mission copies of the travel-time formula.
- Do not let the frontend become authoritative for speed, fuel, cargo or prerequisites.
- Do not change OGameX-like balance values merely for parity.
- Do not certify the fleet subsystem until persisted state and browser flow have been tested.
- Update this document whenever a canonical fleet formula or integration boundary changes.