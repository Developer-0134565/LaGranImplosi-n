# FLEET ENGINE — LA GRAN IMPLOSIÓN

> Deep sweep of the fleet mission engine (2026-09-18). Scope: **mission modifiers, mission speed
> classes, ACS/Holding/Defend, technology routing, fuel ordering, parallel/legacy routes**.
> Everything below was verified against the LIVE database (`pg_get_functiondef`, ACLs, constraints,
> live data). Related docs:
> [`../UNIVERSE_RATE_AND_FLEET_ENGINE_MONITOR.md`](../UNIVERSE_RATE_AND_FLEET_ENGINE_MONITOR.md) ·
> [`README_UNIVERSE_EVOLUTION.md`](README_UNIVERSE_EVOLUTION.md) ·
> [`README_FUNCTIONAL_AUDIT.md`](README_FUNCTIONAL_AUDIT.md).

Status: **CANONICAL PIPELINE CONVERGED · OPEN (ACS/HOLDING not implemented, design decisions listed)**

## 1. Mission speed classes

Single authority (LIVE): `calculate_mission_fleet_speed_multiplier(p_universe_id uuid, p_mission_type text)`
→ `numeric`, `STABLE`, `SECURITY DEFINER`, `search_path = public, pg_temp`, ACL **postgres/service_role
only** (not a public API; the sweep must not revert this).

```sql
WHEN mission IN ('TRANSPORT','DEPLOY','COLONIZE','EXPEDITION')   -> universes.peaceful_fleet_speed
WHEN mission IN ('ATTACK','ESPIONAGE','RECYCLE','RECYCLE_ATTACK','HARVEST') -> universes.war_fleet_speed
WHEN mission IN ('ACS_HOLD','HOLDING','DEFEND')                  -> universes.holding_fleet_speed
ELSE                                                             -> universes.fleet_speed   -- legacy fallback
-- NULL or <= 0 -> RAISE 'Invalid fleet speed for mission %'
```

```text
PEACEFUL : TRANSPORT · DEPLOY · COLONIZE · EXPEDITION
WAR      : ATTACK · ESPIONAGE · RECYCLE
HOLDING  : ACS_HOLD · HOLDING · DEFEND        (class + column prepared; dispatch NOT implemented — §8)
```

`universes.fleet_speed` is **only** a fallback for unknown mission names. It must never become the
universal multiplier again.

## 2. Mission modifier pipeline (canonical, verified in the 3 dispatch RPCs)

```text
ship_definitions.speed
   ↓  calculate_player_ship_speed(player, ship)          -- active propulsion + technology level
effective ship speed
   ↓  calculate_mission_fleet_speed_multiplier(universe, mission)   -- mission class column
classic mission speed
   ↓  power(calculate_universe_evolution_rate(universe), 1.0/3.0)   -- L.G.I. evolution E^(1/3)
   ↓  calculate_fleet_travel_time(distance, ship_speed, fleet_rate, 100)
travel time (seconds)
```

Effective fleet rate actually used by the dispatchers:

```sql
v_fleet_speed := calculate_mission_fleet_speed_multiplier(universe_id, mission);
v_bonus       := 1 + ( item fleet_speed_percent + lifeform research fleet_speed_percent ) / 100;
                 -- EXPEDITION additionally: + lifeform research expedition_speed_percent / 100
v_fleet_rate  := v_fleet_speed * power(v_evolution, 1.0/3.0) * v_bonus;
v_travel_time := calculate_fleet_travel_time(v_distance, v_ship_speed, v_fleet_rate, 100);
```

Travel-time formula (single implementation, `IMMUTABLE`):

```sql
calculate_fleet_travel_time(distance, ship_speed, fleet_rate, speed_percent) =
    round( greatest( ((35000 / speed_percent) * sqrt(distance * 10 / ship_speed) + 10) / fleet_rate, 1 ), 4 )
```

Only **two** functions in the whole schema contain the constant `35000`: this helper and
`calculate_player_fleet_fuel_for_distance` (fuel re-derives speed from the flight time). There is no
inline travel-time formula anywhere else (assertion 5 of the test enforces it).

`power(E, 1/3)` equals `calculate_universe_scaling(E).fleet_movement_scale` — two code routes, same
value. Dispatchers use the inline cube root; expedition helpers use the scaling record.

## 3. Mission modifier matrix (extracted from the implementation, not invented)

| Mission | Ship speed | Universe multiplier | Evolution | Lifeform | Item | Final travel time |
|---|---|---|---|---|---|---|
| TRANSPORT | technology of the ships in the fleet (min speed) | `peaceful_fleet_speed` | `E^(1/3)` | `fleet_speed_percent` (research) | `fleet_speed_percent` (item) | `calculate_fleet_travel_time` |
| DEPLOY | idem | `peaceful_fleet_speed` | `E^(1/3)` | `fleet_speed_percent` | `fleet_speed_percent` | idem |
| COLONIZE | `colony_ship` (impulse) | `peaceful_fleet_speed` | `E^(1/3)` | `fleet_speed_percent` | `fleet_speed_percent` | idem |
| EXPEDITION | min speed of the fleet | `peaceful_fleet_speed` | `E^(1/3)` | `fleet_speed_percent` **+ `expedition_speed_percent`** | `fleet_speed_percent` | idem (+ hold/delay, §7) |
| ATTACK | min speed of the fleet | `war_fleet_speed` | `E^(1/3)` | `fleet_speed_percent` | `fleet_speed_percent` | idem |
| ESPIONAGE | `espionage_probe` (combustion) | `war_fleet_speed` | `E^(1/3)` | `fleet_speed_percent` | `fleet_speed_percent` | idem |
| RECYCLE | `recycler` (hyperspace ≥15 / impulse ≥17 / combustion) | `war_fleet_speed` | `E^(1/3)` | `fleet_speed_percent` | `fleet_speed_percent` | idem |
| ACS_HOLD | — (not dispatchable) | `holding_fleet_speed` (classifier ready) | — | — | — | — |
| HOLDING | — (not dispatchable) | `holding_fleet_speed` (classifier ready) | — | — | — | — |
| DEFEND | — (not dispatchable) | `holding_fleet_speed` (classifier ready) | — | — | — | — |

Live evidence of routing (test assertion 2): with a transactional probe universe
(`fleet_speed=7, peaceful=2, war=3, holding=5`) the classifier returned
`2` for TRANSPORT/DEPLOY/COLONIZE/EXPEDITION, `3` for ATTACK/ESPIONAGE/RECYCLE, `5` for
ACS_HOLD/HOLDING/DEFEND and `7` for an unknown mission.

## 4. Technology routing (propulsion)

Single authority for ship speed (LIVE, `STABLE SECURITY DEFINER`):
`calculate_player_ship_speed(player_id, ship_id)`:

```text
small_cargo        : impulse_drive >= 5 ? 10000*(1+0.2*impulse) : base*(1+0.1*combustion)
bomber             : hyperspace_drive >= 8 ? 5000*(1+0.3*hyper) : base*(1+0.2*impulse)
recycler           : hyperspace >= 15 ? 6000*(1+0.3*hyper) : impulse >= 17 ? 4000*(1+0.2*impulse)
                     : base*(1+0.1*combustion)
large_cargo, light_fighter, espionage_probe : base*(1+0.1*combustion_drive)
heavy_fighter, cruiser, colony_ship        : base*(1+0.2*impulse_drive)
battleship, destroyer, deathstar, battlecruiser, reaper, pathfinder : base*(1+0.3*hyperspace_drive)
default                                     : base
```

Single authority for engine-related consumption: `calculate_player_ship_fuel_consumption(player, ship)`
(same techs, same engine thresholds: `small_cargo` impulse≥5 → `base*2`; `bomber` hyper≥8 → `1000`;
`recycler` hyper≥15 → `900`, impulse≥17 → `600`).

These are the **only two** functions in the schema that read `combustion_drive` / `impulse_drive` /
`hyperspace_drive` (assertions 7/7b). The ship→engine choice lives inside those functions (not in
`ship_definitions` data), so there is exactly one routing implementation and no technology is applied
twice: each technology influences ship speed once and engine consumption once, and never re-enters the
travel-time or fuel pipeline.

```
ship → available propulsion → active propulsion (thresholds) → technology level
     → effective ship speed → mission class → universe multiplier → E^(1/3) → lifeform/item → time
```

## 5. Lifeform / item modifiers

| Effect key | Computed by | Summed by | Applied in | Times |
|---|---|---|---|---|
| `fleet_speed_percent` (research) | `get_active_lifeform_research_effect(player, key)` | dispatchers (inline) | `v_bonus` of the 3 dispatch RPCs | 1 |
| `fleet_speed_percent` (item) | `get_active_expedition_item_effect(player, planet, key)` | dispatchers (inline) | `v_bonus` of the 3 dispatch RPCs | 1 |
| `expedition_speed_percent` (research) | `get_active_lifeform_research_effect` | dispatchers (inline) | `v_bonus`, EXPEDITION only | 1 |
| `fuel_reduction_percent` (lifeform) | `get_player_lifeform_effect(player, key)` | `calculate_player_fleet_fuel_for_distance` | after distance/time/mass consumption, clamped `0..30` | 1 |
| `civilian_ship_speed_percent` (research) | — | — | **never applied** | 0 (dead key) |
| `recall_fuel_recovery_percent` (research) | — | — | **never applied** | 0 (dead key) |

**No double application found** in the live paths: the speed bonus enters the fleet rate once and the
fuel helper does not re-apply speed bonuses; the fuel reduction is applied exactly once
(assertion 8 counts a single occurrence of `fuel_reduction_percent` in the fuel helper).

Architectural note (duplication, not a bug): the three dispatchers **inline** the formula that
`get_player_fleet_speed_multiplier(player, planet)` already implements. That helper is currently used
only by dead code (`calculate_expedition_time`), so the same modifier sum exists in two places — a
divergence risk to converge in a future mission.

## 6. Fuel ordering

```text
ship_definitions.fuel_consumption
   ↓ calculate_player_ship_fuel_consumption(player, ship)   -- engine-related consumption
   ↓ calculate_player_fleet_fuel_for_distance(distance, flight_time, player, ship, qty, speed_percent)
        v_speed       := 35000 / max(t * speed_percent * 10 - 10, 1) * sqrt(distance * 10 / ship_speed)
        v_consumption := qty * base_consumption * distance / 35000 * power(v_speed/10 + 1, 2)
   ↓ fuel_reduction_percent  (get_player_lifeform_effect, clamped 0..30)
final fuel = greatest(1, ceil(consumption))
```

`hyperspace_technology` is **not** a generic fuel reduction: it only selects the engine (and therefore
the engine consumption) inside `calculate_player_ship_fuel_consumption`. The legacy helper
`calculate_fleet_fuel_for_distance(distance, ship, qty)` now hard-fails with
`'… is legacy: use calculate_player_fleet_fuel_for_distance(…)'`, so an old caller would break loudly
instead of silently using the old order.

## 7. Return leg, expedition hold and the worker

- `process_fleet_movements()` (pg_cron `deuteria-fleet-worker`, every second, runs as **postgres**) reuses
  the outbound duration: `v_duration := arrives_at - started_at` → `returns_at = arrives_at + v_duration`.
  The `resolve_*_arrival` functions do the same (`transport`, `espionage`, `attack`:
  `returns_at = arrives_at + v_duration`); `deploy`/`colonize` complete with `returns_at = NULL`.
  → no second speed formula on the return leg, and modifiers cannot be applied twice there.
- Expeditions: `resolve_expedition_arrival` sets
  `returns_at = arrives_at + actual_hold + return_seconds` (hold comes from
  `calculate_expedition_total_hold_seconds` → `calculate_expedition_delay_seconds`; `return_seconds`
  is the outbound flight reduced by speed-up items, never below 1 s).
- **Convergence applied 2026-09-18**: `calculate_expedition_delay_seconds` used the legacy
  `universes.fleet_speed` (the last LIVE bypass of the canonical pipeline, in an active path —
  EXPEDITION belongs to PEACEFUL). It now resolves the class with
  `calculate_mission_fleet_speed_multiplier(universe, 'EXPEDITION')`. Migration
  `20260918100000_converge_expedition_hold_to_mission_class` (applied to LIVE + recorded in
  `supabase_migrations.schema_migrations`). Numeric impact: **none** — live values are
  `fleet_speed = peaceful_fleet_speed = 1`, and the returned delays were identical before/after
  (4439/6659/11099 and 4438/6658/11096 for three live expedition fleets).

## 8. ACS / HOLDING / DEFEND — state: OPEN (not implemented)

| Layer | State | Evidence (LIVE) |
|---|---|---|
| Speed class | **DEFINITION_ONLY** | `calculate_mission_fleet_speed_multiplier` maps `ACS_HOLD`/`HOLDING`/`DEFEND` → `holding_fleet_speed` |
| Universe column | **READY** | `universes.holding_fleet_speed` exists, `NOT NULL DEFAULT 1`, independent from the other two classes |
| Dispatch RPC | **NOT_IMPLEMENTED** | `start_fleet`, `start_fleet_mixed`, `start_colonize_fleet` reject any mission outside the 7 implemented ones |
| Persistence | **NOT_IMPLEMENTED** | `fleet_movements_mission_type_chk` allows only `ATTACK, TRANSPORT, DEPLOY, ESPIONAGE, COLONIZE, RECYCLE, EXPEDITION` |
| Tables | **NOT_IMPLEMENTED** | no ACS/holding/support table exists (`fleet_movements`, `fleet_movement_ships` only) |
| Resolution / UI | **NOT_IMPLEMENTED** | no `resolve_*` branch, no UI entry point |

Required pipeline when it is built (do NOT ship a partial version):

```text
start_acs_hold/start_defend (SECURITY DEFINER, ownership check)
   ↓ calculate_player_ship_speed(player, ship)
   ↓ calculate_mission_fleet_speed_multiplier(universe, 'ACS_HOLD' | 'HOLDING' | 'DEFEND')
        -> holding_fleet_speed   (never peaceful_*/war_*)
   ↓ E^(1/3) + lifeform/item modifiers (same ordering as §2)
   ↓ calculate_fleet_travel_time(...)  → holding window (arrives_at + hold duration)
   ↓ fuel: calculate_player_fleet_fuel_for_distance(...) with the outbound flight time
   ↓ return leg: reuse the duration (worker pattern of §7)
```

Also required before ACS exists: `fleet_movements.mission_type` CHECK extension, destination semantics
(support target = foreign planet), holding-duration persistence and fleet-support combat integration.

## 9. Route classification (map produced by the sweep)

| Function | Class | Notes |
|---|---|---|
| `calculate_mission_fleet_speed_multiplier` | **CANONICAL** | single mission→class authority; not granted to clients |
| `calculate_fleet_travel_time` | **CANONICAL** | only travel-time formula; `IMMUTABLE` |
| `calculate_player_ship_speed` | **CANONICAL** | only propulsion→speed routing |
| `calculate_player_ship_fuel_consumption` | **CANONICAL** | only engine→consumption routing |
| `calculate_player_fleet_fuel_for_distance` | **CANONICAL** | fuel ordering (lifeform reduction once) |
| `start_fleet` / `start_fleet_mixed` / `start_colonize_fleet` | **CANONICAL** | 3/3 wired to classifier + `E^(1/3)` + helper |
| `resolve_*_arrival` + `process_fleet_movements` | **CANONICAL** | return leg = outbound duration; no speed math |
| `calculate_expedition_delay_seconds` | **CANONICAL (was PARALLEL)** | converged 2026-09-18 (§7) |
| `calculate_universe_rates` | **PARALLEL / DISTINCT PURPOSE** | informational rate snapshot; still uses `fleet_speed` × `fleet_movement_scale` and ignores the class columns → §10 |
| `calculate_fleet_time` | **LEGACY (dead)** | hardcodes the `TRANSPORT` class; only reached by the two dead fuel helpers |
| `calculate_fleet_fuel` | **LEGACY (dead)** | no live callers |
| `calculate_fleet_fuel_mixed` | **LEGACY (dead)** | no live callers; uses the legacy time helper |
| `calculate_fleet_fuel_for_distance` | **LEGACY (dead + hard-fail)** | raises `'… is legacy: use calculate_player_fleet_fuel_for_distance(…)'` |
| `calculate_expedition_time` | **LEGACY (dead)** | superseded expedition route (`universes.expedition_speed` + `get_player_fleet_speed_multiplier`) |
| `get_player_fleet_speed_multiplier` | **DUPLICATE** | correct formula, but only dead code uses it; the dispatchers inline the same sum (§5) |

## 10. Known gaps

1. **ACS / HOLDING / DEFEND not implemented** (§8) — the only domain-level OPEN item of the fleet engine.
2. `calculate_universe_rates` still builds the fleet rate from the legacy `universes.fleet_speed`; deciding
   the canonical meaning of a "general fleet rate" (three classes now exist) is a design decision,
   deliberately not taken in this sweep.
3. Dead legacy cluster (`calculate_fleet_time`, `calculate_fleet_fuel`, `calculate_fleet_fuel_mixed`,
   `calculate_expedition_time`, `calculate_fleet_fuel_for_distance`) — inert but still deployed and in some
   cases still granted to clients; cleanup is a separate mission. **Never wire them back.**
4. Duplicated lifeform/item bonus sum (dispatchers inline vs `get_player_fleet_speed_multiplier`).
5. Lifeform keys defined but never applied: `civilian_ship_speed_percent`, `recall_fuel_recovery_percent`
   (balance decision pending).
6. `universes.expedition_speed` survives only in dead code + `calculate_universe_rates`; it is no longer
   used for expedition travel time (expeditions use the PEACEFUL class).
7. Out of this sweep's scope (security): the three fleet dispatch RPCs keep the historical guest branch
   (`ELSIF NOT EXISTS(… is_guest) THEN RAISE 'Authentication required'`), but their ACLs grant EXECUTE only
   to `postgres`/`authenticated`/`service_role` (not `anon`), so it is unreachable through the Data API.
   The hardened `start_fleet` body present in the *local* repo migration `20260918030000` does not match
   the LIVE body → see §12.

## 11. Tests

```text
supabase/tests/fleet_speed_classes.sql   transactional (BEGIN … ROLLBACK), 22/22 PASS live 2026-09-18
```

Covers: single class authority · class matrix incl. HOLDING and the legacy fallback (11 rows) · invalid
class exception · 3/3 dispatch wiring · no parallel travel formula (`35000` appears only twice) ·
expedition hold resolves the class · technology routing single authority · fuel reduction applied once
without hyperspace · legacy cluster without live consumers · ACS/HOLDING not dispatchable while
`holding_fleet_speed` is ready. Executable through the project's MCP `execute_sql` / SQL editor; the
failure message lists every failing assertion, so a run without notice output is still self-diagnosing.

## 12. Repository ↔ LIVE drift (important for future missions)

LIVE `supabase_migrations.schema_migrations` (259 rows) has a **newer head than this repository**:

```text
20260918095315  deduplicate_fleet_event_indexes
20260918095306  harden_fleet_movement_idempotency_and_processing
20260918095029  fix_zero_level_drive_research_lookup
20260918095009  lock_internal_drive_calculation_helpers
20260918095005  apply_drive_tech_to_fleet_dispatch
20260918094959  add_ogame_drive_speed_and_fuel_logic
20260918094440  use_canonical_fleet_travel_time_in_dispatch
20260918094128  lock_internal_shipyard_queue_until
20260918094108  harden_shipyard_queue_processing_ownership
20260918085406  20260918110000_add_can_start_research_contract
20260918100000  converge_expedition_hold_to_mission_class          (this sweep)
(local repo previously ended at 20260918030000)
```

The fleet-convergence migrations exist **only in LIVE** (no matching files in this working copy, in
`_LGI_CONSOLIDATION_BACKUP_2026-09-18` or in `LaGranImplosi-n__CLONE_A_QUARANTINE`). Consequence:
`supabase db push` from this folder would replay old bodies and could **regress** the converged
pipeline. Recover the missing migration files (or re-dump the schema) before any push; the LIVE
function definitions remain the authority in the meantime.

## 13. Maintenance rule

```text
Every new mission MUST: use calculate_mission_fleet_speed_multiplier for its class,
use calculate_fleet_travel_time for its duration, apply lifeform/item modifiers once
(§2 ordering), keep fuel in the order of §6, and reuse the outbound duration for the
return leg (§7). Any new inline speed/fuel formula is a regression.
```


