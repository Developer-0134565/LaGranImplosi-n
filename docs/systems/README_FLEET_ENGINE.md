# FLEET ENGINE — LA GRAN IMPLOSIÓN

> **Status:** BACKEND CONVERGED / MISSION MODIFIERS CLOSED — `start_fleet`, `start_fleet_mixed` and
> `start_colonize_fleet` converge in LIVE on the canonical movement pipeline: ship speed, mission class,
> evolution, modifiers, travel time and fuel. **Browser certification remains OPEN**. ACS_HOLD Fase A is
> **IMPLEMENTED / NOT BROWSER-CERTIFIED** (§22): single support dispatcher + explicit destination-owner
> authorization + `OUTBOUND → ARRIVED → HOLDING → RETURNING → COMPLETED` lifecycle. `DEFEND` remains
> **BLOCKED BY COMBAT ENGINE**, holding fuel and maximum holding duration remain **OPEN**, UI is not built.
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
engine consumption) inside `calculate_player_ship_fuel_consumption`. The former legacy helper `calculate_fleet_fuel_for_distance(distance, ship, qty)` was retired on 2026-09-19;
the live function no longer exists. The canonical helper is `calculate_player_fleet_fuel_for_distance(...)`.

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

Architectural note: the three dispatchers inline the approved modifier sum. The former duplicate helper
`get_player_fleet_speed_multiplier(player, planet)` was retired with the dead legacy cluster on 2026-09-19,
so the dead parallel path no longer remains deployed.

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

## 11. Movement lifecycle / idempotency — 2026-09-19

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
mission-specific resolver                 (including HOLDING → persisted holding state)
        ↓
ARRIVED → HOLDING / RETURNING / COMPLETED
        ↓
HOLDING → RETURNING when holding_until is due
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

## 13. ACS / HOLDING / DEFEND — state: FASE A IMPLEMENTED (see §22)

| Layer | State | Evidence (LIVE) |
|---|---|---|
| Speed class | **IMPLEMENTED** | the classifier maps `ACS_HOLD`/`HOLDING`/`DEFEND` → `holding_fleet_speed` |
| Universe column | **READY** | `universes.holding_fleet_speed` exists, `NOT NULL DEFAULT 1`, independent from the other two |
| Dispatch RPC | **IMPLEMENTED (Fase A)** | single `start_support_fleet(...)`; `ACS_HOLD` accepted, `DEFEND` → `COMBAT_SUPPORT_NOT_READY`, `HOLDING` → `HOLDING_IS_INTERNAL_STATE` |
| Persistence | **IMPLEMENTED** | `fleet_movements` admits the three mission names, stores `holding_until` and `idempotency_key`; the legacy constraints that blocked them were removed (§22.1) |
| Lifecycle worker | **IMPLEMENTED** | due support becomes `HOLDING` after validating the holding window; due `holding_until` becomes `RETURNING` reusing the outbound duration |
| Player dispatch | **IMPLEMENTED (backend only)** | no frontend caller yet; the UI phase is separate |
| Destination semantics | **IMPLEMENTED (temporary explicit policy)** | `planet_support_authorizations`: the destination owner grants/revokes a planet-scoped authorization; planet existence is never authorization |
| Combat integration | **NOT_IMPLEMENTED — BLOCKED BY COMBAT ENGINE** | `DEFEND` cannot be created and cannot enter `HOLDING` |
| Holding fuel | **NOT_IMPLEMENTED (product decision pending)** | no deuterium tick is invented for the hold window |
| Maximum holding duration | **OPEN (product decision)** | no arbitrary maximum is hardcoded; only `holding_until > arrives_at` and future-ness are enforced |
| UI | **NOT_IMPLEMENTED** | no ACS selector; the future selector will be `ACS_HOLD` + `DEFEND` (DEFEND stays closed) |

Actual implemented pipeline (migration `20260919100000_add_acs_hold_support_dispatch`):

```text
start_support_fleet (SECURITY DEFINER, ownership check)
   ↓ calculate_player_ship_speed(player, ship)                     -- slowest effective ship
   ↓ calculate_mission_fleet_speed_multiplier(universe, 'ACS_HOLD')  -> holding_fleet_speed
   ↓ E^(1/3) + lifeform/item modifiers (same ordering as §5)
   ↓ calculate_fleet_travel_time(...)  → arrives_at
   ↓ holding_until (absolute UTC timestamp) → HOLDING window
   ↓ fuel: calculate_player_fleet_fuel_for_distance(..., outbound flight time)
   ↓ return leg: reuse the persisted duration (worker pattern of §11)
```

`HOLDING` is a lifecycle state, never a player-facing mission. Full technical record, tests, findings and
remaining blockers: §22.

Completed in migration `20260919053220_add_fleet_holding_lifecycle`: `fleet_movements.mission_type` admits
`ACS_HOLD`/`HOLDING`/`DEFEND`, `holding_until` is persisted, `HOLDING` is a durable movement state, and the worker
transitions `OUTBOUND → HOLDING → RETURNING` while reusing the outbound duration. The new mission types require a
non-null `holding_until` — but see §22.1: that migration added the broader constraints under new names while the
original `fleet_movements_mission_type_chk` / `fleet_movements_status_chk` remained in force, so until Fase A no
support row could actually exist in LIVE.

Remaining after Fase A: ACS combat integration and multi-defender settlement (`DEFEND` stays closed), validated
holding-fuel semantics, the maximum holding duration product decision, and UI. OGameX restricts ACS Defend to
buddies/alliance members and models physical arrival separately from the hold window; L.G.I. has no alliance/buddy
tables in LIVE, so that eligibility rule was not imported — Fase A uses a minimal explicit, revocable,
planet-scoped owner authorization instead (§22.3).

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

1. **ACS / HOLDING / DEFEND gameplay not implemented** (§13) — the lifecycle contract is now in place, but dispatch,
   support semantics, combat integration and UI remain the domain-level gameplay OPEN item.
2. **Browser fleet flow — OPEN**: backend correctness is not browser certification. Verify fleet selection, dispatch, persisted countdown, arrival, mission resolution and return in the browser.

### 15.2 Design / hygiene decisions left open

3. `calculate_universe_rates` still builds the fleet rate from the legacy `universes.fleet_speed`; decide the canonical meaning of a general fleet-rate snapshot now that three mission-speed classes exist.
4. Lifeform keys defined but never applied: `civilian_ship_speed_percent`, `recall_fuel_recovery_percent`.
5. `universes.expedition_speed` survives in `calculate_universe_rates`; it is no longer used for expedition travel time.

The 2026-09-18/19 directed Mission Modifiers / Technology / legacy audit found **no functional LIVE bug** in
the seven implemented mission paths. Technology routing, mission class routing, modifier ordering, fuel
ordering, double-application checks and legacy-bypass checks all passed. The six-function dead legacy cluster
was retired on 2026-09-19 after dependency, function-body and frontend consumer checks found no remaining callers.
The remaining items above are browser certification or bounded architecture decisions, not an unresolved gameplay defect.


## 16. Tests

```text
supabase/tests/fleet_speed_classes.sql        transactional (BEGIN … ROLLBACK) · 22/22 PASS live 2026-09-18
                                              + assertion 10/10c updated for ACS_HOLD Fase A (pending LIVE re-run)
supabase/tests/fleet_acs_hold_lifecycle.sql   transactional (BEGIN … ROLLBACK) · ACS_HOLD Fase A (pending LIVE run)
```

Covers: single class authority · class matrix incl. HOLDING and the legacy fallback · invalid-class exception
· 3/3 dispatch wiring · no parallel travel formula (`35000` appears only twice) · expedition hold resolves the
class · technology routing single authority · fuel reduction applied once without hyperspace · legacy cluster verified consumer-free before retirement · ACS/HOLDING not dispatchable while `holding_fleet_speed` is ready. The failure
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
- ACS Defend is a distinct mission: OGameX separates physical arrival from the hold window, restricts dispatch to buddies/alliance members, and feeds arrived ACS defend fleets into multi-defender combat.
- OGameX tracks ACS defender fleet identity/owner through combat so per-fleet survival/results remain attributable; L.G.I. must decide its equivalent before combat integration.

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


## 19. Mission Modifiers closure / legacy cleanup — 2026-09-19

Mission Modifiers is **CLOSED functionally** for the seven implemented mission paths. The canonical pipeline is
`calculate_player_ship_speed()` → `calculate_mission_fleet_speed_multiplier()` → `E^(1/3)` → item/lifeform
modifiers → `calculate_fleet_travel_time()` → persisted timing, with fuel delegated to
`calculate_player_fleet_fuel_for_distance()` and no duplicate fuel modifier.

Frontend inspection found only the active `start_fleet` path in `GalaxyView.tsx`; no frontend caller used the
legacy calculation RPCs. LIVE dependency and source-body checks found no remaining database consumers. On
2026-09-19 migration `20260919042419_retire_legacy_fleet_calculation_rpc_cluster` removed:
`calculate_expedition_time`, `calculate_fleet_time`, `calculate_fleet_fuel`, `calculate_fleet_fuel_mixed`,
`calculate_fleet_fuel_for_distance`, and `get_player_fleet_speed_multiplier`. `calculate_fleet_travel_time`
and `calculate_universe_rates` were intentionally preserved.

This cleanup is hygiene, not a gameplay-rule change. ACS/HOLDING/DEFEND remains intentionally unimplemented
and browser fleet certification remains open.


## 20. Holding audit correction — 2026-09-19

The first HOLDING migration was compared against the recovered canonical worker migration `20260918095306_harden_fleet_movement_idempotency_and_processing`. The mission-specific arrival/return branches were preserved, but the initial replacement omitted two existing hardening details:

- partial indexes `fleet_movements_outbound_arrival_idx` and `fleet_movements_returning_idx`;
- the private worker ACL (`REVOKE EXECUTE ... FROM PUBLIC, anon, authenticated`).

This was detected before ACS dispatch implementation and corrected LIVE by migration `20260919060000_restore_fleet_worker_hardening` and the matching repository migration file. LIVE verification confirms the worker remains private and the HOLDING transitions are present. Do not edit migration history to repair this class of drift; add a forward correction migration.


## 21. ACS combat prerequisite audit — 2026-09-19

Before implementing player-facing ACS dispatch, combat integration must be treated as a separate structural work item. LIVE `combat_battles` currently has one `fleet_id`, one `attacker_player_id` and one `defender_planet_id`; `resolve_combat(uuid)` snapshots exactly one attacking fleet plus the target planet's stationary ships/defenses. `resolve_attack_arrival(uuid)` then writes surviving attacker ships back to the movement and target planet state. This is a single-defender model, not yet an ACS multi-defender model.

Therefore the next implementation boundary is **not** to make `resolve_attack_arrival()` inspect ACS rows ad hoc. First define a durable battle-participant model that can attribute each defending support fleet to its owner and source movement, preserve per-fleet survival, and settle each surviving fleet back to its own origin. This matches the OGameX reference pattern where ACS defender fleets are explicit battle participants with fleet/owner identity and multi-defender results.

No combat schema or resolver changes were made in this audit.

## 22. ACS_HOLD Fase A — 2026-09-19

Player-facing ACS_HOLD support dispatch, its minimal authorization policy and the complete holding lifecycle.
Reference for behaviour only: OGameX `AcsDefendMission` / `FleetMissionService` / `DefenderFleet` /
`FleetDispatchAcsDefendTest`. No OGameX architecture, table or code was copied, and its holding cost was **not**
imported (see §22.5).

### 22.1 Migration `20260919100000_add_acs_hold_support_dispatch`

**Forward correction (blocker found by provenance inspection).** `20260919053220_add_fleet_holding_lifecycle`
created the broader `fleet_movements_mission_type_check` / `fleet_movements_status_check` constraints but dropped
constraint names that never existed; the original table constraints `fleet_movements_mission_type_chk`
(7 missions) and `fleet_movements_status_chk` (no `HOLDING`) were therefore still enforcing the old sets. Because
CHECK constraints are ANDed, LIVE could not store `ACS_HOLD`/`HOLDING`/`DEFEND` nor the `HOLDING` status: the
documented holding lifecycle was unreachable. Fase A removes the two legacy constraints (the `*_check` pair stays
as the single mission/status authority). No gameplay value changed; the new set is a strict superset.

Other durable schema changes:

- `fleet_movements.holding_until > arrives_at` (`fleet_movements_holding_until_after_arrival_check`);
- `fleet_movements.idempotency_key uuid` + partial unique index
  `fleet_movements_player_idempotency_key_uq (player_id, idempotency_key)`;
- `public.planet_support_authorizations` (RLS enabled, `deny_direct_api_access` policy, unique
  `(destination_planet_id, guest_player_id)`), managed only through
  `grant_planet_support_authorization(...)` / `revoke_planet_support_authorization(...)`.

### 22.2 Single dispatcher `start_support_fleet(...)`

```text
start_support_fleet(p_player_id, p_origin_planet_id, p_destination_planet_id,
                    p_ships jsonb, p_support_mission text,
                    p_holding_until timestamptz, p_idempotency_key uuid)
```

- One dispatcher for support missions. `ACS_HOLD` is accepted; `DEFEND` raises
  `COMBAT_SUPPORT_NOT_READY`; `HOLDING` raises `HOLDING_IS_INTERNAL_STATE`; any other value raises
  `Invalid support mission type`. No `start_acs_hold` / `start_defend` / `start_holding` exists.
- Identity: `auth.uid()` must resolve through `players.user_id` to `p_player_id`; the origin planet must belong to
  that player. The client-provided `p_player_id` is never trusted alone.
- Destination: exists, not destroyed, same universe, **foreign** (never the player's own planet) and covered by an
  active authorization. `planet exists → ACS allowed` is explicitly *not* the rule.
- Composition: non-empty JSON object, positive integers, known ships, availability checked under `FOR UPDATE`;
  travel time uses the **slowest effective ship** from `calculate_player_ship_speed` (never
  `ship_definitions.speed`).
- Pipeline: `calculate_mission_fleet_speed_multiplier(universe,'ACS_HOLD')` → `holding_fleet_speed` →
  `E^(1/3)` → item/lifeform `fleet_speed_percent` → `calculate_fleet_travel_time` → fuel through
  `calculate_player_fleet_fuel_for_distance` with the outbound flight time (applied once, lifeform reduction
  only). The dispatcher body contains no `35000`, no `.speed` read and no `universes` read (assertion F3).
- `holding_until` must exist, be in the future and be strictly after the computed `arrives_at`
  (`HOLDING_UNTIL_REQUIRED` / `HOLDING_UNTIL_NOT_IN_FUTURE` / `HOLDING_UNTIL_BEFORE_ARRIVAL`). **No maximum
  duration is enforced**: the product limit is still an OPEN decision, so no arbitrary constant was hardcoded.
- Atomicity: fuel check → fuel deduction → ship deduction → `fleet_movements` → `fleet_movement_ships`, all in the
  dispatcher's single transaction. There is no code path that can persist a movement without its fuel/ship
  deduction or a deduction without its movement.
- Idempotency: `p_idempotency_key` is required. A replay returns the durable movement of the first request
  (`idempotent_replay = true`) without mutating anything; the partial work of a call that loses the unique-index
  race is rolled back by its own subtransaction and the winner's movement is returned.
- ACL: `REVOKE ... FROM PUBLIC, anon` + `GRANT ... TO authenticated` for all three new RPCs.


### 22.3 Authorization policy (temporary, explicit)

L.G.I. has no alliance/buddy/consent structure in LIVE. The phase therefore ships one minimal primitive instead of
inventing a social system: the **destination owner** explicitly authorizes a specific foreign player on a specific
planet, with optional expiry and revocation. The dispatcher requires an active row
(`revoked_at IS NULL AND (expires_at IS NULL OR expires_at > now())`); expired or revoked authorizations are
rejected exactly like a missing one. This is a deliberate product decision pending the alliance/buddy design.

### 22.4 Worker lifecycle `20260919101000_extend_acs_hold_worker_lifecycle`

`process_fleet_movements()` is extended in place — no second worker:

```text
OUTBOUND → ARRIVED → HOLDING        only after validating the persisted holding window
HOLDING  → RETURNING                now() >= holding_until, returns_at = holding_until + outbound duration
RETURNING → COMPLETED               existing settlement (ships + cargo back to origin)
```

- Invalid or missing `holding_until` on arrival raises `SUPPORT_HOLDING_WINDOW_*` inside the worker transaction, so
  a support movement can never remain `ARRIVED` with a half-initialised hold.
- `DEFEND` never enters `HOLDING`: the worker emits a WARNING and leaves the row in `ARRIVED`. This is a defensive
  guard for a state that no live path can create (the dispatchers reject `DEFEND`, and `fleet_movements` has no
  INSERT policy for client roles). Raising there would abort the whole worker batch, so the safe rejection is
  explicit and non-fatal.
- The return leg reuses the persisted outbound duration; the worker contains no
  `calculate_fleet_travel_time` / `calculate_player_ship_speed` / `calculate_player_fleet_fuel_for_distance` /
  `35000` (assertion F4). The hold is never extended automatically.
- L.G.I. has no `QUEUED` movement status: an accepted dispatch is created directly as `OUTBOUND`, as every other
  implemented mission already does. This is an intentional difference from the conceptual `QUEUED → OUTBOUND`
  sketch.

### 22.5 Fuel semantics in Fase A

Outbound fuel only, through the canonical helper, exactly like the other missions. **Holding fuel is NOT
IMPLEMENTED**: OGameX charges for the hold window, L.G.I. has no product rule for it, and inventing a deuterium
tick would contaminate the canonical helper. Pending decision. Return-leg fuel keeps the existing project
behaviour (no second charge).

### 22.6 OGameX classification

| Item | Classification |
|---|---|
| Support target is a foreign planet; own planet is not a valid ACS_HOLD target | OGameX reference → L.G.I. equivalent (`ACS_HOLD_DESTINATION_OWN_PLANET`) |
| Slowest-ship speed + mission speed class | OGameX reference → L.G.I. equivalent (`holding_fleet_speed`) |
| Physical arrival distinct from the hold window | OGameX reference → L.G.I. equivalent (`arrives_at` vs `holding_until`) |
| Return after the hold | OGameX reference → L.G.I. equivalent (`RETURNING` reusing the outbound duration) |
| Recall during outbound/holding | OGameX reference → **L.G.I. missing** (no recall path exists for any mission; out of Fase A scope) |
| Normal fleet composition (multi-ship) | OGameX reference → L.G.I. equivalent (`fleet_movement_ships`) |
| Buddy/alliance dispatch eligibility | OGameX reference → **L.G.I. missing** (no alliance/buddy tables) → replaced by the temporary explicit authorization policy by product decision (§22.3) |
| Holding deuterium cost | OGameX reference → **L.G.I. intentionally different / not implemented** (product rule pending, §22.5) |
| Multi-defender ACS combat participation | OGameX reference → **L.G.I. missing** → `DEFEND` and combat integration stay BLOCKED (§21) |
| `QUEUED` mission status | OGameX reference → **L.G.I. intentionally different** (no `QUEUED`; created as `OUTBOUND`) |
| Prerequisite re-validation at dispatch | L.G.I. intentionally follows `start_fleet_mixed` (no `check_ship_requirements` at dispatch; ownership and availability only) |

### 22.7 Blockers / findings recorded by this phase

1. **Product blocker — maximum holding duration**: not defined by the product, therefore not enforced.
2. **Product blocker — holding fuel**: not defined, therefore not implemented (§22.5).
3. **Structural blocker — combat**: `DEFEND` and multi-defender settlement, unchanged from §21.
4. **Finding — provenance gap**: `calculate_player_ship_fuel_consumption` is referenced by the canonical fuel
   helper in `20260919042952_reconcile_fleet_mission_and_monitor_provenance`, but its `CREATE` is absent from every
   repository migration; it exists in LIVE only. It was **not** recreated here (that would duplicate the single
   engine-consumption authority), but the migration history cannot reproduce it.
5. **Finding — dispatcher/classifier claim not reproducible**: no repository migration makes `start_fleet` /
   `start_fleet_mixed` call `calculate_mission_fleet_speed_multiplier`; the last authored bodies (and the recovered
   `20260918094440` / `20260918095005` patchers) still read `universes.fleet_speed`. The §10 claim and
   `fleet_speed_classes.sql` assertion 4 must be re-verified against LIVE before being trusted. Fase A does not
   depend on it: `start_support_fleet` resolves its own class explicitly.
6. **Pending verification**: `fleet_acs_hold_lifecycle.sql` and the updated `fleet_speed_classes.sql` must be
   executed in LIVE (SQL Editor / `execute_sql`). This environment had no database credentials and no local
   Postgres/Docker, so the SQL was validated structurally (balanced blocks, canonical-helper-only bodies) but not
   executed here.
