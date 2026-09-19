# FLEET ENGINE — LA GRAN IMPLOSIÓN

> **Status:** OPEN — backend movement lifecycle, propulsion/technology routing, mission-speed classes and
> fuel are converged and verified against LIVE; **browser certification remains OPEN**. The HOLDING class
> (ACS/holding/defend) is prepared at the classifier/universe level but its gameplay is **not implemented**.
>
> Canonical durable record for ship prerequisites, propulsion technology, mission speed classes, cargo,
> fuel, distance, dispatch and the movement lifecycle. OGameX is a reference pattern; L.G.I. keeps its own
> schema, balance and authority. Migration-history context: [`../MIGRATION_DRIFT_RECONCILIATION.md`](../MIGRATION_DRIFT_RECONCILIATION.md) ·
> [`../MIGRATION_INVERSE_DRIFT_AUDIT.md`](../MIGRATION_INVERSE_DRIFT_AUDIT.md).

## 1. Audit method

```text
OGameX reference
    ↓
current Supabase definitions/functions (LIVE)
    ↓
identify duplicated, parallel or divergent rules
    ↓
apply only confirmed L.G.I. fixes
    ↓
live verification (pg_get_functiondef + transactional tests)
    ↓
document
```

Never copy Laravel/PHP architecture or blindly import OGame values.

## 2. Ship prerequisite graph

The live `ship_prerequisites` table holds **41 prerequisite rows** for the current ship catalogue; a live
referential audit found **no dangling research or building references**.

The authoritative availability path is `check_ship_requirements(planet_id, ship_id)`. Dispatch/build
entrypoints must use this contract instead of reimplementing prerequisites.

## 3. Propulsion / technology routing

`calculate_player_ship_speed(player_id, ship_id)` is the single player-aware speed helper
(`STABLE SECURITY DEFINER`, `search_path = public, pg_temp`). It is the **only** implementation of the
ship → engine transition, and `calculate_player_ship_fuel_consumption(player_id, ship_id)` is the only
implementation of engine-related consumption. Both read `combustion_drive` / `impulse_drive` /
`hyperspace_drive` levels; **no other function reads those technologies** (assertion 7 in the fleet test).

| Ship | Active propulsion (transition) |
|---|---|
| `small_cargo` | Combustion until Impulse Drive ≥ 5, then Impulse |
| `bomber` | Impulse until Hyperspace Drive ≥ 8, then Hyperspace |
| `recycler` | Combustion baseline; Impulse ≥ 17; Hyperspace ≥ 15 takes precedence |
| `large_cargo`, `light_fighter`, `espionage_probe` | Combustion scaling |
| `heavy_fighter`, `cruiser`, `colony_ship` | Impulse scaling |
| `battleship`, `destroyer`, `deathstar`, `battlecruiser`, `reaper`, `pathfinder` | Hyperspace scaling |

Effective speed formula (LIVE):

```text
small_cargo        : impulse ≥ 5 ? 10000*(1+0.2*impulse) : base*(1+0.1*combustion)
bomber             : hyper   ≥ 8 ?  5000*(1+0.3*hyper)   : base*(1+0.2*impulse)
recycler           : hyper ≥ 15 ? 6000*(1+0.3*hyper) : impulse ≥ 17 ? 4000*(1+0.2*impulse) : base*(1+0.1*combustion)
large_cargo / light_fighter / espionage_probe : base*(1+0.1*combustion_drive)
heavy_fighter / cruiser / colony_ship         : base*(1+0.2*impulse_drive)
battleship / destroyer / deathstar / battlecruiser / reaper / pathfinder : base*(1+0.3*hyperspace_drive)
default                                       : base
```

`ship_definitions` owns the base values; the helper applies the player's research to them. Engine-related
consumption uses the same thresholds (`small_cargo` impulse ≥ 5 → `base*2`; `bomber` hyper ≥ 8 → `1000`;
`recycler` hyper ≥ 15 → `900`, impulse ≥ 17 → `600`; otherwise base). A technology therefore influences
ship speed once and engine consumption once, and never re-enters the travel-time or fuel pipeline.

## 4. Mission speed classes

Single authority (LIVE): `calculate_mission_fleet_speed_multiplier(p_universe_id uuid, p_mission_type text)`
→ `numeric`, `STABLE`, `SECURITY DEFINER`, `search_path = public, pg_temp`, ACL **postgres/service_role
only** (not a public API; this must not be reverted).

```text
universes.peaceful_fleet_speed   PEACEFUL : TRANSPORT · DEPLOY · COLONIZE · EXPEDITION
universes.war_fleet_speed        WAR      : ATTACK · ESPIONAGE · RECYCLE (also RECYCLE_ATTACK, HARVEST)
universes.holding_fleet_speed    HOLDING  : ACS_HOLD · HOLDING · DEFEND
universes.fleet_speed            legacy fallback for unknown mission names only
```

`NULL or <= 0` → `RAISE 'Invalid fleet speed for mission %'`. Never restore `universes.fleet_speed` as the
universal multiplier. Current live values for both universes are `1.0/1.0/1.0`, so existing behaviour is
preserved while the single-speed architectural limitation is removed.

## 5. Mission modifier pipeline (canonical, verified in the 3 dispatch RPCs)

```text
ship base speed
    ↓
propulsion technology                     calculate_player_ship_speed()
    ↓
mission fleet-speed class                 calculate_mission_fleet_speed_multiplier(universe, mission)
    ↓
universe evolution scale E^(1/3)          power(calculate_universe_evolution_rate(universe), 1/3)
    ↓
item / lifeform fleet-speed modifiers     get_active_expedition_item_effect + get_active_lifeform_research_effect
    ↓
expedition-specific modifier (EXPEDITION only)   lifeform expedition_speed_percent
    ↓
calculate_fleet_travel_time(distance, ship_speed, fleet_rate, 100)
    ↓
persisted arrives_at
```

Effective fleet rate used by the dispatchers:

```sql
v_fleet_speed := calculate_mission_fleet_speed_multiplier(universe_id, mission);
v_bonus       := 1 + ( item fleet_speed_percent + lifeform research fleet_speed_percent ) / 100;
                 -- EXPEDITION additionally: + lifeform research expedition_speed_percent / 100
v_fleet_rate  := v_fleet_speed * power(v_evolution, 1.0/3.0) * v_bonus;
v_travel_time := calculate_fleet_travel_time(v_distance, v_ship_speed, v_fleet_rate, 100);
```

Universe evolution does **not** replace the classic modifier; it is applied **after** the mission-speed
layer, matching the project's evolution design. `power(E, 1/3)` equals
`calculate_universe_scaling(E).fleet_movement_scale` (two code routes, identical value).

Travel-time formula (single implementation, `IMMUTABLE`):

```sql
calculate_fleet_travel_time(distance, ship_speed, fleet_rate, speed_percent) =
    round( greatest( ((35000 / speed_percent) * sqrt(distance * 10 / ship_speed) + 10) / fleet_rate, 1 ), 4 )
```

Only **two** functions in the entire schema contain the constant `35000`: this helper and
`calculate_player_fleet_fuel_for_distance` (which re-derives speed from the flight time). There is no inline
travel-time formula anywhere else (assertion 5 of `fleet_speed_classes.sql` enforces it).

## 6. Mission modifier matrix (extracted from the implementation, not invented)

| Mission | Ship speed | Universe multiplier | Evolution | Lifeform | Item | Final travel time |
|---|---|---|---|---|---|---|
| TRANSPORT | technology of the ships in the fleet (slowest) | `peaceful_fleet_speed` | `E^(1/3)` | `fleet_speed_percent` | `fleet_speed_percent` | `calculate_fleet_travel_time` |
| DEPLOY | idem | `peaceful_fleet_speed` | `E^(1/3)` | `fleet_speed_percent` | `fleet_speed_percent` | idem |
| COLONIZE | `colony_ship` (impulse) | `peaceful_fleet_speed` | `E^(1/3)` | `fleet_speed_percent` | `fleet_speed_percent` | idem |
| EXPEDITION | slowest of the fleet | `peaceful_fleet_speed` | `E^(1/3)` | `fleet_speed_percent` + `expedition_speed_percent` | `fleet_speed_percent` | idem (+ hold/delay, §12) |
| ATTACK | slowest of the fleet | `war_fleet_speed` | `E^(1/3)` | `fleet_speed_percent` | `fleet_speed_percent` | idem |
| ESPIONAGE | `espionage_probe` (combustion) | `war_fleet_speed` | `E^(1/3)` | `fleet_speed_percent` | `fleet_speed_percent` | idem |
| RECYCLE | `recycler` | `war_fleet_speed` | `E^(1/3)` | `fleet_speed_percent` | `fleet_speed_percent` | idem |
| ACS_HOLD / HOLDING / DEFEND | — (not dispatchable) | `holding_fleet_speed` (classifier ready) | — | — | — | — |

Live evidence (fleet test assertion 2): with a transactional probe universe
(`fleet_speed=7, peaceful=2, war=3, holding=5`) the classifier returned `2` for
TRANSPORT/DEPLOY/COLONIZE/EXPEDITION, `3` for ATTACK/ESPIONAGE/RECYCLE, `5` for ACS_HOLD/HOLDING/DEFEND
and `7` for an unknown mission.

## 7. Distance model

```text
same coordinate:              5
same system:                  1000 + 5 * |Δposition|
different system:             2700 + 95 * |Δsystem|
different galaxy:             20000 * |Δgalaxy|
```

The same canonical helpers are used for normal planets and coordinate-only targets such as colonisation,
recycling and expeditions (expedition distance uses its own justified geometry helper).

## 8. Fuel model — corrected, 2026-09-18

Two semantic divergences were found and corrected in the fleet fuel path:

1. the generic `1 - (0.003 × Hyperspace Technology)` fuel reduction was **removed**: fuel reduction belongs
   to the project's Lifeform `fuel_reduction_percent` effects, not to Hyperspace Technology;
2. fuel is now computed per ship type from the **persisted flight time** and the same canonical speed
   helpers used by the dispatch.

Canonical ordering (LIVE):

```text
ship_definitions.fuel_consumption
    ↓ calculate_player_ship_fuel_consumption(player, ship)        -- engine-related consumption
    ↓ calculate_player_fleet_fuel_for_distance(distance, flight_time, player, ship, qty, speed_percent)
         v_speed       := 35000 / max(t * speed_percent * 10 - 10, 1) * sqrt(distance * 10 / ship_speed)
         v_consumption := qty * base_consumption * distance / 35000 * power(v_speed/10 + 1, 2)
    ↓ fuel_reduction_percent (get_player_lifeform_effect, clamped 0..30)
final fuel = greatest(1, ceil(consumption))
```

`hyperspace_technology` is **not** a generic fuel reduction: it only selects the engine (and therefore the
engine consumption) inside `calculate_player_ship_fuel_consumption`. The legacy helper
`calculate_fleet_fuel_for_distance(distance, ship, qty)` hard-fails with
`'… is legacy: use calculate_player_fleet_fuel_for_distance(…)'`, so an old caller breaks loudly instead of
silently using the old order.

## 9. Lifeform / item modifiers

| Effect key | Computed by | Summed by | Applied in | Times |
|---|---|---|---|---|
| `fleet_speed_percent` (research) | `get_active_lifeform_research_effect(player, key)` | dispatchers (inline) | `v_bonus` of the 3 dispatch RPCs | 1 |
| `fleet_speed_percent` (item) | `get_active_expedition_item_effect(player, planet, key)` | dispatchers (inline) | `v_bonus` of the 3 dispatch RPCs | 1 |
| `expedition_speed_percent` (research) | `get_active_lifeform_research_effect` | dispatchers (inline) | `v_bonus`, EXPEDITION only | 1 |
| `fuel_reduction_percent` (lifeform) | `get_player_lifeform_effect(player, key)` | `calculate_player_fleet_fuel_for_distance` | after distance/time/mass consumption, clamped `0..30` | 1 |
| `civilian_ship_speed_percent` (research) | — | — | **never applied** | 0 (dead key) |
| `recall_fuel_recovery_percent` (research) | — | — | **never applied** | 0 (dead key) |

**No double application was found** in the live paths: the speed bonus enters the fleet rate once, the fuel
helper does not re-apply speed bonuses, and the fuel reduction is applied exactly once (assertion 8 counts a
single occurrence of `fuel_reduction_percent` in the fuel helper).

Architectural note (duplication, not a bug): the three dispatchers **inline** the formula that
`get_player_fleet_speed_multiplier(player, planet)` already implements; that helper is currently used only
by dead code (`calculate_expedition_time`), so the same modifier sum exists in two places — a divergence risk
to converge in a future mission.

## 10. Dispatch entrypoints

Known fleet dispatch surface:

- `start_fleet(player, origin, destination, ship, quantity, mission)` — single-ship dispatch
- `start_fleet_mixed(player, origin, destination, ships jsonb, mission)` — mixed composition
- `start_colonize_fleet(player, origin, galaxy, system, position)` — colony ship
- expedition dispatch and recycle dispatch / debris-field targeting (both through the two main RPCs)

All audited dispatch paths now select the mission-speed class **before** evolution scaling:

```text
start_colonize_fleet            → PEACEFUL (COLONIZE)
start_fleet (single ship)       → ATTACK/ESPIONAGE/RECYCLE = WAR · TRANSPORT/DEPLOY/EXPEDITION = PEACEFUL
start_fleet_mixed               → same mapping as start_fleet
```

Mixed fleets are validated independently: existence, prerequisites (`check_ship_requirements`), quantity,
effective speed and mission restrictions. Travel time uses the **slowest effective ship speed**; fuel is
accumulated per ship type using the same persisted flight time; composition is persisted in
`fleet_movement_ships`.

## 11. Movement lifecycle / idempotency — 2026-09-18

The shared worker was hardened specifically for downtime recovery, duplicate execution and concurrent
workers. Current live `process_fleet_movements()` semantics:

```text
persisted arrives_at / returns_at
        ↓
worker selects only due events            (status OUTBOUND/… and due timestamp)
        ↓
row lock + global transaction advisory lock
        ↓
OUTBOUND → ARRIVED
        ↓
mission-specific resolver                 (resolve_transport/deploy/attack/espionage/colonize/expedition/recycle)
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

1. Game time is persisted (the worker executes due events; it does not define game time).
2. Late workers preserve the original movement duration.
3. Arrival processing is transactionally claimed.
4. Arrival resolvers are state-gated.
5. Return settlement is state-gated.
6. Concurrent workers are serialized.
7. Mission-specific resolver side effects are protected by state/event identity.
8. Worker APIs are private (callable only by `postgres`/`service_role`; pg_cron runs as `postgres`).

Return leg: `process_fleet_movements()` reuses the outbound duration
(`v_duration := arrives_at - started_at` → `returns_at = arrives_at + v_duration`) and every
`resolve_*_arrival` does the same (`transport`, `espionage`, `attack`); `deploy`/`colonize` complete with
`returns_at = NULL`. There is therefore **no second speed formula** on the return leg and modifiers cannot be
applied twice there. A transactional double-run test processed a synthetic due return exactly once and the
whole test was rolled back.

## 12. Expedition hold / delay — converged 2026-09-18

`resolve_expedition_arrival` sets `returns_at = arrives_at + actual_hold + return_seconds`, where the hold
comes from `calculate_expedition_total_hold_seconds` → `calculate_expedition_delay_seconds` and
`return_seconds` is the outbound flight reduced by speed-up items (never below 1 s).

Convergence applied in that sweep: `calculate_expedition_delay_seconds` used the legacy
`universes.fleet_speed` (it was the last LIVE bypass of the canonical pipeline, in an active path —
EXPEDITION belongs to PEACEFUL). It now resolves the class with
`calculate_mission_fleet_speed_multiplier(universe, 'EXPEDITION')` (migration
`20260918100000_converge_expedition_hold_to_mission_class`). Numeric impact: **none** — live values are
`fleet_speed = peaceful_fleet_speed = 1` and the delays were identical before/after
(4439/6659/11099 and 4438/6658/11096 for three live expedition fleets).

## 13. ACS / HOLDING / DEFEND — state: OPEN (not implemented)

| Layer | State | Evidence (LIVE) |
|---|---|---|
| Speed class | **DEFINITION_ONLY** | the classifier maps `ACS_HOLD`/`HOLDING`/`DEFEND` → `holding_fleet_speed` |
| Universe column | **READY** | `universes.holding_fleet_speed` exists, `NOT NULL DEFAULT 1`, independent from the other two |
| Dispatch RPC | **NOT_IMPLEMENTED** | `start_fleet`, `start_fleet_mixed`, `start_colonize_fleet` reject any mission outside the 7 implemented ones |
| Persistence | **NOT_IMPLEMENTED** | `fleet_movements_mission_type_chk` allows only ATTACK, TRANSPORT, DEPLOY, ESPIONAGE, COLONIZE, RECYCLE, EXPEDITION |
| Tables | **NOT_IMPLEMENTED** | no ACS/holding/support table exists (`fleet_movements`, `fleet_movement_ships` only) |
| Resolution / UI | **NOT_IMPLEMENTED** | no `resolve_*` branch, no UI entry point |

Required pipeline when it is built (do not ship a partial version):

```text
start_acs_hold/start_defend (SECURITY DEFINER, ownership check)
   ↓ calculate_player_ship_speed(player, ship)
   ↓ calculate_mission_fleet_speed_multiplier(universe, 'ACS_HOLD' | 'HOLDING' | 'DEFEND')
        -> holding_fleet_speed   (never peaceful_*/war_*)
   ↓ E^(1/3) + lifeform/item modifiers (same ordering as §5)
   ↓ calculate_fleet_travel_time(...)  → holding window (arrives_at + hold duration)
   ↓ fuel: calculate_player_fleet_fuel_for_distance(...) with the outbound flight time
   ↓ return leg: reuse the duration (worker pattern of §11)
```

Also required: `fleet_movements.mission_type` CHECK extension, destination semantics (support target =
foreign planet), holding-duration persistence and fleet-support combat integration.

## 14. Route classification (map produced by the sweep)

| Function | Class | Notes |
|---|---|---|
| `calculate_mission_fleet_speed_multiplier` | **CANONICAL** | single mission→class authority; not granted to clients |
| `calculate_fleet_travel_time` | **CANONICAL** | the only travel-time formula; `IMMUTABLE` |
| `calculate_player_ship_speed` | **CANONICAL** | the only propulsion→speed routing |
| `calculate_player_ship_fuel_consumption` | **CANONICAL** | the only engine→consumption routing |
| `calculate_player_fleet_fuel_for_distance` | **CANONICAL** | fuel ordering (lifeform reduction once) |
| `start_fleet` / `start_fleet_mixed` / `start_colonize_fleet` | **CANONICAL** | 3/3 wired to classifier + `E^(1/3)` + helper |
| `resolve_*_arrival` + `process_fleet_movements` | **CANONICAL** | return leg = outbound duration; no speed math |
| `calculate_expedition_delay_seconds` | **CANONICAL (was PARALLEL)** | converged 2026-09-18 (§12) |
| `calculate_universe_rates` | **PARALLEL / DISTINCT PURPOSE** | informational snapshot; still uses `fleet_speed` × `fleet_movement_scale` and ignores the three classes → §15.2 |
| `calculate_fleet_time` | **LEGACY (dead)** | hardcodes the `TRANSPORT` class; only reached by the two dead fuel helpers |
| `calculate_fleet_fuel` | **LEGACY (dead)** | no live callers |
| `calculate_fleet_fuel_mixed` | **LEGACY (dead)** | no live callers; uses the legacy time helper |
| `calculate_fleet_fuel_for_distance` | **LEGACY (dead + hard-fail)** | raises `'… is legacy: use calculate_player_fleet_fuel_for_distance(…)'` |
| `calculate_expedition_time` | **LEGACY (dead)** | superseded expedition route (`universes.expedition_speed` + `get_player_fleet_speed_multiplier`) |
| `get_player_fleet_speed_multiplier` | **DUPLICATE** | correct formula, but only dead code uses it; the dispatchers inline the same sum (§9) |

## 15. Known gaps / remaining OPEN audit

### 15.1 Domain-level OPEN

1. **ACS / HOLDING / DEFEND not implemented** (§13) — the only domain-level gameplay OPEN item of the fleet engine.
2. **Browser fleet flow — OPEN**: backend correctness is not browser certification. Verify fleet selection, dispatch, persisted countdown, arrival, mission resolution and return in the browser.

### 15.2 Design / hygiene decisions left open

3. `calculate_universe_rates` still builds the fleet rate from the legacy `universes.fleet_speed`; decide the canonical meaning of a general fleet-rate snapshot now that three mission-speed classes exist.
4. Dead legacy cluster (`calculate_fleet_time`, `calculate_fleet_fuel`, `calculate_fleet_fuel_mixed`, `calculate_expedition_time`, `calculate_fleet_fuel_for_distance`) — inert but still deployed and in some cases still granted to clients; cleanup is a separate mission. **Never wire them back.**
5. Duplicated lifeform/item bonus sum (dispatchers inline vs `get_player_fleet_speed_multiplier`).
6. Lifeform keys defined but never applied: `civilian_ship_speed_percent`, `recall_fuel_recovery_percent`.
7. `universes.expedition_speed` survives only in dead code + `calculate_universe_rates`; it is no longer used for expedition travel time.

The 2026-09-18 directed Mission Modifiers / Technology / ACS audit found **no functional LIVE bug** in the seven implemented mission paths. Technology routing, mission class routing, modifier ordering, fuel ordering, double-application checks and live legacy-bypass checks all passed. The remaining items above are browser certification or architecture/hygiene decisions, not an unresolved gameplay defect.


## 16. Tests

```text
supabase/tests/fleet_speed_classes.sql   transactional (BEGIN … ROLLBACK) · 22/22 PASS live 2026-09-18
```

Covers: single class authority · class matrix incl. HOLDING and the legacy fallback · invalid-class exception
· 3/3 dispatch wiring · no parallel travel formula (`35000` appears only twice) · expedition hold resolves the
class · technology routing single authority · fuel reduction applied once without hyperspace · legacy cluster
without live consumers · ACS/HOLDING not dispatchable while `holding_fleet_speed` is ready. The failure
message lists the failing assertions, so a run without notice output is still self-diagnosing.

Related regression coverage: `supabase/tests/buildings_lifecycle.sql` (13/13 PASS), `scripts/verify-buildings.mjs`,
`scripts/verify-identity.mjs` and the research suite (`supabase/tests/research_lifecycle.sql`).

## 17. OGameX comparison targets

Useful OGameX lessons (patterns, never code to reproduce):

- mission creation/validation is distinct from arrival resolution;
- propulsion/technology rules should be centralized;
- fleet speed is determined by the slowest effective ship;
- the mission type selects the appropriate universe fleet-speed class;
- mission state must survive downtime;
- arrival and return are durable temporal transitions;
- workers execute due events but do not define game time.

OGameX's open-source fleet implementation exposes the same conceptual separation between
`FlightDistance`, `FlightSpeed`, `FlightCons` and `FlightTime`. These are architectural references; OGameX is
never an authority over L.G.I. rules.

## 18. Guardrails / maintenance rule

- Do not put ship technology rules into `calculate_universe_scaling(E)`.
- Do not maintain per-mission copies of the travel-time formula.
- Do not use Hyperspace Technology as a generic fuel-reduction modifier.
- Do not let the frontend become authoritative for speed, fuel, cargo or prerequisites.
- Do not restore `universes.fleet_speed` as the universal mission multiplier.
- Do not change OGameX-like balance values merely for parity.
- Keep worker/resolver entrypoints private; only approved player-facing dispatch RPCs are exposed.
- Do not certify the fleet subsystem until persisted state and the browser flow have been tested.
- Every new mission MUST use `calculate_mission_fleet_speed_multiplier` for its class, `calculate_fleet_travel_time`
  for its duration, apply lifeform/item modifiers once (§5 ordering), keep fuel in the order of §8 and reuse the
  outbound duration for the return leg (§11). Any new inline speed/fuel formula is a regression.
- Update this document whenever a canonical fleet formula or integration boundary changes.
