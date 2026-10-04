# 2026-10-01 — STUCK-STATE: los 4 anchors de llegada que el fix del 2026-09-30 no cubrió

## El hueco

`20260930240000` y `20260930241000` corrigieron la trampa «evento pasado + reloj del cuerpo ya
adelantado» (`INVALID_RESOURCE_TIMESTAMP`) en una lista **fija** de puntos de asentamiento. Al
auditar los call sites completos el 2026-10-01 se localizaron **cuatro** que seguían pasando el
timestamp crudo:

| Anchor | Cuerpo liquidado |
| --- | --- |
| `resolve_attack_arrival` | defensor |
| `resolve_espionage_arrival` | objetivo |
| `resolve_expedition_arrival` | origen |
| `apply_attack_loot` | defensor |

## Por qué era un stuck-state real

`process_fleet_movements` degrada cualquier error a
`raise warning 'FLEET_RESOLUTION_FAILED'`. Un `WARNING` no deshace nada ni se superficie, así que
el movimiento reintentaba **para siempre** y las naves —ya debitadas del planeta de origen en el
despacho— se perdían definitivamente. Sin presupuesto de reintentos, sin auto-sanación y sin
superficie de operador: la única traza era el warning.

Medido en LIVE (sondas con `ROLLBACK`, por el worker real `process_fleet_movements()`), con el
evento 2 h en el pasado y el cuerpo ya liquidado a `now()`:

```text
ANTES                                    DESPUÉS
ATTACK      OUTBOUND (tras 5 pasadas)   → COMPLETED   · 1 batalla
ESPIONAGE   OUTBOUND · 0 informes      → COMPLETED   · 1 informe
EXPEDITION  OUTBOUND                   → RETURNING   · resultado persistido
TRANSPORT   COMPLETED (control)        → COMPLETED   (sin regresión)
```

La alcanzabilidad es el **orden ORDINARIO** de eventos: el worker corre cada 1 s mientras
`universe-heartbeat` corre cada minuto y liquida todos los planetas a `now()`; cualquier acción del
jugador sobre el cuerpo (`start_building`, `cancel_building`, `load_fleet_cargo`, el comerciante, la
UI `sync_current_planet_resources`) hace lo mismo.

## El arreglo

El **mismo** clamp ya aceptado en 240000/241000, uno por anchor:

```text
greatest(<timestamp del evento>, last_calculated_at)
```

* Evento en el **futuro** (la vía certificada normal) → no-op, el anclaje a la hora del evento es
  byte-idéntico.
* Evento **detrás** → no queda tiempo transcurrido que acreditar, así que asentar en el reloj del
  propio cuerpo concede **cero producción extra** y deja terminar la misión.

La aserción 7 de `supabase/tests/fleet_stuck_attack_espionage_arrival_regression.sql` es la
anti-vacuuidad del propio arreglo: si un clamp empezara a fabricar producción, falla.

Las colas de hangar y defensa **no** se tocan: sólo filtran `finishes_at <= p_until` y no liquidan
recursos, luego no pueden lanzar.

## Lo que NO se cambió

`update_planet_resources_until` y su guarda `INVALID_RESOURCE_TIMESTAMP` (es correcta); costes,
tiempos, combustible, ventanas de espera, combate, topes de botín del 50 %, recompensas de
expedición, reglas de revelado de espionaje, y todas las firmas, volatilidad, `SECURITY` y
`search_path` (los cuerpos se cortan de `pg_get_functiondef()`, nunca se reescriben a mano).
Ninguna de las cuatro gana `EXECUTE` de cliente: siguen siendo internas.

Ver `docs/audits/STUCK_STATE_SWEEP_2026-10-01.md`.

---
# FLEET ENGINE — LA GRAN IMPLOSIÓN

> **Status:** LOCAL CONVERGENCE IN PROGRESS / HISTORICAL GAP — the checked-in local convergence artifact
> routes `start_fleet`, `start_fleet_mixed` and `start_colonize_fleet` through the demonstrated propulsion
> and mission-class helpers. LIVE parity and the complete fuel path remain unverified. **Browser certification
> remains OPEN**. ACS_HOLD Fase A is
> **IMPLEMENTED / NOT BROWSER-CERTIFIED** (§22): single support dispatcher + explicit destination-owner
> authorization + `OUTBOUND → ARRIVED → HOLDING → RETURNING → COMPLETED` lifecycle. `DEFEND` remains
> **BLOCKED BY COMBAT ENGINE**, holding fuel and maximum holding duration remain **OPEN**, UI is not built.
> Transversal audit 2026-09-25 (§27): the mission-modifier matrix was re-verified on the deployed bodies, three
> client-reachable internal calculation helpers were **closed** (ACL only, no formula change), the cargo/HOLDING
> integration was certified, and **recall was recorded as MISSING + PRODUCT DECISION** (not implemented).
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

## 5. Mission modifier pipeline (canonical, verified in the 4 dispatch RPCs)

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
| `fleet_speed_percent` (research) | `get_active_lifeform_research_effect(player, key)` | dispatchers (inline) | `v_bonus` of the 4 dispatch RPCs | 1 |
| `fleet_speed_percent` (item) | `get_active_expedition_item_effect(player, planet, key)` | dispatchers (inline) | `v_bonus` of the 4 dispatch RPCs | 1 |
| `expedition_speed_percent` (research) | `get_active_lifeform_research_effect` | dispatchers (inline) | `v_bonus`, EXPEDITION only | 1 |
| `fuel_reduction_percent` (lifeform) | `get_player_lifeform_effect(player, key)` | `calculate_player_fleet_fuel_for_distance` | after distance/time/mass consumption, clamped `0..30` | 1 |
| `civilian_ship_speed_percent` (research) | — | — | **never applied** | 0 (dead key) |
| `recall_fuel_recovery_percent` (research) | — | — | **never applied** | 0 (dead key) |

**No double application was found** in the live paths: the speed bonus enters the fleet rate once, the fuel
helper does not re-apply speed bonuses, and the fuel reduction is applied exactly once (assertion 8 counts a
single occurrence of `fuel_reduction_percent` in the fuel helper).

Measured occurrence counts per body (2026-09-20, `pg_get_functiondef`):

```text
start_fleet / start_fleet_mixed / start_colonize_fleet / start_support_fleet
    fleet_speed_percent     2   = item source + lifeform source, summed ONCE into v_bonus
                                  (two different sources, not the same modifier twice)
    expedition_speed_percent 1   start_fleet / start_fleet_mixed only, gated by mission = EXPEDITION
    expedition_speed_percent 0   start_colonize_fleet / start_support_fleet (correct: not expeditions)
    fuel_reduction_percent  0   never applied in a dispatcher
    classifier calls        1   exactly one classification per dispatch
    calculate_player_ship_speed 1
calculate_player_fleet_fuel_for_distance
    fuel_reduction_percent  1   the only application in the whole schema, clamped 0..30
    calculate_player_ship_speed 1  legitimate input (speed is re-derived from the flight time)
```

Architectural note: the four dispatchers inline the approved modifier sum. The former duplicate helper
`get_player_fleet_speed_multiplier(player, planet)` was retired with the dead legacy cluster on 2026-09-19,
so the dead parallel path no longer remains deployed (re-confirmed absent from LIVE on 2026-09-20).

## 10. Dispatch entrypoints

### 10.1 Evidence boundary

**LIVE VERIFIED**: the mission classifier, player-aware ship-speed helper, canonical travel-time helper,
and player-aware fleet-fuel contract are documented as the intended backend authorities. The four
LIVE-only migrations remain blocked by the Migration Provenance Gate.

**LOCAL REPRODUCIBLE**: migration
`20260920010000_converge_local_fleet_dispatch_classifiers.sql` removes only the demonstrated
`universes.fleet_speed` class bypass from `start_fleet` and `start_fleet_mixed`, and routes the
colonization dispatcher’s ship speed and mission class through the canonical helpers. It does not
reconstruct the fuel helper, expedition timing, or coordinate-distance payload.

**PROVENANCE GAP**: `calculate_player_ship_fuel_consumption` body is not recoverable and was not recreated,
wrapped, or replaced. The expedition inline `35000 / 100 * sqrt(...)` branch and colonization distance
calculation remain unchanged until their exact LIVE provenance is demonstrated.

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
start_support_fleet             → HOLDING  (ACS_HOLD; DEFEND and HOLDING are refused)
```

Dispatcher mission allow-lists (LIVE, 2026-09-20) — the four dispatchers partition the ten mission names
with no overlap and no gap:

```text
start_fleet          accepts TRANSPORT · DEPLOY · ESPIONAGE · RECYCLE · EXPEDITION · ATTACK   (6, no COLONIZE)
start_fleet_mixed    accepts TRANSPORT · DEPLOY · ESPIONAGE · RECYCLE · EXPEDITION · ATTACK   (6, no COLONIZE)
start_colonize_fleet accepts COLONIZE only (own RPC, own colony-ship requirement)
start_support_fleet  accepts ACS_HOLD only; DEFEND -> COMBAT_SUPPORT_NOT_READY,
                     HOLDING -> HOLDING_IS_INTERNAL_STATE, anything else -> Invalid support mission type
```

`COLONIZE` is therefore validated by its own dispatcher, not by `start_fleet`; calling `start_fleet` with
`COLONIZE` is rejected by the allow-list before any speed math runs. `fleet_movements.mission_type` carries a
CHECK constraint listing exactly those ten names.

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
| Player dispatch | **IMPLEMENTED (backend + UI)** | CORRECTED 2026-09-26: `src/FleetCommandPanel.tsx` dispatches `ACS_HOLD` through `start_support_fleet` from the FLOTA view; the earlier "no frontend caller yet" note predates the fleet UI block (the read contract for authorizations exists since `20260926214030`) |
| Destination semantics | **IMPLEMENTED (temporary explicit policy)** | `planet_support_authorizations`: the destination owner grants/revokes a planet-scoped authorization; planet existence is never authorization |
| Combat integration | **NOT_IMPLEMENTED — BLOCKED BY COMBAT ENGINE** | `DEFEND` cannot be created and cannot enter `HOLDING` |
| Holding fuel | **NOT_IMPLEMENTED (product decision pending)** | no deuterium tick is invented for the hold window |
| Maximum holding duration | **OPEN (product decision)** | no arbitrary maximum is hardcoded; only `holding_until > arrives_at` and future-ness are enforced |
| UI | **IMPLEMENTED** | CORRECTED 2026-09-26: the FLOTA view offers `ACS_HOLD` (with the destination selector and a holding window) plus the `SupportAuthorizationPanel` (grant/revoke/received); `DEFEND` stays closed (`COMBAT_SUPPORT_NOT_READY`) and `HOLDING` stays a non-dispatchable internal state. The earlier "no ACS selector" note predates that block |

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
| `start_fleet` / `start_fleet_mixed` / `start_colonize_fleet` | **CANONICAL — LIVE VERIFIED (2026-09-20)** | All three call `calculate_mission_fleet_speed_multiplier` with their own mission (`v_mission_type` / `'COLONIZE'`). No `universes.fleet_speed` read anywhere in any dispatcher. §23 records the verification and the now-unexecutable local convergence migration |
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
   *Progress 2026-09-26 (GAP B/GAP I closeout):* every RPC the browser calls exists in LIVE with `authenticated`
   EXECUTE and the 13 read contracts (fleets, expedition slots/items, inbox, moons, authorizations, battle /
   espionage / expedition reports, ranking, colony cap) answer for the authenticated owner; the mission surface now
   covers all nine dispatchable missions. A full browser-driven certification run is still pending.
3. **COLONIZE from a moon — OPEN PRODUCT DECISION (new, measured 2026-09-26).** `start_colonize_fleet` does not
   validate the origin kind, so a moon origin is accepted, and the fleet UI offers moons in the origin selector.
   Classic OGame forbids colonising from a moon. Not restricted (no rule invented); detail in §23.3 item 7.

### 15.2 Design / hygiene decisions left open

3. `calculate_universe_rates` still builds the fleet rate from the legacy `universes.fleet_speed`; decide the canonical meaning of a general fleet-rate snapshot now that three mission-speed classes exist.
4. Lifeform keys defined but never applied: `civilian_ship_speed_percent`, `recall_fuel_recovery_percent`.
5. `universes.expedition_speed` survives in `calculate_universe_rates`; it is no longer used for expedition travel time.
6. `universes.lifeform_speed` is a **lifeform build/research rate, not a fleet class**: its only readers are
   `calculate_lifeform_building_time`, `calculate_lifeform_research_time` and `calculate_universe_rates`.
   `calculate_mission_fleet_speed_multiplier` correctly never reads it. The name invites confusion with a
   fourth fleet speed class; it is not one.
7. `calculate_universe_rates` is not dead: it is the shared economy-rate projector called by nine functions
   (`calculate_planet_production`, `get_current_planet_resources`, `get_planet_economic_rates[_snapshot]`,
   `project_planet_resources`, `project_building_production`, `calculate_building_production_delta`,
   `update_planet_resources[_until_raw]`). Its `fleet` and `expedition` columns are informational outputs with
   no dispatch consumer. Decision 3 above is therefore about the *meaning* of those two columns only.
8. **`20260920010000_converge_local_fleet_dispatch_classifiers.sql` can never execute (2026-09-20 finding).**
   Its three patchers raise unless the legacy `SELECT u.fleet_speed INTO v_fleet_speed FROM public.universes …`
   / `SELECT sd.speed INTO v_ship_speed …` fragments are present. All six target fragments are absent from LIVE
   and all three dispatchers already call the canonical classifier, so the migration aborts on its first
   target. Its intended end state is **already LIVE**; the artifact is obsolete rather than pending.
   Zero runtime impact (never applied). Recommended bounded action: supersede it, or convert its three
   `RAISE EXCEPTION … not found` guards into idempotent skips. Not changed by this audit (report-only).

The 2026-09-18/19 directed Mission Modifiers / Technology / legacy audit found **no functional LIVE bug** in
the seven implemented mission paths. Technology routing, mission class routing, modifier ordering, fuel
ordering, double-application checks and legacy-bypass checks all passed. The six-function dead legacy cluster
was retired on 2026-09-19 after dependency, function-body and frontend consumer checks found no remaining callers.
The remaining items above are browser certification or bounded architecture decisions, not an unresolved gameplay defect.


## 16. Tests

```text
supabase/tests/fleet_speed_classes.sql        transactional (BEGIN … ROLLBACK) · 23/23 PASS live 2026-09-23
                                              (re-run after ACS_HOLD Fase A: assertions 1–10c incl. 10b/10c, zero residue)
supabase/tests/fleet_acs_hold_lifecycle.sql   transactional (BEGIN … ROLLBACK) · ACS_HOLD Fase A (pending LIVE run)
```

Covers: single class authority · class matrix incl. HOLDING and the legacy fallback · invalid-class exception
· 4/4 dispatch wiring · no parallel travel formula (`35000` appears only twice) · expedition hold resolves the
class · technology routing single authority · fuel reduction applied once without hyperspace · legacy cluster verified consumer-free before retirement · ACS/HOLDING not dispatchable while `holding_fleet_speed` is ready. The failure
message lists the failing assertions, so a run without notice output is still self-diagnosing.

**Execution status (2026-09-20): BLOCKED — requires a runtime transactional test.** Both suites run
`INSERT`/`UPDATE`/`DELETE` inside `BEGIN … ROLLBACK`, so they cannot be executed under a read-only
introspection window. They were **not** run and are **not** recorded as PASS. Their previous PASS records
(2026-09-18) remain the last executed evidence.

Their **structural** assertions were independently re-derived read-only against LIVE on 2026-09-20 by
stripping SQL comments from `pg_get_functiondef` (the same technique the suite uses) and counting matches:

```text
single class authority            functions other than the classifier reading
                                  peaceful_fleet_speed | war_fleet_speed | holding_fleet_speed  -> 0   PASS
no parallel travel formula        functions containing 35000                                  -> 2   PASS
                                  (calculate_fleet_travel_time, calculate_player_fleet_fuel_for_distance)
single technology authority       functions reading combustion_drive | impulse_drive |
                                  hyperspace_drive                                            -> 2   PASS
                                  (calculate_player_ship_speed, calculate_player_ship_fuel_consumption)
bare universes.fleet_speed read   functions reading the legacy column                          -> 2   PASS
                                  (the classifier itself + calculate_universe_rates only)
expedition_speed column readers   the universes.expedition_speed column                        -> 1   PASS
                                  (calculate_universe_rates only; not a dispatch path)
classifier callers                start_fleet, start_fleet_mixed, start_colonize_fleet,
                                  start_support_fleet, calculate_expedition_delay_seconds,
                                  the classifier itself                                        -> 6   INFO
```

The **discriminating** part of the class matrix (assertion 2) needs a probe universe whose four speed
columns differ, which requires `INSERT` → **BLOCKED**. Its mapping was therefore verified structurally from
the classifier body, not at runtime.

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
5. **Finding — local convergence is bounded**: the new local migration removes the demonstrated
   `universes.fleet_speed` class bypass from the two standard dispatchers and routes colonization ship speed
   through `calculate_player_ship_speed`; the exact LIVE dispatcher payload remains unverified. The §10
   claim and `fleet_speed_classes.sql` assertion 4 must still be re-verified against LIVE before parity is
   trusted. Fase A does not depend on it: `start_support_fleet` resolves its own class explicitly.
6. **Pending verification**: `fleet_acs_hold_lifecycle.sql` and the updated `fleet_speed_classes.sql` must be
   executed in LIVE (SQL Editor / `execute_sql`). This environment had no database credentials and no local
   Postgres/Docker, so the SQL was validated structurally (balanced blocks, canonical-helper-only bodies) but not
   executed here.

### 22.8 Descubrimiento de autorizaciones — cerrado 2026-09-26

Fase de cierre del hueco funcional que quedaba en ACS_HOLD. **El motor no se tocó**: `start_support_fleet`, la
política de autorización, `grant_planet_support_authorization`, `revoke_planet_support_authorization`, la tabla y la
vida del movimiento siguen exactamente como estaban certificados.

**Hueco demostrado LIVE** (antes de cambiar nada):

```text
planet_support_authorizations   RLS con `deny_direct_api_access` + sólo MAINTAIN para authenticated/anon
                                → `permission denied for table planet_support_authorizations`
players                         RLS (`player_type = 'AI' OR user_id = auth.uid()`) → un humano no ve a otro humano
                                ni por id ni por nombre (0 filas en ambos casos)
get_universe_ranking*           no expone a otros humanos (100 filas devueltas, el jugador ajeno ausente)
contrato de lectura             NO existía (`get_player_support_authorizations()` no existía)
```

Consecuencia: conceder y enviar funcionaban, pero **ningún lado podía descubrir la autorización que le afecta**.

**Lo que NO era un hueco** (y por eso no se creó ningún directorio): `planets.player_id` es público, así que el
propietario identifica al invitado por **coordenadas** (la galaxia ya las publica) y el contrato de concesión valida
el resto. No se añadió ninguna API de búsqueda de jugadores.

**Contrato añadido** — `20260926214030_add_support_authorization_read_contract.sql`:

```text
get_player_support_authorizations()
  SECURITY DEFINER · STABLE · search_path fijo · propiedad `players.user_id = auth.uid()`
  devuelve SÓLO las autorizaciones NO revocadas en las que el llamante es owner o guest, con
  dirección (GRANTED/RECEIVED), planeta destino (datos públicos), nombre del contraparte, fechas e `is_usable`
  (mismo predicado que el despachador: revocada o caducada → no utilizable)
  ACL: authenticated + service_role; NUNCA anon/PUBLIC · no se tocó ninguna ACL de tabla ni RLS
  la autoridad sigue siendo `start_support_fleet`, que revalida la autorización al enviar
```

**Evidencia LIVE del flujo completo** (rol `authenticated`, transaccional con ROLLBACK, residuo 0):

```text
concesión (propietario humano real, alta por provision_player)     grant_planet_support_authorization → autorización creada
pareja ajena (mismo planeta, otro invitado)                        creada y NO visible para el tercero
descubrimiento del invitado                                        filas=1 · dirección=RECEIVED
contenido expuesto                                                 destino [g:s:p] (PLANET) · propietario=AllyHuman ·
                                                                   invitado=DevPlayer · usable=t
concesión/petición ajena                                           PLANET_NOT_OWNED_BY_PLAYER ·
                                                                   «Player does not belong to authenticated user»
revoke sobre pareja ajena                                          devuelve false, 0 filas afectadas, fila intacta
                                                                   (el contrato filtra por owner_player_id)
acceso anónimo                                                     permission denied for function get_player_support_authorizations
despacho con autorización válida                                   start_support_fleet → ACS_HOLD / OUTBOUND · holding_until persistido
idempotencia                                                       misma clave → misma flota, idempotent_replay=t
ciclo de vida (worker certificado)                                 OUTBOUND → HOLDING → RETURNING (returns_at calculado)
revocación por el propietario                                      descubrimiento=0 filas · despacho → SUPPORT_AUTHORIZATION_REQUIRED
autorización caducada                                              visible con is_usable=f · despacho → SUPPORT_AUTHORIZATION_REQUIRED
```

**Superficie** (mínima, sin pantalla nueva): `src/SupportAuthorizationPanel.tsx` (conceder por coordenadas, listar
RECIBIDAS/CONCEDIDAS, retirar) montado en la vista FLOTA, y un selector de **autorizaciones recibidas** dentro de la
misión `APOYO ACS` de `FleetCommandPanel` que rellena el destino. El panel no decide nada: muestra las respuestas y
los rechazos del servidor.

**Diferencia con OGameX (deliberada, sin cambios)**: OGameX restringe ACS a *buddies*/miembros de alianza
(`FleetUnionService` + `FleetUnion`/`FleetUnionInvite`). LGI no tiene tablas de alianza/buddy, así que mantiene la
autorización explícita y revocable por planeta, y el descubrimiento es por tanto un listado de autorizaciones, no un
directorio de jugadores ni una lista de uniones.

**Limitación del entorno**: el universo LIVE tiene un único humano, así que la certificación creó un segundo humano
**dentro de la transacción** (`auth.users` + `provision_player`, revertido al final) para poder ejercer las dos
posiciones del flujo; las reglas probadas son las mismas para cualquier par de humanos.


## 23. Mission Modifiers closure — LIVE verification, 2026-09-20

Directed read-only sweep of the fleet mission-modifier surface against LIVE project `evtfsbntvuqmahiskekd`.
Method: `pg_get_functiondef` / `pg_proc` / `pg_constraint` introspection only. No DML, no fixtures, no writes.
This record closes §15.2 decision 3 partially, §22.7 item 5, and the "3 dispatch RPCs" wording in §5 and §9.

### 23.1 Mission → modifier matrix (extracted from LIVE, not invented)

| Mission | Speed class column | Universe multiplier | Evolution | Tech | Lifeform | Item | Special formula |
|---|---|---|---|---|---|---|---|
| TRANSPORT | `peaceful_fleet_speed` | yes | E^(1/3) | `calculate_player_ship_speed` | `fleet_speed_percent` | `fleet_speed_percent` | — |
| DEPLOY | `peaceful_fleet_speed` | yes | E^(1/3) | same | same | same | — |
| COLONIZE | `peaceful_fleet_speed` | yes | E^(1/3) | same (`colony_ship`) | same | same | own dispatcher + colony-ship requirement |
| EXPEDITION | `peaceful_fleet_speed` | yes | E^(1/3) | same | same **+ `expedition_speed_percent`** | same | expedition geometry helper for distance; delay event scales by the same class |
| ATTACK | `war_fleet_speed` | yes | E^(1/3) | same | `fleet_speed_percent` | `fleet_speed_percent` | — |
| ESPIONAGE | `war_fleet_speed` | yes | E^(1/3) | same | same | same | — |
| RECYCLE | `war_fleet_speed` | yes | E^(1/3) | same | same | same | recycler-only composition rule (frontend + RPC) |
| ACS_HOLD | `holding_fleet_speed` | yes | E^(1/3) | same (slowest ship) | same | same | `holding_until` window; idempotency key |
| HOLDING | `holding_fleet_speed` | yes | E^(1/3) | — | — | — | **not dispatchable**: lifecycle state only |
| DEFEND | `holding_fleet_speed` | yes | E^(1/3) | — | — | — | **not dispatchable**: `COMBAT_SUPPORT_NOT_READY` |

`RECYCLE_ATTACK` and `HARVEST` also resolve to WAR inside the classifier; they are not in the
`fleet_movements.mission_type` CHECK list, so they cannot be persisted as movements.

### 23.2 What was proven, and how

```text
single class authority       only calculate_mission_fleet_speed_multiplier reads the three class columns
                             (comments stripped, whole public schema, violators = 0)
EXPEDITION is NOT a bypass   start_fleet / start_fleet_mixed never read universes.expedition_speed; they
                             classify EXPEDITION as PEACEFUL and add expedition_speed_percent once
expedition_speed column      consumed only by calculate_universe_rates (rate projector, no dispatch path)
no parallel travel formula   35000 appears in exactly 2 bodies (travel time + fuel re-derivation)
single tech authority        drives read by exactly 2 bodies (ship speed + engine consumption)
                            -> a technology influences speed once and consumption once; never again
fuel ordering                fuel_reduction_percent applied exactly once, in
                            calculate_player_fleet_fuel_for_distance, clamped 0..30; hyperspace_technology
                            never acts as a generic fuel reduction
no double modifiers          per-body counts: fleet_speed_percent = 2 (item source + lifeform source,
                            summed once), expedition_speed_percent <= 1 and EXPEDITION-gated,
                            classifier calls = 1 per dispatch
worker has no speed math     process_fleet_movements: zero references to the classifier, travel time,
                            ship speed, fleet rate or fuel -> it only routes persisted state
legacy cluster is gone       calculate_fleet_time, calculate_fleet_fuel, calculate_fleet_fuel_mixed,
                            calculate_fleet_fuel_for_distance, calculate_expedition_time and
                            get_player_fleet_speed_multiplier return zero rows from pg_proc
expedition delay is canonical calculate_expedition_delay_seconds resolves EXPEDITION through the classifier
                            and reads E^(1/3) as calculate_universe_scaling(E).fleet_movement_scale, defined
                            as power(E, 1.0/3.0) -> numerically identical to the dispatchers' inline form
```


### 23.3 Findings recorded by this sweep

1. **No functional bug found** in the seven implemented missions plus ACS_HOLD. Class routing, technology
   routing, modifier ordering, fuel ordering, double-application and bypass checks all pass.
2. **`20260920010000_converge_local_fleet_dispatch_classifiers.sql` can never be applied** (§15.2 item 8).
   All six of its patch targets are absent from LIVE and the three dispatchers are already canonical, so it
   raises on its first target. Report-only; the artifact was not modified.
3. **Documentation precision**: §5/§9 said "3 dispatch RPCs"; ACS Fase A added a fourth
   (`start_support_fleet`), which applies the same pipeline with `holding_fleet_speed`. Corrected.
4. **`universes.lifeform_speed` is not a fleet class** (§15.2 item 6): it drives lifeform build/research
   times and the rate snapshot only.
5. **Four identical inline copies of the modifier sum** exist (one per dispatcher) — the same expression
   with only whitespace differences, i.e. duplication **without divergence**. Classified as maintainability
   risk, not a defect. Not refactored (no demonstrated bug; a shared helper would be a contract change).
6. **`solar_satellite`** (`speed = 0`, `fuel_consumption = 0`) has no propulsion routing and falls to the
   `else v_speed := v_base` branch, yielding `0`; dispatching it would raise
   `'Ship speed must be greater than zero'` from `calculate_fleet_travel_time`. Legitimate stationary-unit
   special case, not a gap — recorded so it is not mistaken for one.
7. **Frontend reach — CORRECTED 2026-09-26 (GAP B closeout).** This item originally reported that
   `start_colonize_fleet` and `start_support_fleet` had **no frontend caller** and that the browser selector exposed
   six missions only. That is no longer the case: `src/FleetCommandPanel.tsx` (FLOTA view) renders every deployed
   body — TRANSPORT · DEPLOY · COLONIZE · EXPEDITION · ATTACK · ESPIONAGE · RECYCLE · ACS_HOLD · MOON_DESTRUCTION —
   with an origin selector (planets **and** moons), ship loading, `load_fleet_cargo`, `recall_fleet`,
   `get_player_fleet_slots`, `get_player_expedition_slot_status` and `check_colony_cap`; `DEFEND` and `HOLDING` are
   listed as deliberately non-dispatchable. `RECYCLE` and `EXPEDITION` intentionally pass a NULL
   `destination_planet_id`: their backend dispatchers resolve the debris field or expedition coordinate from the
   mission type, and the frontend preserves that contract instead of rejecting both missions before the RPC call.
   OPEN PRODUCT DECISION recorded with this correction: with an identical fixture (shipyard 4 + impulse_drive 3 +
   colony_ship) `start_colonize_fleet` is **accepted from a moon** — the dispatcher validates coordinates, origin
   ownership + not destroyed, target occupancy, the colony cap, the colony ship, its prerequisites and the fuel, but
   **not the origin kind**, and the origin selector offers moons. Classic OGame forbids colonising from a moon.
   Measured LIVE 2026-09-26 (control from a planet accepted, moon origin accepted). Nothing was restricted.

   **Fleet-slot + cargo surface — 2026-09-26 (GAMEPLAY COMPLETION PASS).** The launch button now derives its
   enabled/disabled state exclusively from server contract values instead of only from `dispatchable`:
   `get_player_fleet_slots().out_slots_available <= 0` → `FLEET_SLOTS_FULL` (measured LIVE: `FLEET_SLOTS_FULL: 1/1`
   for EXPEDITION and for TRANSPORT — the guard is a BEFORE INSERT trigger on `fleet_movements`, so it covers every
   dispatch path); `get_player_expedition_slot_status().available_slots <= 0` → `EXPEDITION_SLOTS_FULL` (the status
   contract computes `used_slots` with `get_active_expedition_count` and `total_slots` with
   `get_player_expedition_slots`, i.e. the very predicate the dispatchers compare, verified LIVE); and
   `check_colony_cap().allowed = false` → `COLONY_CAP_REACHED`. If a contract has not loaded, nothing is blocked and
   the server decides. The cargo block now also shows the origin body's available resources (owner RLS read of
   `planet_resources`), the selection's advisory base capacity and the requested cargo; `load_fleet_cargo` remains
   the only authority that embeds the load.
8. **`calculate_fleet_travel_time` carries PUBLIC EXECUTE** (`=X/postgres` + anon + authenticated) while
   being the canonical travel-time authority. It is a pure `IMMUTABLE` formula, non-`SECURITY DEFINER`, so it
   leaks no data — noted against the "internal helper" convention of §4.
   `calculate_mission_fleet_speed_multiplier` itself is correctly restricted to `postgres`/`service_role`.

### 23.4 Status of this block

```text
Mission Modifiers / Technology / Lifeform / Item / Fuel ordering  -> CLOSED (no bug), re-verified LIVE
EXPEDITION routing                                                 -> CLOSED (canonical, with its justified
                                                                      expedition-specific modifier)
ACS_HOLD dispatch + lifecycle                                      -> CLOSED (Fase A, LIVE verified)
DEFEND                                                             -> OPEN — BLOCKED BY COMBAT ENGINE
HOLDING gameplay                                                   -> OPEN — internal state, by design
Browser fleet certification                                        -> OPEN
Holding fuel + maximum holding duration                            -> OPEN — product decisions
20260920010000 executable-or-not                                   -> OPEN — report-only finding (§15.2.8)
```

### 23.5 Distinction kept explicit

`HOLDING` and `DEFEND` have a speed class assigned (`holding_fleet_speed`) and are refused by the only
dispatcher that could create them. Having the class defined is **not** the same as having the gameplay
implemented: no HOLDING or DEFEND movement can currently be created, and no ACS combination, combat
integration, holding-fuel tick or UI exists. This block is **not** marked CLOSED on the strength of the
lifecycle contract alone.

## 24. Fleet cargo loading (bodega de flota) — implemented 2026-09-25

Contract: `public.load_fleet_cargo(p_fleet_id uuid, p_metal numeric, p_crystal numeric, p_deuterium numeric)`
(SECURITY DEFINER, one signature, unchanged result shape:
`fleet_id, metal, crystal, deuterium, total_cargo, cargo_capacity`). Applied LIVE as the server-versioned
migration `20260925154234_expose_fleet_cargo_loading_to_owner` (forward-only, no schema change).

Model (LGI custom, deliberate): loading is POST-DISPATCH while the fleet is `OUTBOUND`. OGameX instead
validates the resources at dispatch time (`GameMission::start` → `startMissionSanityChecks` →
`deductResourcesAndUnitsAtomic`, capacity from `UnitCollection::getTotalCargoCapacity`) and carries them with
the mission. The observable outcome is the same (the resources travel with the fleet, limited by total
capacity and by planet availability), so LGI keeps its own loader instead of changing the certified
dispatch RPCs.

Authority (all server-side; the frontend is never authoritative):
1. `auth.uid()` mandatory → `Authentication required`.
2. The fleet's player must belong to that user → `Fleet does not belong to authenticated user`.
3. The fleet's origin planet must belong to the same player → `CARGO_ORIGIN_NOT_OWNED`.
4. Status must be `OUTBOUND` → `Cargo can only be loaded while fleet is OUTBOUND`.
5. Mission whitelist `TRANSPORT | ESPIONAGE | ACS_HOLD | DEPLOY | COLONIZE | EXPEDITION` → otherwise
   `CARGO_MISSION_NOT_SUPPORTED`. The three extra missions were admitted in migration
   `20260925171816` **after** their handlers learned to deliver/preserve the cargo (see §25):
   `DEPLOY` delivers it to the destination planet, `COLONIZE` seeds the new colony with it and
   `EXPEDITION` adds the find to it instead of overwriting it.
6. Capacity from `calculate_fleet_cargo_capacity` (per-ship `cargo_capacity` + hyperspace 5%/level) →
   `Cargo exceeds fleet capacity: X / Y`; availability from `planet_resources` → `Insufficient <resource>`.

Atomicity: one transaction, `FOR UPDATE` on the fleet row and on the origin planet's resources; the planet
debit and the fleet credit are additive, so repeated calls add exactly what was requested (never a
duplicate) and no rejected call mutates anything.

Mission compatibility (derived from the arrival/return handlers, now complete — see §25):
- `TRANSPORT` — delivered to the destination planet (`resolve_transport_arrival`).
- `DEPLOY` — delivered to the destination planet, then the fleet completes unloaded
  (`resolve_deploy_arrival`, migration `20260925171816`).
- `COLONIZE` — seeds the newly created colony with the cargo (`resolve_colonize_arrival`, same
  migration; the destination-occupied path returns the fleet so the cargo travels home instead).
- `EXPEDITION` — the RESOURCES outcome ADDS the find to the cargo (`resolve_expedition_arrival`); every
  other outcome leaves the cargo untouched and `resolve_expedition_return` credits it at the origin.
- `ESPIONAGE`, `ACS_HOLD` — the return leg credits the cargo back to the origin
  (`process_fleet_movements` RETURNING loop). Latent note: if ACS grouping ever draws a holding fleet into
  a battle, the cargo-on-holding-fleet rule must be ratified in the combat domain.
- Still NOT whitelisted: `RECYCLE` (its worker intentionally SETs the cargo to the harvested debris) and
  `ATTACK` (LGI cargo is not part of the battle model: the certified PG-09 loot capacity ignores
  pre-loaded cargo, while OGameX caps the return with surviving capacity → combat-domain product decision).

Client: the `src/App.tsx` fleet view shows METAL / CRISTAL / DEUTERIO inputs only for the eligible missions
(TRANSPORT, ESPIONAGE), calls `load_fleet_cargo` with the fleet id returned by `start_fleet_mixed`, and
displays the capacity the SERVER returns (no capacity formula is duplicated in the client).

Tests: `supabase/tests/fleet_cargo_loading.sql` — **18/18 PASS LIVE 2026-09-25** inside its rollback
transaction, zero residue: ACL surface (authenticated only; `anon` revoked; `service_role` preserved),
unauthenticated / foreign-fleet / foreign-origin / non-OUTBOUND / non-whitelisted / negative rejections with
no mutation, valid multi-resource load, exact per-resource debit, insufficient resources, ESPIONAGE cargo,
exact-capacity load, overflow rejection, additive repeated calls and the end-to-end conservation invariant.
LIMITATION: the suite is single-session, so true concurrent loading is not executed (the `FOR UPDATE` locks
and the capacity check are asserted on the sequential path).

## 25. Cargo lifecycle completion — DEPLOY / COLONIZE / EXPEDITION (2026-09-25)

Migrations (forward-only, LIVE applied, no schema change): `20260925171816` (handler fixes + whitelist),
`20260925172115` and `20260925172311` (the two latent-defect fixes below).

What changed (before → after):
- `resolve_deploy_arrival`: ships only, then `COMPLETED` with the cargo still on the row (stranded) → the
  destination economy is settled through the arrival event and credited with the carried cargo before the
  ships are transferred; the fleet then completes with `metal/crystal/deuterium = 0`. OGameX reference:
  `DeploymentMission:83-85` (`addResources` on arrival).
- `resolve_colonize_arrival`: the colony was created with `planet_resources = 0/0/0` (cargo lost) → the new
  colony is seeded with the carried cargo and the fleet completes unloaded. OGameX reference:
  `ColonisationMission:125-126`.
- `resolve_expedition_arrival` (outcome `RESOURCES`): `SET metal=<find>, crystal=…, deuterium=…` (destroyed
  any carried cargo and forced the other two resources to 0) → additive
  `metal=COALESCE(metal,0)+<find>, …`. The `expedition_results` row still records ONLY the find, so the
  report, the reward tier and the weight accounting are unchanged. OGameX reference:
  `ExpeditionMission:218-220` (`mission->metal + returnResources->metal`).
- `load_fleet_cargo` mission whitelist widened to those three missions (their handlers now preserve the
  cargo). `RECYCLE` and `ATTACK` stay excluded (§24).

Two PRE-EXISTING latent defects found and fixed (both blocked paths this mission had to verify):
1. `resolve_colonize_arrival` — `DELETE FROM fleet_movement_ships WHERE fleet_id=p_fleet_id` raised
   `42702 column reference "fleet_id" is ambiguous`, because the function returns `TABLE(fleet_id, …)` so
   `fleet_id` is also an OUT variable. Consequence: a colonisation arrival could never complete (LIVE had
   0 planets named `Colony %` and 0 `COLONIZE` movements). Fixed in `20260925172115` by qualifying the
   column (`fms.fleet_id`).
2. `prepare_expedition_resource_reward` — `UPDATE expedition_reward_budgets … WHERE fleet_id=p_fleet_id`
   raised the same `42702` (identical OUT-variable collision). Consequence: the `EXPEDITION → RESOURCES`
   outcome could never resolve. Fixed in `20260925172311`. Detected systematically: of every public function
   whose body contains an unqualified `fleet_id = …` reference, only this one also declares `fleet_id` as an
   OUT parameter; the other occurrences resolve to the column and were deliberately left untouched.

Idempotency and retries (verified, not assumed):
- DEPLOY / COLONIZE keep their `ARRIVED → COMPLETED` state guard, so a replay raises and never credits twice.
- EXPEDITION's `expedition_results` early return only protects a replay that still sees `ARRIVED`; after a
  successful resolution the fleet is `RETURNING`, so a replay is rejected by the state guard instead. Both
  paths prevent double-crediting, and no partial state can survive because every resolver is one transaction.

Tests: `supabase/tests/fleet_cargo_lifecycle.sql` — **17/17 PASS LIVE 2026-09-25** (+3 INFO rows) inside its
rollback transaction, zero residue (fleet tables empty, no colony left behind, `expedition_settings` back to
its original single row, `planet_ships` / `planet_buildings` unchanged): `DEPLOY` exact delivery + unload +
replay + zero-cargo (5), `COLONIZE` planet creation + exact seed + colony-ship consumption + unload + replay
+ zero-cargo (6), `EXPEDITION` deterministic RESOURCES selection + preserved cargo & added find +
report-records-only-the-find + replay rejection + zero-cargo find (5), and the whitelist functional + static
checks (2).
Technique note: the RESOURCES outcome is deterministic per fleet id, so the fixture probes candidate fleets
(`expedition_event_random(id,'outcome') × Σ weights → select_expedition_outcome`) instead of modifying any
game setting to force it.
LIMITATION: single-session harness — true concurrency is not executed; idempotency is covered by replays and
the `FOR UPDATE` locks are asserted from the deployed bodies.

Data finding (out of scope, OPEN): the universe of the human player (`cf021ece-…`) has **no**
`expedition_settings` row, so `resolve_expedition_arrival` raises `Invalid expedition weights for universe`
there and expeditions cannot resolve in that universe at all. The fixture creates a rollback-only copy of the
configured weights to exercise the code; choosing the real weights for a universe is a configuration
decision, so nothing was changed.

**CLOSED 2026-09-25** — see §26: the row was replicated into the active universe from the project's own
configured weights (same values, provenance in migration `20260925202506`) and the real resolution is now
certified.

## 26. Expeditions end-to-end — configuration, items, slots, read contracts and UI (2026-09-25)

Migrations (forward-only, LIVE applied, no schema change): `20260925202506` (config + item activation + slots +
read contracts) and `20260925202529` (ACL hygiene for the internal slots helper).

**Configuration.** The ACTIVE universe (`cf021ece-…`) had no `expedition_settings` row, so
`resolve_expedition_arrival` raised `Invalid expedition weights for universe` and **no expedition could resolve
in the real universe** (the only configuration lived in the inactive `TEST - Universe 1`). The block
replicated the weights the project itself had configured — provenance: `20260912092811` (seed),
`20260912105222_restore_expedition_weights_after_timing_audit` (explicit restore) plus the DM / merchant /
items migrations — into the active universe **without changing any value**; the weights remain product-tunable
data. `expedition_resource_caps`, `expedition_ship_tiers` and `expedition_item_definitions` are global (no
`universe_id`), so this row was the only missing per-universe configuration.

**Items.** The activation logic already existed (consume the stack, create the `expedition_item_uses` row with
`effect_snapshot = {effect_key, effect_value, expires_at, item_name, category}`), but `use_expedition_item` had
**no ownership gate and no client grant**, so `get_active_expedition_item_effect` (which reads only
`expedition_item_uses`) always returned 0: every item effect was inert while items accumulated. Now the
function requires `auth.uid()` → `players.user_id` → the player, validates the optional planet ownership, keeps
`FOR UPDATE` on the stack, and EXECUTE is granted to `authenticated` only (`anon` revoked).

**Effects** (all pre-existing definitions — nothing invented): `production_percent`, `storage_percent`,
`research_speed_percent`, `expedition_slots`, `fleet_speed_percent`, `building_speed_percent` and
`expedition_reward_percent`, each expiring by `expires_at` from `expedition_item_definitions.duration_seconds`.

**Slots.** `get_player_expedition_slots` = `1 + expedition_settings.bonus_expedition_slots + objetos activos`;
the internal helper is now closed to client roles (it carried a PUBLIC grant before) and the client uses
`get_player_expedition_slot_status()`.

**Read contracts for the client** (every expedition table carries `deny_direct_api_access`, so the browser
could not read results or items): `get_player_expedition_reports(p_limit)`,
`get_player_expedition_item_status()` and `get_player_expedition_slot_status()` — SECURITY DEFINER,
owner-scoped through `with me as (select pl.id … where pl.user_id = auth.uid())` (same pattern as
`get_player_battle_reports`), EXECUTE only for `authenticated`/`service_role`.

**UI** (`src/App.tsx`). The Expeditions view shows the slot breakdown (base / universe settings / items / total
/ used / available), the owned items with a working ACTIVAR button and the active effects with remaining time;
the Messages view consumes `get_player_expedition_reports` and distinguishes resources, ships, dark matter,
items, merchant, combat (pirates/aliens), losses, delay and speed-up. The three new RPCs are invoked through a
small typed cast (`rpcUntyped`) because `src/lib/database.types.ts` has not been regenerated yet (same
precedent as `lib/identity.ts`).

**Tests.** `supabase/tests/expedition_items_and_slots.sql` — **22/22 PASS + 1 INFO, LIVE 2026-09-25**, rollback,
zero residue: active-universe configuration, real end-to-end resolution, slot base/bonus/expiry, activation and
consumption, the six effects verified against their consumers, effect expiry, security (cross-player,
unauthenticated, unknown item, foreign planet), state untouched after every rejection, the item reward path and
replay without double award. Regression: `fleet_cargo_lifecycle.sql` **18/18 PASS** (now reporting the active
universe as configured) and `research_building_prerequisites.sql` **21/21 PASS**. LIMITATION: single-session
harness (no true concurrency; the RNG lottery is resolved with the deterministic per-fleet probe).

## 27. Transversal Fleet Engine audit — modifier matrix, helper ACL, ACS/recall (2026-09-25)

Single block covering dispatch · mission modifiers · speed · fuel · travel time · cargo · arrival · return ·
recall · ACS_HOLD/support · mission-affecting technologies · **real consumers**. Migrations (forward-only,
applied LIVE, **no schema change, no formula change**):
`20260925211615_tighten_fleet_calculation_helper_acl` and
`20260925211804_tighten_fleet_distance_helper_acl`.
Regression: new `supabase/tests/fleet_helper_acl_and_holding_cargo.sql` **18/18 PASS + 1 INFO**, plus the
certified `fleet_speed_classes.sql` re-run **23/23 PASS** — both LIVE, rollback, zero residue.

### 27.1 Mission modifier × consumer matrix (read from the deployed bodies)

| Mission | Speed source | Fuel | Travel time | Cargo | Modifiers | Consumer |
|---|---|---|---|---|---|---|
| TRANSPORT | slowest ship via `calculate_player_ship_speed` | `calculate_player_fleet_fuel_for_distance` (outbound time) | `calculate_fleet_travel_time` | delivered to destination, movement zeroed | peaceful class · `E^(1/3)` · item/lifeform `fleet_speed_percent` | `resolve_transport_arrival` + worker |
| DEPLOY | idem | idem | idem | delivered to destination, movement zeroed | idem | `resolve_deploy_arrival` (COMPLETED, `returns_at = NULL`) |
| COLONIZE | `colony_ship` via the same helper | idem (`start_colonize_fleet`) | idem | seeds the new colony, movement zeroed | idem | `resolve_colonize_arrival` (occupied target → cargo preserved home) |
| EXPEDITION | slowest ship | idem | idem (+ hold/delay §12) | additive: prior cargo **+** find | peaceful · `expedition_speed_percent` (lifeform) added once | `resolve_expedition_arrival` / `resolve_expedition_return` |
| ATTACK | slowest ship | idem | idem | **not loadable** (PG-09/PG-10 open) | war class | `resolve_attack_arrival` (untouched here) |
| ESPIONAGE | `espionage_probe` | idem | idem | carried cargo returns home untouched | war class · `espionage_technology` read only in the report | `resolve_espionage_arrival` |
| RECYCLE | `recycler` | idem | idem | **overwritten** by the debris find (`deuterium = 0`) | war class | `collect_debris` inside the worker |
| ACS_HOLD | slowest ship | idem | idem (`holding_fleet_speed`) | kept through HOLDING, returned to the **origin** | holding class · item/lifeform `fleet_speed_percent` | `start_support_fleet` + worker HOLDING loop |
| HOLDING | — (state) | — | — | idem | — | worker `HOLDING → RETURNING` |
| DEFEND | — | — | — | — | — | refused by every dispatcher (`COMBAT_SUPPORT_NOT_READY`) |

Audited invariants (each re-confirmed on the deployed `prosrc`, not on this document):

```text
single travel-time implementation ............ only calculate_fleet_travel_time carries 35000 (with the fuel helper): 2/2
single fuel ordering ......................... fuel_reduction_percent applied exactly once, hyperspace never a generic reduction
single mission→class authority ............... calculate_mission_fleet_speed_multiplier; no other function reads the three class columns
single propulsion routing .................... only calculate_player_ship_speed / _fuel_consumption read combustion/impulse/hyperspace
no dispatcher bypass ......................... no .speed read in start_fleet / _mixed / _colonize / _support
legacy column ................................ universes.fleet_speed is read ONLY by calculate_universe_rates (informational snapshot)
cargo is never double-credited ............... every delivering resolver zeroes the movement cargo before the RETURNING settlement
expedition slots ............................. get_active_expedition_count filters mission_type = 'EXPEDITION' (ACS_HOLD never consumes a slot)
ACS_HOLD eligibility ......................... planet existence is never authorization (planet_support_authorizations, revocable + expirable)
```

### 27.2 What was actually wrong: three internal helpers were still client-reachable

A per-entry ACL probe (not a `LIKE` match — `postgres=X/postgres` also contains `=X/`) found that, of the
canonical cluster, exactly three functions still carried the default `PUBLIC`/`anon`/`authenticated` grant:

```text
calculate_fleet_distance(uuid,uuid)                       PUBLIC + anon + authenticated   -> CLOSED by 20260925211615
calculate_fleet_travel_time(numeric,numeric,numeric,numeric)  PUBLIC + anon + authenticated -> CLOSED by 20260925211615
calculate_fleet_distance_to_coordinates(uuid,int,int,int)     PUBLIC                        -> CLOSED by 20260925211804
```

All three are internal (§7 distance model, §5 travel-time authority). Safety evidence before closing, verified
LIVE: their only consumers are `start_fleet`, `start_fleet_mixed`, `start_colonize_fleet` and
`start_support_fleet` — SECURITY DEFINER and owned by `postgres`, so they keep EXECUTE — and `src/**` never
calls them (only the generated types mention two of them). This is the same treatment already given to
`calculate_mission_fleet_speed_multiplier` (20260919) and to the expedition slots helper (20260925). §23.3
item 8's report-only note about `calculate_fleet_travel_time` is therefore **closed**; the deliberate PUBLIC
grant on the informational `calculate_universe_rates` snapshot is **not** touched (it is item 3 below).

No gameplay value, ordering, signature or body was modified by this block.

### 27.3 Recall — audit result: MISSING, and blocked by two product decisions

Determined LIVE, exhaustively (not inferred from the docs):

```text
RPC / logic                  -> NONE. No recall_* / cancel_* function exists in public (only resolve_expedition_return,
                                which is the expedition return leg, not a player recall).
Lifecycle slot               -> fleet_movements.status admits 'CANCELLED', but nothing in the schema ever writes it
                                (it is the same unreachable value already recorded for the four queues).
Column/state                 -> no recalled_at / recall_requested_at; no partial index for a recall sweep.
Frontend                     -> CORRECTED 2026-09-26: the recall surface exists — `ActiveFleetsPanel` offers
                                `recall_fleet` for OUTBOUND/HOLDING movements and `FleetSlotsPanel` mirrors it; the
                                earlier "no recall surface in src/**" note predates the fleet UI block.
                                (The contract described in this section — `recall_fleet` — was implemented later;
                                see the recall closeout block.)
```

What a recall therefore still needs before it can be implemented **without inventing**:

1. **Fuel semantics — PRODUCT DECISION.** LGI already reserves a modifier for it
   (`recall_fuel_recovery_percent`) and it is a documented dead key (§9). OGame's classic rule does not refund
   fuel; whether LGI refunds part of it, nothing, or charges for the return leg is a balance decision, not a
   technical gap. Implementing either option silently would be inventing a mechanic.
2. **Return-leg duration for a partially-flown mission — PRODUCT DECISION.** Reusing the persisted outbound
   duration (the worker's rule for every return leg, §11) would make a recalled fleet arrive *later* than the
   target it never reached; OGame uses the elapsed time plus a turnaround. Both are defensible; the choice
   changes player-visible timing and must be decided.
3. **Recall of `ACS_HOLD`** (and of a fleet already in HOLDING) — whether a support fleet can be pulled back
   before `holding_until`, and whether the authorization is consumed, depends on the same decisions.
4. Cargo needs **no** new rule: a recalled fleet has not delivered anything, so its cargo simply returns home
   through the existing RETURNING settlement (§27.4). Ownership needs no new rule either: the recall RPC must
   reuse the established `auth.uid() → players.user_id → fleet.player_id` guard.

Recall is therefore recorded as **MISSING + PRODUCT DECISION** (already classified that way in
`README_OGAMEX_LGI_MAP` §F) and **not implemented** in this block. `CANCELLED` stays an unwritten value.

### 27.4 Cargo / ACS_HOLD integration — verified, not changed

The post-dispatch cargo contract (§24–§25) was **not** re-implemented. Only its integration with return,
HOLDING and the generic settlement was verified:

- `load_fleet_cargo` is owner-gated, requires `status = 'OUTBOUND'`, whitelists
  `TRANSPORT · ESPIONAGE · ACS_HOLD · DEPLOY · COLONIZE · EXPEDITION` (RECYCLE/ATTACK stay excluded because
  their handlers overwrite the cargo), and measures capacity through `calculate_fleet_cargo_capacity` →
  `calculate_player_ship_cargo_capacity` (no duplicated formula).
- **No double credit is possible.** Every delivering handler zeroes the movement cargo
  (`resolve_transport_arrival`, `resolve_deploy_arrival`, `resolve_colonize_arrival`), so the single generic
  RETURNING credit in `process_fleet_movements` (`pr.metal + fm.metal`) adds exactly 0 for them. Assertions
  B1–B5 prove it end to end (destination credited once, origin credited 0, ships restored once).
- **ACS_HOLD carries cargo correctly**: it survives OUTBOUND → HOLDING → RETURNING untouched and lands on the
  **origin** exactly once at COMPLETED, while the supported planet is never credited (assertions C1–C5).
  Holding fuel remains the product decision recorded in §13/§22 — no deuterium tick was invented.

### 27.5 Remaining OPEN (unchanged by this block)

1. **Recall** — MISSING, blocked by the two product decisions in §27.3.
2. `calculate_universe_rates` still builds its `fleet`/`expedition` columns from the legacy `universes.fleet_speed`
   and `expedition_speed`, and it keeps its deliberate PUBLIC grant. The columns are informational (no dispatch
   consumer); deciding their canonical meaning is item §15.2.3.
3. Dead lifeform keys: `civilian_ship_speed_percent` (no consumer) and `recall_fuel_recovery_percent`
   (reserved for the recall decision).
4. `20260920010000_converge_local_fleet_dispatch_classifiers.sql` still cannot execute (§15.2.8) — its end state
   is already LIVE; report-only, not modified.
5. Browser fleet certification and the ACS multi-attacker producer (combat engine) remain OPEN.
6. Holding fuel and the maximum holding duration remain PRODUCT DECISIONS.
7. Residual ACL note (reported, **not** changed — they belong to the closed expedition block): four
   expedition-selection helpers still carry PUBLIC/anon/authenticated EXECUTE —
   `calculate_expedition_speedup_seconds(uuid,numeric)`, `expedition_fleet_has_pathfinder(uuid)` and both
   `select_expedition_speedup_percentage` overloads. All are SECURITY **INVOKER** over tables carrying
   `deny_direct_api_access`, so a client role reads no rows (same accepted exception as
   `get_active_expedition_item_effect`), and `src/**` never calls them. Closing them is a separate,

## 30. Fleet slots — derivation contract (2026-09-26)

`computer_technology` was unlock-only and LGI had **no** fleet-slot sub-system (no column, no counter, no
reader). The map records the OGameX rule and lists the adoption of a cap as an open product question, so this
block implemented the **derivation** and deliberately left the **enforcement** out.

```text
calculate_player_max_fleet_slots(player)     = 1 + computer_technology level     (OGameX parity; LGI has no officers)
calculate_player_fleet_slots_in_use(player)  = count of the player's fleets whose status is
                                               NOT IN (COMPLETED, CANCELLED)
get_player_fleet_slots()                     = client read contract: one row per player owned by auth.uid()
                                               (player, computer level, max, in use, available never negative)
```

```text
ACL        the two calculators are postgres/service_role only; the read contract is authenticated/service_role.
           Never anon, and no parameter can select a player.
READ-ONLY  nothing is written; the fixture asserts fleet statuses are untouched.
EXEMPTIONS every LGI mission holds a slot (OGameX exempts missile attacks; LGI has no missile mission).
NOT DONE   the cap is NOT enforced in start_fleet / start_fleet_mixed / start_colonize_fleet or any other
           dispatcher: adopting it would change what existing players may do → PRODUCT DECISION. No certified
           dispatcher was modified by this block.
```

Tests: `supabase/tests/fleet_slots_derivation.sql` — **8 PASS + 1 INFO, LIVE 2026-09-26** (max = 1 + level, only
live missions count, client contract + identity, available never negative, read-only proof, no session → no row,
ACL). LIMITATION: single-session harness; no concurrency.

```text
GAPS             no UI and no dispatcher consumer (by design, see NOT DONE above).
PRODUCT DECISION whether to adopt the cap (map: «¿Se adopta el límite de flotas (computer_technology)?») and, if
                 adopted, which dispatchers are gated and whether an over-limit state is tolerated.
```

   expedition-scoped decision.

## 29. FLEET SLOTS ENFORCEMENT + FLEET RECALL (2026-09-26)

Both mechanics are LIVE and close the "PRODUCT DECISION" recorded above.

```text
ADOPTED PRODUCT RULE   maximum simultaneous fleets = 1 + computer_technology level, enforced SERVER-SIDE for every
                       mission that puts a fleet in flight. The UI is never the authority.

ENFORCEMENT  migration 20260926121000_fleet_slots_enforcement
  assert_player_fleet_slot_available(player)   internal helper (postgres/service_role only)
  enforce_fleet_slots_before_insert()          BEFORE INSERT trigger on fleet_movements (trg_enforce_fleet_slots)
  Rationale (no-regression): the certified dispatchers (`start_fleet`, `start_fleet_mixed`, `start_support_fleet`,
  `start_colonize_fleet`) are NOT modified; the rule cannot be bypassed by a future dispatcher or by a client
  (`fleet_movements` refuses direct API access); and a rejection is an exception inside the caller's transaction, so
  a refused dispatch writes no fuel, no ships and no movement.
  Slot accounting: a mission holds its slot for its whole duration; only COMPLETED / CANCELLED release it, so
  ACS_HOLD/HOLDING, expeditions, colonisation and returning fleets each occupy one slot.
  Idempotency preserved: an insert whose `idempotency_key` was already used by the same player is NOT blocked by the
  cap — it must reach the partial unique index so `start_support_fleet` can return the winner's durable movement.
  Client read contract: `get_player_fleet_slots()` (already existed) returns max / in-use / available for the caller.

RECALL  migration 20260926122000_fleet_recall_contract
  recall_fleet(p_player_id, p_fleet_id)  authenticated/service_role (never anon), SECURITY DEFINER
  Ownership    auth.uid() → players.user_id must own the fleet; a service-role call must state the owner and is
               still cross-checked against `fleet_movements.player_id`. A client `p_player_id` is never trusted.
  Timing       OUTBOUND → RETURNING with `returns_at = now + (now − started_at)`: the fleet turns around where it
               is, so the return leg lasts exactly as long as the time already flown (nothing is teleported).
               HOLDING → RETURNING with the FULL outbound duration (the fleet is at the destination).
               Refused with FLEET_RECALL_TOO_LATE once `arrives_at <= now`, and with FLEET_NOT_RECALLABLE in any
               other status, so a fleet can never be returned twice.
  Cargo        the recall writes only `status` and `returns_at`; `metal`/`crystal`/`deuterium` and
               `fleet_movement_ships` are preserved byte-for-byte and the worker's existing RETURNING branch
               delivers them to the origin planet.
  Lifecycle    the canonical RETURNING state is reused — no new status and no CANCELLED row, so the queue
               cancellation contract stays untouched.
  Notification the messaging engine produces "Fleet returning" for the fleet owner.

TESTS (LIVE 2026-09-26, rolled back, zero residue)
  supabase/tests/fleet_slots_enforcement.sql   6 PASS + 1 INFO
  supabase/tests/fleet_recall.sql              7 PASS + 1 INFO
  supabase/tests/fleet_slots_derivation.sql    unchanged assertions, still PASS (base level raised to 6)
  LIMITATION   single-session harnesses: real concurrency is not executed.

FIXTURE PREREQUISITE  fixtures that need several live movements for one player now grant a high
  `computer_technology` level right after `begin;` (they would otherwise be refused by the new cap). Files touched:
  combat_acs_settlement, combat_debris_idempotency, combat_defender_fleet_participant, combat_expedition_combat,
  combat_participant_identity_collision, combat_participant_propagation, combat_report_contract,
  combat_worker_isolation, expedition_items_and_slots, fleet_acs_hold_lifecycle, fleet_cargo_lifecycle,
  fleet_cargo_loading, fleet_helper_acl_and_holding_cargo, fleet_speed_classes,
  fleet_support_authorization_chain, owner_read_contracts.
  They were NOT re-executed in this session; their only new constraint is the slot cap, which the prerequisite
  removes.
```

UI: `src/GameplayEnginePanel.tsx` (`FleetSlotsPanel`) renders the slot counters from `get_player_fleet_slots` plus a
`RETIRAR FLOTA` button per OUTBOUND/HOLDING fleet calling `recall_fleet`. No authority lives in the UI: it shows the
contract's answer and the server's own error text (FLEET_SLOTS_FULL, FLEET_NOT_RECALLABLE).

GAPS (unchanged by this block)

```text
* No recall entry point in the galaxy launch flow (recall is offered from the fleet view).
* Holding has still no maximum duration and no fuel tick (pre-existing gaps).
* Recalling an AI-owned fleet needs a service-role call (AI players have no session).
```

## Dedicated moon destruction mission (2026-09-26)

`20260926190000_moon_destruction_mission.sql` adds the mission OGameX models as `MoonDestructionMission`:

* `mission_type = 'MOON_DESTRUCTION'` (CHECK extended, original values untouched) classified as a **WAR fleet**
  (`MoonDestructionMission::$fleetSpeedType = FleetSpeedType::war`); measured LIVE: identical travel time to an
  equivalent ATTACK.
* `start_moon_destruction(player, origin, destination, ships)` enforces the OGameX rules (at least one deathstar,
  destination = alive foreign moon) and delegates to the certified `start_fleet_mixed`, so there is a single
  dispatch authority (fuel, distance, fleet rows).
* `resolve_attack_arrival` and `resolve_combat` accept the mission (two ATTACK-only guards widened) and
  `process_fleet_movements` routes it to the same resolver. The destruction roll is **not duplicated**: the
  certified hook `settle_moon_destruction_for_battle` keeps applying the OGameX rules (chance
  `(100 - sqrt(diameter)) * sqrt(deathstars)`, deathstar-loss roll, ripple).
* Two latent certified defects were found and fixed on the way: `start_fleet_mixed` deducted ships with an
  ambiguous `ship_id` (collision with its own OUT parameter, so any mixed dispatch reaching that line failed)
  and `resolve_combat` carried a second ATTACK-only guard with a Spanish message.
* ACL: `authenticated` + `service_role` only (the AI service actor uses the certified contract).

Tests: `supabase/tests/moon_destruction_mission.sql` — **6 PASS + 1 INFO, LIVE 2026-09-26**: rejections
(no deathstar / planet target / own moon), dispatch to the target moon, war speed class with duration parity
against ATTACK, worker routing, full resolution (battle created, attempt row with the OGameX chance,
`destroyed = roll <= chance`, attacker RETURNING) and ACL. Transactional with ROLLBACK and zero residue.
LIMITATION: single-session harness; the global worker is asserted statically and the destruction roll is random.

## Colony cap by astrophysics (2026-09-26)

`20260926210000_colony_cap_astrophysics.sql` implements the OGameX `MAX_COLONIES` calculation
(`ResearchObjects.php`: `round($level / 2)`) with an explicit, balanced base:

```text
max PLANETS = 1 (homeworld) + max(1, round(astrophysics / 2))
```

So every player can always found one colony (playable from turn one) and Astrophysics is the growth lever:
astro 0 -> 2 slots, 4 -> 3, 8 -> 5, 10 -> 6, 20 -> 11. **Moons never count against the cap** and destroyed
planets never count. OGameX publishes the calculation without its base count, so the base is stated here
explicitly instead of guessed.

* `calculate_max_colony_slots(player)` — the cap; `check_colony_cap(player)` — the read contract
  (`allowed`, `reason`, `max_slots`, `current_planets`, `astrophysics_level`, reason `COLONY_CAP_REACHED`).
* Enforcement in **two** places, so the rule can not be bypassed by fleets already in flight:
  `start_colonize_fleet()` (dispatch gate, the OGameX `ColonyEstablishFailAstrophysics` outcome) and
  `resolve_colonize_arrival()` (authoritative creation gate, defensive).
* ACL: `authenticated` + `service_role` (the AI actor included); no anon bypass.

Tests: `supabase/tests/colony_cap.sql` — **7 PASS + 1 INFO, LIVE 2026-09-26**: the 2/3/6 curve at astro 0/4/10,
a single-planet player allowed, the moon excluded from the count while 2 planets hit the cap
(`COLONY_CAP_REACHED`), the dispatch refusal, astro 4 lifting the cap, ACL and the presence of the creation gate.
Transactional with ROLLBACK and zero residue. LIMITATION: single-session harness; the arrival gate is asserted
by source inspection (the defensive one).

## Wreck field + Space Dock (2026-09-26)

`20260926230000_wreck_field_space_dock.sql` closes the last approved sweep block. OGameX reference:
`WreckFieldService` (`loadOrCreateForCoordinates`, `canCreateWreckField`, `calculateShipsForWreckField`,
`extendWreckField`, `startRepairs`, `completeRepairs`, `burn`) plus its `CleanupWreckFields` scheduled command.

| State | Meaning |
|---|---|
| `ACTIVE` | the field holds recoverable ships; a new battle over the same coordinate **extends** it and refreshes the 72 h decay timer |
| `REPAIRING` | repairs started; `repair_finishes_at` = now + ceil(total / (5 * Space Dock level)) hours |
| `BLOCKED` | repairs asked for but the coordinate has no Space Dock (`blocked_reason = NO_SPACE_DOCK`) |

LGI decisions (explicit, because OGameX only ships the service and not the building curve):

* **Space Dock** (`space_dock`) is LGI-defined and balanced: 400 / 200 / 100, cost factor 2, time factor 2,
  max level 10, valid on **planets and moons**.
* recoverable share of the destroyed ships = `least(100, 20 + 8 * level) %` (level 0 -> 20 %, level 10 -> 100 %).
* repair rate = `5 * level` ships per hour; **repairs are free** (they only cost time), which is the OGS behaviour.
* decay: a field nobody repairs for 72 h is **burned** by the worker; a fresh battle refreshes the timer.
* the field pools the destroyed **ship** units of both sides at that coordinate; defences can never enter it
  (they are not rows of `ship_definitions`, so the join excludes them by construction).

### Contracts (ACL: `service_role` only)

```text
create_or_extend_wreck_field(planet_id, ships jsonb, space_dock_level default null) -> uuid
start_wreck_field_repairs(wreck_field_id)                      -> status/result/total/finishes_at
complete_wreck_field_repairs(wreck_field_id)                   -> result/ships_repaired
run_wreck_field_worker(limit)                                   -> per-field outcome (COMPLETED | DECAYED)
settle_wreck_field_for_battle(battle_id)                        -> uuid   (called by the battle hook)
```

**Producer:** the additive trigger `trg_on_combat_battle_finished_wreck_field` (AFTER UPDATE on
`combat_battles`, `old.finished_at is null and new.finished_at is not null`) - the same hook pattern already
used by the moon destruction settlement. No certified combat function is modified, and the trigger swallows
its own errors (`raise warning`) so a wreck-field problem can never break a battle settlement. The per-type
losses are read from the certified `combat_unit_state` snapshot of the final round
(`quantity - quantity_alive`), which also excludes defences naturally.

**Scheduling:** pg_cron `lagranimplosion-wreck-field-worker` every 10 minutes (`*/10 * * * *`).

Tests: `supabase/tests/wreck_field_space_dock.sql` - **9/9 PASS, LIVE 2026-09-26**, transactional (ROLLBACK,
zero residue): building definition, 20 % recovery at level 0, extension of an existing field, BLOCKED without
a Space Dock, REPAIRING at level 10 with the exact 6 h estimate for 300 ships at 50/h, completion returning
the ships to `planet_ships`, decay of an expired field by the worker, producer trigger + ACL + cron, and the
safe no-op path for an unknown battle.

Pending (declared, not part of this block): the client panel for the wreck field (the tables are ready to be
read directly from the UI, in the same way the other panels read their tables).

## P0 fixed 2026-09-26 — `start_fleet` OUT-parameter/column ambiguity (all single-ship dispatch)

Found by the integral Supabase↔frontend contract audit. The galaxy view's two dispatch buttons
(`ENVIAR FLOTA` for ATTACK/TRANSPORT/ESPIONAGE and `ENVIAR EXPEDICIÓN`, which sends `p_destination_planet_id = NULL`)
called a contract that **failed for every mission**:

```text
start_fleet(<player>, <planet>, <dest|null>, <ship>, <qty>, <mission>) -> ERROR 42702: column reference "ship_id" is ambiguous
start_fleet_mixed(...)                                                     -> OK   (already qualified)
```

Cause: `start_fleet` declares OUT parameters through `RETURNS TABLE (fleet_id, ship_id, quantity, …)` and its
ship-consumption statement referenced the `planet_ships` columns unqualified, so `ship_id`/`quantity` resolved
ambiguously between the OUT parameter and the column. Because `App.tsx` drives the main fleet view through
`start_fleet_mixed`, the defect stayed hidden until the contract audit exercised every frontend call path.

Fix (`20260926250000_fix_start_fleet_out_param_column_ambiguity.sql`, idempotent, patches the LIVE definition from
its own text and refuses to touch anything unexpected):

```sql
-- before
UPDATE public.planet_ships SET quantity=quantity-p_quantity WHERE planet_id=p_origin_planet_id AND ship_id=p_ship_id;
-- after
UPDATE public.planet_ships AS ps SET quantity = ps.quantity - p_quantity WHERE ps.planet_id = p_origin_planet_id AND ps.ship_id = p_ship_id;
```

Tests: `supabase/tests/fleet_dispatch_contract.sql` — **9/9 PASS, transactional (ROLLBACK, zero residue)**: fleet slots
derived from computer technology (5 → 6 slots), TRANSPORT dispatch creates the fleet, EXPEDITION with a NULL
destination is accepted, ship consumption (20−3−2=15) and fuel charging are booked, the function text is qualified
(regression guard), the business refusals still fire (over-quantity, invalid mission, unknown ship), a foreign actor is
refused, and `start_fleet_mixed` still works.

Related findings already recorded for this session: the same ambiguity class was fixed earlier in `start_fleet_mixed`;
an OUT-parameter scan over every public function now reports no further unqualified references on live paths.

## H2 CLOSED 2026-09-26 — `process_fleet_movements` OUT-parameter/column ambiguity (battle branch)

Same defect class as the `start_fleet` P0 of the same day (see the section above). The worker declares
`RETURNS TABLE (fleet_id, previous_status, new_status, processed_at)`, and the battle/recycle branch of its loop
referenced the `fleet_movement_ships` column unqualified:

```sql
-- before
  delete from public.fleet_movement_ships where fleet_id=v.id;
-- after (20260926260000_fix_process_fleet_movements_out_param_column_ambiguity.sql)
  delete from public.fleet_movement_ships as fms where fms.fleet_id = v.id;
```

The ambiguity class was **proven** with a local reproducer: a temporary function with an OUT parameter named
`fleet_id` and the same statement raises `column reference "fleet_id" is ambiguous`. The patch is idempotent and
verifies the exact pre-state statement before touching anything.

### RESOLVED — the harness was at fault, not the worker (see "H4 CLOSED" below)

While verifying the patch, the worker returned **zero rows** for a fleet that was clearly due
(`status='OUTBOUND'`, `arrives_at = now() - 1 minute`) and for a fleet due on the return leg
(`status='RETURNING'`, `returns_at` in the past), leaving the status untouched. The per-fleet error isolation
(`begin … exception when others then continue`) swallows whatever fails, so the error never surfaces.

Established evidence:

* LIVE has **no fleets at all** right now, which is why this never showed up in production traffic.
* Dispatching works after the `start_fleet` fix (fleet created, ships consumed, fuel charged).
* `resolve_transport_arrival` works when called directly with the fleet in `ARRIVED` state (it returns `RETURNING`).
* The worker's first loop statement (`update public.fleet_movements set status='ARRIVED' where id=v.id and status='OUTBOUND'`)
  contains no OUT-parameter collision, so the swallowed failure lies later in the loop body or in another helper it calls.

Next session must isolate it (temporarily surface the swallowed error, or replicate the loop body statement by statement).
Until then, treat **fleet arrival processing as unverified**: the contract is dispatched correctly, but no end-to-end
arrival/return could be observed in a real transaction.

## H4 CLOSED 2026-09-26 — the worker drives the whole lifecycle (the earlier harness was insufficient)

`process_fleet_movements` was **never broken**. The two failures seen by the first audit harness were harness artifacts:

1. **Resource-timeline coherence.** `update_planet_resources_until` / `update_planet_resources_until_raw` raise
   `INVALID_RESOURCE_TIMESTAMP` (P0001) when asked to write a planet before `planet_resources.last_calculated_at`.
   The harness fast-forwarded the fleet two hours back while the ledger was at `now()`, so the engine refused — correctly.
   A fixture that time-travels must first move the ledger back (`last_calculated_at = now() - interval '4 hours'`)
   for the planets involved.
2. **A hand-made `ARRIVED` row leaves the worker's loops.** The worker itself performs `OUTBOUND → ARRIVED`; setting
   `ARRIVED` manually (as the first harness did) removes the fleet from the only loop that would process it, which is
   exactly why the worker returned zero rows. Fixtures must leave the fleet `OUTBOUND` and let the worker work.

The worker also already self-instruments failures: `raise warning 'FLEET_RESOLUTION_FAILED fleet=% mission=% sqlstate=% error=%'`.
It is the first thing to look at when a fleet stalls (note: this project''s log stream does not surface WARNING level, so
an isolated harness is the practical way to read it).

### Observed state machine (TRANSPORT, end to end, LIVE)

```text
start_fleet            -> OUTBOUND   (ships and fuel leave the origin; fleet_movement_ships row created)
worker (arrival leg)   -> ARRIVED    (internal)  -> resolve_transport_arrival -> RETURNING   [rows returned: 1]
worker (return leg)    -> COMPLETED  (ships come home: 6 - 2 dispatched + 2 returned = 6)
messages               -> 'Fleet arrived', 'Fleet returning', 'Fleet returned' (dedupe_key fleet_arrived/returning/returned:<id>)
idempotence            -> two extra worker passes return zero rows and change nothing
```

Tests: `supabase/tests/fleet_worker_contract.sql` — **8/8 PASS, transactional (ROLLBACK, zero residue)**.

## H5 CLOSED 2026-09-26 — wreck-field helpers are internal

`wreck_field_space_dock_level` / `wreck_field_recover_percent` were executable by `anon` and `authenticated`, and the
former (SECURITY DEFINER over the RLS-hidden `planet_buildings`) let a foreign actor read another player''s Space Dock
level — reproduced LIVE (level 7). Confirmed before the change: no frontend reference of any kind, and the only callers
are wreck-field internals. `20260926270000_harden_wreck_field_helper_acl.sql` revokes both from `public`, `anon` and
`authenticated` and keeps `service_role`. Verified LIVE: a foreign authenticated actor now gets
`42501 permission denied for function wreck_field_space_dock_level`, `service_role` still gets the value, and
`has_function_privilege('authenticated', …)` is false for both.

## Superficie jugable de flotas — BLOQUE A (dispatch) + BLOQUE B (movimientos activos), 2026-09-26

Primer bloque de la fase **superficie jugable**: las mecánicas de flota ya certificadas se convierten en pantalla
sin crear ningún contrato nuevo (0 RPC nuevas, 0 cambios de ACL, 0 cambios de esquema, 0 cambios en los
despachadores certificados).

### Implementado

```text
src/FleetCommandPanel.tsx            (nuevo) FleetDispatchPanel + ActiveFleetsPanel
src/GameplayEnginePanel.tsx          FleetSlotsPanel.fleets ahora opcional; ExpeditionReportsPanel (nueva)
src/App.tsx                          vista FLOTA = slots + despacho + flotas activas; vista EXPEDICIONES = slots +
                                     objetos + despacho EXPEDITION + flotas activas + resultados
eslint.config.js                     la misma excepción deliberada que GalaxyView para la carga asíncrona en effect
```

Contratos usados (todos LIVE, leídos de los cuerpos desplegados):

```text
start_fleet_mixed · start_colonize_fleet · start_support_fleet · load_fleet_cargo · recall_fleet
get_player_fleet_slots · get_player_expedition_slot_status · check_colony_cap
lecturas directas permitidas por RLS: fleet_movements · fleet_movement_ships · planet_ships · planets · ship_definitions
```

Clases de misión expuestas tal cual están en el backend: `PEACEFUL` (TRANSPORT, DEPLOY, COLONIZE, EXPEDITION),
`WAR` (ATTACK, ESPIONAGE, RECYCLE), `HOLDING` (ACS_HOLD despachable; DEFEND y HOLDING se muestran **no
disponibles** con la puerta del backend en pantalla). La autoridad de slots, cap de colonias, capacidad de carga,
velocidad, combustible y estados sigue siendo exclusivamente del servidor: la UI no reproduce ninguna fórmula.


### Verificación LIVE (transaccional, ROLLBACK, residuo 0)

Ejecutada con `set local role authenticated` + `request.jwt.claims` de un jugador real (el mismo camino del
navegador). Evidencia literal:

```text
A0 get_player_fleet_slots (antes)                  max=6 in_use=0 available=6
A1 start_fleet_mixed EXPEDITION                    mission=EXPEDITION status=OUTBOUND destino=[1:1:16] hold=3600s
A2 lectura RLS del movimiento propio               filas visibles=1
A3 get_player_expedition_slot_status (en vuelo)    total=1 used=1 available=0
A4 segunda expedición (esperado rechazo)           EXPEDITION_SLOTS_FULL: 1/1
A5 recall_fleet expedición                         status=RETURNING
B1 start_fleet_mixed TRANSPORT                     status=OUTBOUND destino=<id resuelto desde coordenadas>
B2 load_fleet_cargo 10/20/15                       total=45 capacidad=50.00
   y el mismo intento con 100/200/300              Cargo exceeds fleet capacity: 600 / 50.00
B3 fleet_movement_ships                            light_fighter×1
B4 recall_fleet TRANSPORT                          status=RETURNING carga=10/20/15 naves={"light_fighter":1}
C1 start_colonize_fleet (destino ocupado)          COLONIZE_TARGET_OCCUPIED
D1 start_support_fleet ACS_HOLD sin autorización   SUPPORT_AUTHORIZATION_REQUIRED: the destination owner has not authorised …
D2 start_support_fleet DEFEND                      COMBAT_SUPPORT_NOT_READY: DEFEND requires the ACS combat engine
E1 load_fleet_cargo sobre ATTACK                   CARGO_MISSION_NOT_SUPPORTED: mission ATTACK cannot carry loaded cargo
E2 start_fleet_mixed RECYCLE con cazas             No debris field available for RECYCLE
F1 slots con 3 flotas vivas                        in_use=3 available=3 filas_movimiento_nave=3
residuo tras ROLLBACK                              fleets=0 fleet_ships=0 computer_level=null fighters=1 deuterio=98900
                                                   messages=0 wreck_fields=0
```

Frontend: `npx tsc -b` 0 errores · `npx vite build` OK (bundle emitido) · `git diff --check` limpio ·
`npx eslint src` vuelve al recuento previo (5 errores preexistentes en App.tsx, GameplayEnginePanel.tsx y
main.tsx; el archivo nuevo aporta 0).

Bugs de compilación preexistentes corregidos (bloqueaban `tsc -b`; no causados por este bloque):
`src/lib/identity.ts` conservaba dos líneas huérfanas de un cast retirado y `BuildingDemolitionPanel` perdía el
estrechamiento de tipos dentro de una función anidada.



### Hallazgos de este bloque (no implementados, deliberadamente)

```text
BUG (latente, §H6)         p_building_id inexistente → "structure of query does not match function result type".
                           No se ha tocado: no impide ninguna pantalla de este bloque.
BACKEND GAP (ACS_HOLD)     No existe contrato público que liste autorizaciones de apoyo y `planet_support_authorizations`
                           sólo concede MAINTAIN a authenticated (probado LIVE: 42501 permission denied). El envío
                           ACS_HOLD sí funciona por coordenadas y el servidor valida la autorización; lo que no puede
                           construirse es la pantalla de concesión/descubrimiento (además `players` oculta a los demás
                           humanos, así que el propietario tampoco puede resolver un invitado por nombre).
                           → No se abrió ninguna ACL ni se creó una RPC.
BACKEND GAP (wreck field)  La nota del bloque de wreck field («the tables are ready to be read directly from the UI»)
                           no se sostiene en LIVE: `planet_wreck_fields` y `planet_wreck_field_ships` no conceden SELECT
                           a authenticated (sólo MAINTAIN, sin RLS). El panel del BLOQUE F necesita un contrato de
                           lectura owner-scoped; no se ha creado.
BY DESIGN                  No hay contrato público de previsualización de vuelo (velocidad/combustible/tiempo): los
                           helpers `calculate_player_ship_speed`, `calculate_mission_fleet_speed_multiplier`,
                           `calculate_fleet_travel_time` y `calculate_fleet_cargo_capacity` son internos. La UI muestra
                           la respuesta del despacho (`arrives_at`) y la capacidad que devuelve `load_fleet_cargo`.
FUTURE UI                  CORRECTED 2026-09-26: MOON_DESTRUCTION (`start_moon_destruction`) and the moon actions
                           (phalanx, jump gate) ARE now part of the surface — the fleet selector offers
                           MOON_DESTRUCTION with a foreign-moon destination and `MoonServicesPanel` drives
                           `scan_with_phalanx` / `execute_jump_gate`; the active-body selector (planet/moon) exists
                           in the shell. Nothing in this row is pending any more.
```

### Estado del panel activo y siguientes bloques

`ActiveFleetsPanel` muestra misión, origen, destino, estado, salida, llegada, espera (`holding_until`), regreso,
carga, combustible y composición, con recuento descendente local sobre las marcas del servidor, refresco cada 20 s
mientras existan flotas vivas, y las acciones disponibles según el contrato: `recall_fleet` en `OUTBOUND`/`HOLDING`
y bodega (`load_fleet_cargo`) en `OUTBOUND` con misión de la whitelist. La capacidad de la bodega se lee por el
propio contrato con una carga de 0 (no muta nada).

Siguiente bloque listo para implementar: **E (superficie lunar)** —la información de luna ya se muestra en
`MoonsPanel`, pero edificios lunares, falange, puerta de salto y destrucción necesitan antes el selector de planeta
activo—, seguido de **F (wreck field)**, bloqueado por el BACKEND GAP del contrato de lectura, y **G (informes)**,
que ya se apoya en los contratos certificados. Los bloques C (Expedición) y D (Colonización) quedan cubiertos en
esta misma entrega dentro de la vista EXPEDICIONES y del selector COLONIZE.

## 25. Beginner protection (human targets) — implemented 2026-09-26

### 25.1 What existed before (evidence, not assumption)

* **LGI had no beginner/newbie protection.** A repo-wide search for
  `beginner|newbie|novice|newcomer|protection_until|protected_until|attack_protection|immunity` returns only
  documentation notes, and LIVE introspection over `pg_proc.prosrc` and `information_schema.columns` for the same
  terms returns **zero rows**: no function, no column, no duration, no enforcement.
* **OGameX @ 7c420bad has none either.** `app/GameMissions/AttackMission.php::isMissionPossible` validates target
  existence, the destroyed-moon rule, own-planet, `checkTargetVacationMode($targetPlanet)` and
  `checkAdminProtection($targetPlanet, …)` — no protection window, no account-age rule, no points-ratio rule.
  `EspionageMission` blocks only the admin planet, and `start_support_fleet` (ACS defend) is support, not attack.

### 25.2 The rule implemented (an LGI-owned window, reused — not invented)

```text
window      players.created_at + 24 hours
authority   public.get_player_attack_protection(player_id, at default now())
            -> (out_protected boolean, out_protected_until timestamptz, out_reason text)
               reasons: BEGINNER_PROTECTION_24H | EXPIRED | NOT_HUMAN_TARGET | PLAYER_NOT_FOUND
scope       a HUMAN target (players.user_id IS NOT NULL) inside its first 24 h
guard       BEFORE INSERT trigger trg_enforce_beginner_protection on public.fleet_movements
            raises TARGET_BEGINNER_PROTECTED: player <id> is protected until <ts>
```

Neither the duration nor the anchor is new: they are the 24-hour window the owner already approved for the AI
attacker gate of `20260926291000` ("no attack during the AI's first 24 h"), reused on the DEFENDING side. The
`at` parameter exists so the frontier case is testable and a replayed tick stays deterministic.

### 25.3 Scope, decided by the evidence

| Mission / path | Blocked? | Why |
|---|---|---|
| ATTACK — `start_fleet`, `start_fleet_mixed` | **yes** | the only attack paths; the trigger covers every dispatcher, present and future, by construction |
| ESPIONAGE | no | OGameX restricts only the admin planet; espionage is information, not aggression |
| TRANSPORT / RECYCLE / COLONIZE | no | none of them is an attack |
| ACS defend / support — `start_support_fleet` | no | support, not attack |
| AI targets | no | declared scope: an AI already has the symmetric attacker-side 24 h gate; a target-side rule for AI empires would be a new product decision |
| attacker side for humans | no | OGameX has no such rule; inventing it is a product decision |

A client cannot bypass it: the guard runs server-side on the INSERT of the movement, so no parameter — including
a hand-crafted RPC call — can create an ATTACK against a protected player.

### 25.4 How it was verified

`supabase/tests/ai_normalization_and_beginner_protection.sql` — 14 PASS + 1 INFO (LIVE, rolled back): a freshly
provisioned human is protected until `created_at + 24 h`; the frontier case (protected one second before expiry,
released exactly at expiry); a real ATTACK dispatch from an armed AI is refused with `TARGET_BEGINNER_PROTECTED`
and creates no movement; the same attack succeeds once the human is out of protection; espionage against the
protected human is allowed; an AI target reports `NOT_HUMAN_TARGET`; the trigger exists and acts only on
`mission_type = 'ATTACK'`. Regression: `ai_behaviour_policy.sql` 20/20 PASS (including a real attack dispatch)
and `ai_player_policy.sql` 6/6 PASS.

**Remaining product decisions (declared, not implemented):** a target-side rule for AI empires, an attacker-side
restriction for humans, a points-based (rather than time-based) novice band, and a visible UI hint of the
remaining protection time (it would need a new client read contract).

## 26. Espionage reports — level gating (certified 2026-09-27)

### 26.1 Authority and contract

The single writer is `public.resolve_espionage_arrival(fleet_id)` (SECURITY DEFINER, service_role only). The report
is stored **already filtered**: a category that is not revealed is persisted as `{}`, never as the real data, so a
client cannot mine more by reading the row. The single reader is `public.get_player_espionage_reports(limit)`
(SECURITY DEFINER, authenticated only), scoped to the players owned by `auth.uid()`; `public.espionage_reports`
itself carries `deny_direct_api_access` (using/check false) for `anon` and `authenticated`, so a direct SELECT
returns zero rows.

```text
level_gap       = greatest(0, target_espionage_level - attacker_espionage_level)
remaining       = greatest(0, probes_sent - level_gap ^ 2)
reveal_ships    = remaining >= 2  or  attacker_level - 1 >= target_level
reveal_defenses = remaining >= 3  or  attacker_level - 2 >= target_level
resources       metal / crystal / deuterium: stored unconditionally (no gate)
```

That is OGameX `7c420bad` verbatim: `canRevealData($remaining, $attacker, $defender, 2, 1)` for ships and
`(…, 3, 2)` for defense, with `$extraProbesRequired = pow($levelDifference, 2)`.

### 26.2 visible_at_level (measured; defender at level 0, one probe)

| category | visible at | authority | stored complete? | returned to client? |
|---|---|---|---|---|
| resources (metal/crystal/deuterium) | always | `resolve_espionage_arrival` | yes (synced target values) | yes (`out_metal/out_crystal/out_deuterium`) |
| ships (`fleet`) | level 1 (level path) or 2 remaining probes | same | **filtered at write time** | yes, as stored (`{}` when hidden) |
| defenses (`defenses`) | level 2 (level path) or 3 remaining probes | same | **filtered at write time** | yes, as stored (`{}` when hidden) |
| buildings | — | no column, no reveal path, no client contract | n/a | **never** |
| research | — | same (retired by `20260921140925_retire_research_action_candidates_client_contract`) | n/a | **never** |
| `energy` column | always | same | yes | yes (`out_energy`) — **deviation**: LGI stores the target's total ship attack (`sum(quantity × attack)`), OGameX stores the planet energy; pinned by the fixture, change = product decision (DEFERRED) |

A stored report is a **snapshot**: raising the attacker's espionage level afterwards does not upgrade it.

### 26.3 What was proven and how

`supabase/tests/espionage_report_gating.sql` (LIVE, rolled back): the level ladder 0…4, the probe-budget frontier
(gap 2 with 1/6/8 probes), the mixed case (level 3 vs 2 → ships visible, defenses hidden, counter-espionage chance
0 and no battle), a moon target, resources ungated, the `energy` aggregate, a direct SELECT as `authenticated` and
`anon` returning 0 rows, the owner RPC returning the hidden report with empty categories and no foreign row, a
snapshot that does not gain information at level 7, and the ACL invariants. `counter_espionage.sql` keeps covering
the OGameX chance formula and the battle.

**Harness note:** the fleet *insert* needs a session (`AUTHENTICATION_REQUIRED` without it) while
`resolve_espionage_arrival` must run **without** a JWT — `calculate_planet_storage` refuses a foreign planet when
`auth.uid()` is set (`PLAYER_NOT_OWNED`), which is exactly how the cron worker resolves fleets in production.

## 27. Browser certification of the fleet flow — BLOCKED (2026-09-27)

A real UI → Supabase client → RPC → engine → worker certification was requested. It could NOT be executed and is
reported as BLOCKED, never as PASS:

```text
start_fleet          = BLOCKED
start_fleet_mixed    = BLOCKED
start_colonize_fleet = BLOCKED
start_support_fleet  = BLOCKED
```

Causes, all verified in this environment:

1. **No browser automation dependency.** `package.json` lists no Playwright/Puppeteer/Cypress and neither exists in
   `node_modules` (`@playwright`, `playwright`, `playwright-core`, `puppeteer` all absent); Vite is the only
   runner. Chrome/Edge binaries exist, but there is no driver, and installing one would modify the dependency tree.
2. **No human session credential.** `.env.local` exposes only `VITE_SUPABASE_URL` and
   `VITE_SUPABASE_PUBLISHABLE_KEY`; the only human player in LIVE cannot be authenticated without its password, and
   minting a JWT by hand was rejected as fabrication.
3. **No fixture may fake ownership** (mission rule) and creating a throw-away account would mutate LIVE.

Done instead, explicitly **not** a substitute: the static UI→RPC inventory (`supabase.rpc('…')` over `src/**`, 32
RPCs) that feeds the ACL allow-list, plus the backend contracts the browser would drive (dispatchers, ownership
guards, fleet slots, the beginner-protection gate, the espionage gating), each certified by its own SQL fixture.
The browser step remains OPEN.

## 28. Expedition merchant (`GainMerchantTrade`) — reachable from the client (2026-09-27)

### 28.1 The hole (measured LIVE, 2026-09-27)

LGI adopted the OGameX `ExpeditionOutcomeType::GainMerchantTrade` outcome: `expedition_settings.weight_merchant`
is `0.4` in the universe that actually has planets (`cf021ece`), `resolve_expedition_arrival` calls
`resolve_expedition_merchant`, that function writes (or IMPROVES) the active row of
`player_expedition_merchants`, and the report (`expedition_results.merchant_*`) and the message announce it.

Nothing could consume it:

```text
read    player_expedition_merchants carries the policy `deny_direct_api_access` (USING/WITH CHECK false for anon
        and authenticated) → the client cannot read the offer at all
write   `execute_expedition_merchant_trade` is EXECUTE = service_role only, has ZERO callers in `pg_proc`, the
        Worker has no RPC path and there are no Edge Functions
UI      the expedition report printed `comerciante <resource>` and stopped there
```

Consequence: a reward that can never be used and a state row that stays `active = true` forever (further merchant
outcomes only raise its rates). The rules themselves were never missing — they were unreachable.

### 28.2 What was implemented (no new rule, no new formula, no parallel engine)

```text
20260927024948_expedition_merchant_trade_contract
  get_player_expedition_merchant()
      read contract, owner-scoped: one row with `has_merchant`, `offered_resource` (what the merchant GIVES —
      the trade's `bought_resource`) and the three rates. One row always, so the UI has a stable shape.
  trade_with_expedition_merchant(p_planet_id, p_sell_resource, p_sell_amount)
      identity from `auth.uid()` → `players.user_id` (NEVER a client-supplied player id), ownership of the body
      verified (owned and not destroyed), then the RULE is delegated to the already-LIVE
      `execute_expedition_merchant_trade`; it returns the same four columns (`sold`, `bought`, `bought_resource`,
      `remaining_merchant`) so the client never recomputes the exchange.
  ACL: both = EXECUTE `authenticated` + `service_role`, never `anon`, never PUBLIC (the DDL guard trigger
      enforces it). The delegated internal function stays `service_role`-only on purpose: the AI actor /
      service_role must keep passing its own `p_player_id` and must NOT be forced through `auth.uid()`.
UI   src/GameplayEnginePanel.tsx `ExpeditionMerchantPanel` (mounted in the Expeditions view): shows the
     resource the merchant gives and the rates, offers only the OTHER two resources as payment, and displays the
     server's answer. No price is recomputed in React and no player id is sent.
```

### 28.3 Verification

```text
supabase/tests/expedition_merchant_trade.sql — 15 PASS + 2 INFO, LIVE, ROLLBACK, residue 0
   1   ACL: authenticated yes, anon no, PUBLIC revoked, delegated function still closed
   2   no session: trade refused ('Authentication required'), read returns 0 rows
   3   no active offer: refused ('No active merchant for player …'), resources untouched
  4/5  a foreign body, and an authenticated stranger, refused with PLANET_NOT_FOUND_OR_NOT_OWNED; nothing moved
   6   the owner reads the offer (resource + rates)
   7   100 crystal → 150 metal at 3/2/1 exactly; offer deactivated; remaining_merchant = false
  8/9  the second trade is refused (no double reward); the read reports has_merchant = false
  10   paying with the resource the merchant gives is refused BY THE RULE, offer untouched
  11   insufficient resources refused, resources untouched
  12   storage clamp: 1000 crystal requested → sold 20 / bought 10, metal == capacity (never overflows)
  13   another player's offer is not usable by me; his row stays active
 14a/b a non-positive amount and an unknown resource are refused before any mutation
```

Scope boundary kept explicit: this is only the **expedition** variant. The general merchant, the shop and the
premium economy (spending Dark Matter) remain out of scope and untouched.

## 29. Debris fields are visible to the player (2026-09-27)

### 29.1 The hole (measured LIVE, 2026-09-27)

`public.debris_fields` carries the `deny_direct_api_access` policy (USING/WITH CHECK `false` for `anon` and
`authenticated`) and **no contract exposed it**, so the client could not see debris anywhere: the only mentions of
`debris` in `src/**` are report texts. The RECYCLE mission itself works — `start_fleet_mixed` selects the
**nearest** field for the caller — which is precisely why the blind spot mattered: the player recycled without
ever knowing that a field existed, how big it was, or how far the recyclers would fly.

### 29.2 What was implemented

```text
20260927035703_universe_debris_read_contract
  get_universe_debris(universe, galaxy, system) → out_position, out_metal, out_crystal, out_updated_at
      · the universe is VALIDATED against the identity (auth.uid() → players.user_id must have a player in that
        universe); otherwise 0 rows — no cross-universe leak, no client-supplied authority
      · only fields with metal > 0 OR crystal > 0 are announced
      · ACL: EXECUTE authenticated + service_role, never anon, never PUBLIC
      · the table remains closed: producers (create_combat_debris, add_debris_field) and the collector
        (collect_debris) stay internal
UI   src/GalaxyView.tsx — each slot of the system view shows its debris (RESTOS <metal> M / <crystal> C) next to
     the planet/empty label, plus a "N CAMPO(S) DE RESTOS" counter in the status line
```

Visibility rationale (recorded): debris is public game state, exactly like the planets the galaxy view already
lists with their foreign owners, and `can_recycle_debris` never checked who owned the debris. No new rule, no
new reward, no write path.

Not done on purpose: a coordinate-targeted RECYCLE dispatch from the galaxy view is **not** possible today —
`start_fleet_mixed` has no coordinate parameters and the certified contract chooses the nearest field
server-side. Adding it would need a new dispatch contract/rule and was **not invented**; the debris display and
the existing RECYCLE mission are enough to act on the information.

### 29.3 Verification

```text
supabase/tests/universe_debris_read_contract.sql — 10 PASS + 1 INFO, LIVE, ROLLBACK, residue 0
  1  ACL: authenticated yes, anon no, PUBLIC revoked
  2  the debris_fields policy is still deny_direct_api_access (the table is NOT opened)
  3  without a session → 0 rows
  4  a foreign universe → 0 rows (no cross-universe leak)
  5  the own system returns exactly the inserted field (12345 M / 6789 C at the position)
  6  another system of the same universe → 0 rows
  7  a zero-amount field is not announced
  8  updated_at is returned
  9  as `authenticated` the contract returns the row
 10  as `authenticated` a direct read of debris_fields still returns 0 rows
```

## 30. Ship losses that exhaust a stack violated `fleet_movement_ships_quantity_chk` (fixed 2026-09-28)

### 30.1 The hole (measured LIVE 2026-09-28)

```text
contract     resolve_expedition_black_hole(fleet_id) — the BLACK_HOLE branch of resolve_expedition_arrival.
symptom      the settlement subtracted the rolled loss with
                UPDATE public.fleet_movement_ships SET quantity = quantity - v_loss_qty WHERE ...
                DELETE FROM public.fleet_movement_ships WHERE ... AND quantity <= 0;
             so when the loss consumed an ENTIRE stack the UPDATE wrote quantity = 0 and violated
             fleet_movement_ships_quantity_chk = CHECK (quantity > 0); the statement aborted and the DELETE that was
             meant to remove the exhausted row never ran.
consequence  the error is NOT swallowed here (unlike the moon path): it propagates to resolve_expedition_arrival
             for a deterministic roll, so the expedition cannot be resolved at all.
reproducible 6/6 LIVE with the fleet {espionage_probe 1, light_fighter 1}: the loss target is capped at
             total-1, so the single-unit stack is always fully consumed and the single-unit write is deterministic.
```

### 30.2 What was implemented (same shape as the moon fix, no new rule)

```text
migration    supabase/migrations/20260928121226_fix_fleet_movement_ship_loss_quantity_check.sql
             applied to LIVE as version 20260928121226 and written to the repo (not committed).
fix          delete the stacks the loss exhausts FIRST, then subtract only from the surviving stacks:
                DELETE  ... AND quantity <= v_loss_qty;
                UPDATE  ... SET quantity = quantity - v_loss_qty AND quantity > v_loss_qty;
             quantity = 0 is never written, so the CHECK holds. Same signature, same ACL, same contract,
             same table, same formula and same distribution; idempotent (no-op if already patched).
post-check   inside the migration: no liquidation path keeps the legacy block and no ACL drift (both helpers
             stay service_role only; anon and authenticated denied).
md5 LIVE     resolve_expedition_black_hole prosrc 8db2c06ae768312ca05eda82e422e3a2 (was b9771f6d…).
```

### 30.3 Verification

```text
supabase/tests/fleet_ship_loss_quantity_check.sql — 8 PASS + 2 INFO, LIVE, ROLLBACK, residue 0
  5  the black hole resolves: lost {espionage_probe: 1}, surviving {light_fighter: 1}, loss 50.00%
  6  the exhausted stack is removed and the survivor kept: 1 unit left, 0 rows with quantity <= 0
  7  a partial loss still subtracts instead of deleting: 2 lost of 4, 2 surviving, 0 rows with quantity <= 0
  8  global invariant: fleet_movement_ships has 0 rows with quantity <= 0
  9  static post-condition: 0 liquidation functions still subtract before deleting
  INFO single-session harness, no concurrency. The 50% loss is structural (the loss target is capped
       at total-1), not a lucky roll.

## 31. Beginner protection visibility — CLOSED 2026-09-28

### 31.1 The gap

§25 introduced beginner protection: an empire inside its first 24 h cannot be attacked. The rule is
**enforced** by `enforce_beginner_protection_before_insert`, a BEFORE INSERT trigger on `fleet_movements`
that refuses any `ATTACK` whose target is still protected:

```text
MEASURED LIVE: attacking a freshly created empire
  → TARGET_BEGINNER_PROTECTED: player <id> is protected until <ts>
```

But it was **invisible to the player**:

```text
get_player_attack_protection(player_id, at)   → service_role ONLY (correctly: it takes a player id)
grep -r 'protection|beginner' src/**          → ZERO hits
```

The only place the rule ever surfaced was the raw text of a **failed** attack. An attacker never learns
*before* striking that a target is shielded, and a brand-new empire never learns it is protected. In
OGame this state is plainly visible to the player. This was a real, demonstrable gap in an already
enforced mechanic — not a proposal for a new rule.

### 31.2 The contract

`20260928210000_add_my_attack_protection_read_contract.sql` (LIVE) adds ONE read-only function and
changes no rule:

```text
name        public.get_my_attack_protection()      — NO arguments
ownership   auth.uid() -> players.user_id -> players.id
            with no player_id parameter, no argument can select another player
delegates   to get_player_attack_protection(), the SAME authority the ATTACK trigger calls,
            so the UI can never drift from the enforcement (the rule is NOT re-implemented)
returns     out_protected, out_protected_until, out_reason
security    SECURITY DEFINER + search_path pinned to public, pg_temp
ACL         revoke public + anon; grant authenticated + service_role
```

The internal helper `get_player_attack_protection` stays `service_role` only — it is deliberately NOT
opened, and the migration's post-conditions raise if that ever changes.

### 31.3 UI

`ProtectionStatusPanel` (`src/GameplayEnginePanel.tsx`), mounted on the overview screen next to
`RankingPanel` / `MoonsPanel`. It renders the contract's own answer and nothing else; it reuses the
existing `neo-panel` / `fleet-group-head` / `neo-definition-stats` / `neo-empty` classes, so **no CSS was
touched**. It renders nothing at all when the empire is not protected, so an established player sees no
change. `database.types.ts` gained the signature by hand (the CLI regeneration needs credentials this
environment does not have).

### 31.4 Verification

```text
supabase/tests/my_attack_protection_visibility.sql — 8 PASS + 2 INFO, LIVE, ROLLBACK, residue 0
  1  a fresh empire reads PROTECTED, with a window ending inside 24 h
  2  the contract returns the SAME answer as the authority the ATTACK trigger uses
  3  an empire outside the window is not protected (reason EXPIRED)
  4  exactly ONE row — my own state, never a list of players (ownership by construction)
  5  without a session it returns 0 rows
  6  the contract takes NO arguments: a player selector is impossible
  7  no write path: the body cannot insert/update/delete/truncate
  8  ACL: new contract authenticated + service_role, anon denied; the internal helper is still
     service_role only
residue    0: Mbp* players 0, auth.users 12, movements 0 — identical to pre-run
regression 8 PASS: transport / espionage-report / battle-report contracts intact, the ATTACK protection
           trigger untouched, the espionage composition guard and the untouched resolver intact, the
           internal helper still service_role only, no RLS policy added or removed
static     npx tsc -b exit 0 · npx vite build exit 0 · git diff --check clean
browser    ENVIRONMENT BLOCKED — no browser driver + human DEV credential. The panel's rendering is
           therefore NOT certified; the contract it consumes is.
```

### 31.5 Limitations, stated rather than hidden

* Browser validation is blocked; the assertions cover the contract, not the DOM.
* LIVE's single human player (`DevPlayer`, created 2026-09-13) is long past the window, so the panel
  legitimately renders nothing there; the protected case is exercised by fixture-created empires that are
  rolled back.
* This adds visibility only. It does not change the 24 h window, the trigger, the AI scope, or any
  balance.

```

## 32. RECYCLE discoverability — CLOSED 2026-09-28

### 32.1 The gap

The RECYCLE mission chooses its own target: the player may not send coordinates, so `start_fleet_mixed`
picks the nearest non-empty field and raises `No debris field available for RECYCLE` when there is none.
That refusal was already **correct and atomic** (verified LIVE: 0 movements created, no slot and no fuel
consumed), so this was never a correctness bug.

What was missing is **discoverability**. `launchBlock` (`useFleetDispatch.ts`) derives a pre-flight
warning for `FLEET_SLOTS_FULL`, `EXPEDITION_SLOTS_FULL` and `COLONY_CAP_REACHED` straight from server
contracts, and RECYCLE had no such case: the launch button was enabled and the only feedback was the
error *after* pressing it. On LIVE the human player's universe (`cf021ece`) contains **zero** debris
fields — all 3 live in another universe — so every RECYCLE attempt was guaranteed to fail silently in
advance.

### 32.2 Why existence-only is EXACT, not a weakening

The dispatcher selects with `WHERE df.universe_id = <mine> AND (df.metal > 0 OR df.crystal > 0) … LIMIT 1`
and raises precisely when that finds nothing. So "is there a recyclable field?" **is** the dispatcher's
own precondition — no ordering and no distance involved. Verified LIVE on both cases: an empty universe
(`EXISTS = f`, dispatcher found nothing) and a populated one (`EXISTS = t`, dispatcher found `[1:1:15]`).

This is why the mission could be closed without a product decision. The alternative — telling the player
*which* field and *how much* it holds — would have required duplicating the dispatcher's `ORDER BY` in a
second place (and choosing a distance metric for a target that has no planet), which is exactly the
second-source-of-truth drift this repository has been eliminating. That option was explicitly **not**
taken.

### 32.3 The contract

`20260928220000_add_recyclable_debris_status_contract.sql` (LIVE), one read-only function:

```text
name        public.get_recyclable_debris_status()   — NO arguments
ownership   auth.uid() -> players.user_id -> players.universe_id -> debris_fields
            (not even a universe id can be supplied by the client)
predicate   (metal > 0 OR crystal > 0) — the dispatcher's own condition
returns     out_available boolean, out_field_count bigint
security    SECURITY DEFINER + search_path pinned (debris_fields is closed to the client)
ACL         revoke public + anon; grant authenticated + service_role
```

It does **not** tell the player which field will be targeted, and it does **not** model capacity: which
field is chosen and how much fits remain the engine's decision. The migration's post-conditions raise if
the ACL drifts, if the contract ever grows an argument, if a `distance|range|capacity|order by|limit`
token ever appears in its body, or if the recycling engine ever starts depending on it.

### 32.4 UI

`useFleetDispatch` fetches the contract only while the RECYCLE mission is selected and feeds it into the
**existing** `launchBlock`, which disables the launch button and shows the reason. The pre-existing
`NEAREST_DEBRIS` note gained one sentence reporting the field count. No new component, no CSS, no new
visual system: both edits reuse markup that was already there.

### 32.5 Verification

```text
supabase/tests/recyclable_debris_status.sql — 12 PASS + 2 INFO, LIVE, ROLLBACK, residue 0
  1  an empty universe -> available = false, fields = 0
  2  ...and the ENGINE agrees ("No debris field available for RECYCLE", 0 movements) — the contract
     predicts the engine exactly, and the engine stays atomic
  3  one non-empty field -> available = true, fields = 1
  4  and now the engine really accepts the recycle flight (the mechanic still works)
  5  an exhausted (0/0) field is not recyclable: it is the dispatcher's own (metal>0 OR crystal>0)
  6  without a session the answer is a hard NO (available = false, fields = 0)
  7  a player of ANOTHER universe gets a hard NO, never my fields
  7b and the owner still sees its own field — proving 6/7 are isolation, not a broken contract
  8  the contract takes NO arguments: nothing to manipulate
  9  read-only and existence-only: no write, no distance/range/capacity/ranking in the body
  10 ACL: authenticated + service_role, anon denied
  11 the recycling engine is untouched and does not depend on the new contract
residue    0: debris_fields 3 (unchanged), universes 2, 0 Rds* players, 0 rdsother@example.invalid
           auth.users, 0 RdsOtherUniverse-% — all identical to pre-run
regression 7 PASS: both dispatchers still carry the RECYCLE branch; the four related functions remain
           SECURITY DEFINER; start_fleet_mixed kept its p_mission_type DEFAULT; get_universe_debris
           unchanged and still auth.uid()-gated; debris_fields still closed to direct access; the
           transport / espionage / battle / protection contracts all still callable; the espionage
           composition guard survives
static     npx tsc -b exit 0 · npx vite build exit 0 · git diff --check clean
browser    ENVIRONMENT BLOCKED — no browser driver + human DEV credential. The contract is certified;
           the panel's rendering is not.
```

> **Fixture repair 2026-09-29.** Re-running this file against LIVE initially aborted with
> `1 failed assertion(s)`. The cause was in the FIXTURE, never in the contract: it emptied the
> universe with `delete from debris_fields` and then only ever issued `UPDATE`s, so assertions 5/6
> touched **zero** rows and 7b asserted `out_field_count = 1` on a field that was never created.
> Assertions 3 and 4 — the positive half the header comment already referred to — were missing
> entirely, so the suite could only ever prove the negative answer. Fixed by inserting one real field
> after assertion 2 (the universe must still be empty when 2 observes the engine refusing), which
> restored 3 and 4. Re-run: **12 PASS + 2 INFO, 0 FAIL**, residue 0. Test 4 is asserted on the
> engine's *acceptance* plus a before-count, not on an absolute movement total, because LIVE may
> already hold RECYCLE rows for the selected player.

### 32.6 Limitations, stated rather than hidden

* Browser validation is blocked; the assertions cover the contract, not the DOM.
* The contract is an aggregate without `GROUP BY`, so it always returns exactly **one** row
  (`available = false, fields = 0` when nothing is visible). The UI reads the value, never the row count.
* LIVE's human player has no recyclers and no debris in their universe, so the shipped UI will show
  "no recyclable debris" there — which is the truthful answer, and is the point of this mission.
* This adds visibility only. The RECYCLE mechanic, its target selection, its capacity and the worker
  are untouched; only the *timing* of the information changed.

## 33. BROWSER CERTIFICATION — Fleet flow (2026-09-29)

The block that had been open since §27 is now **CLOSED**. It was closed with a real browser and a real
human DEV session — not with SQL, not with a mock, and without touching a single line of fleet logic.

### 33.1 Environment

| Item | Value |
|------|-------|
| Browser | Microsoft Edge, headless, real process |
| Driver | native CDP over WebSocket (`scripts/fleet-browser-certify.mjs`) — **no** Playwright/Puppeteer/Cypress |
| App | real Vite build served locally and opened in the browser |
| Supabase | LIVE |
| Player | real DEV account, logged in through the real login form |

Credentials were read from `process.env` at runtime only. They are **not** in the repository, not in
`.env`, not in any log line, and not in any screenshot. The runner prints only a masked address.

### 33.2 Happy path — 9/9

```
1  Login real DEV (UI, sin bypass)          PASS
2  Abrir vista Fleet (navegación real)      PASS   encabezado "Flotas"
3  Origen: selector con planeta propio      PASS   Homeworld [1:1:1] · PRINCIPAL
4  Misión: selección                        PASS   ATTACK
5  Naves: selección por input real          PASS   Light Fighter ×1
6  Destino: coordenadas                     PASS   1:1:4 (DOM read back and verified)
7  Botón LANZAR y su gate de UI             PASS   "LANZAR ATAQUE" disabled=false
8  N2/N3: rechazo del servidor              PASS   ERROR: Selecciona al menos una nave.
9  DISPATCH real desde la UI                PASS
```

Every one of those clicks was a real DOM event against the real React application.

### 33.3 What the server actually persisted

```text
fleet_movements   ATTACK · OUTBOUND · 1:1:1 → 1:1:4 · fuel_consumed 1
fleet_movement_ships   light_fighter × 1
planet_ships      light_fighter 1 → 0   (decremented at dispatch)
```

Then the real `deuteria-fleet-worker` cron (1 second, active) carried the lifecycle to completion:

```text
OUTBOUND  →  arrival + combat resolved  →  RETURNING  →  COMPLETED
planet_ships light_fighter 0 → 1  (returned to the origin planet)
outstanding slots back to 0
```

So dispatch, persistence, worker, arrival, mission resolution and return are all certified end to end
in a browser session.

### 33.4 Negative tests

| Test | Expected | Observed |
|------|----------|----------|
| N2 invalid fleet | rejected | `ERROR: Selecciona al menos una nave.` — nothing created |
| N3 invalid target | rejected | `ERROR: El destino debe ser distinto del planeta de origen.` |
| N2/N3 mission rule | enforced | `ESPIONAGE_MISSION_REQUIRES_PROBES: only espionage_probe may be sent…` |
| N4 duplicate submit | no duplicate | the rejected click produced **no** row; exactly 1 fleet existed at the end |
| N1 ownership | server-enforced | see below |

**N1 is enforced in the database, not in React.** `start_fleet` is `SECURITY DEFINER` and opens with:

```sql
v_auth_user := auth.uid();
IF v_auth_user IS NOT NULL THEN
  IF NOT EXISTS (select 1 from public.players pl
                 where pl.id = p_player_id and pl.user_id = v_auth_user)
  THEN raise exception 'Player does not belong to authenticated user';
```

followed by `Origin planet does not belong to player` and a same-universe check on the destination.
A client-supplied `player_id` is therefore worthless: it is only accepted when it resolves to the
authenticated user.

### 33.5 Two harness defects worth recording

The first runs of the runner reported PASS while nothing had been dispatched. Both causes were in the
**test**, never in the product, and both are now fixed:

1. Step 9 searched the whole `body` for the word "LANZAR" — which the launch button itself contains.
   It now reads the server's notice or its `ERROR:` paragraph instead.
2. Step 6 wrote the destination coordinates and never read them back, so a value React had discarded
   still counted as PASS. It now verifies the DOM afterwards. The screenshot (`06-post-dispatch.png`,
   empty coordinate fields) is what exposed both.

A third "failure" was not a defect at all: the DEV player owns exactly **one** `light_fighter`, so
ESPIONAGE is legitimately impossible and ATTACK is the correct mission for this account.

### 33.6 What is still not certified

The worker, arrival and return were observed through the database rather than by watching the UI count
down, and no ACS/HOLD, DEPLOY or multi-ship composition was exercised — the DEV account has a single
light fighter. Those are coverage limits of this account, not open defects.

## 34. Fleet slot cap — CLOSED 2026-10-03 (concurrency fixed)

> This resolves the long-standing `PRODUCT DECISION` label on the fleet-slot cap. **It was not a
> product decision: the policy was already decided and already enforced.** What was missing was
> that the enforcement did not hold under concurrency.

### The policy (unchanged — nothing here is new balance)

```text
base / effective capacity   1 + computer_technology level
bonus sources               computer_technology ONLY
maximum                     no separate cap; it grows with the research level
occupied slot               any fleet_movements row whose status is NOT in
                            ('COMPLETED','CANCELLED')  → OUTBOUND, ARRIVED,
                            HOLDING, RETURNING
consumed                    at INSERT (dispatch time)
released                    the moment status becomes COMPLETED or CANCELLED
enforcement point           BEFORE INSERT trigger trg_enforce_fleet_slots on
                            fleet_movements → assert_player_fleet_slot_available
read contract               get_player_fleet_slots()  (owner-scoped, SECURITY DEFINER)
UI                          src/screens/fleet/FleetModules.tsx — SLOTS MÁXIMOS /
                            EN VUELO / LIBRES, all read from the server contract
```

Because the gate is a **database trigger**, it covers *every* insert path — the RPCs and the AI
actor alike — not just the ones the UI happens to call. A client cannot dodge it by changing
`player_id`, mission, planet or payload: `authenticated` has no `INSERT` on `fleet_movements`
(verified `false`), so the only way in is through a `SECURITY DEFINER` function, and all of them
land on the trigger.

### The real defect: lock scope vs. resource scope

The limit is **per player**, but every dispatch locked only the **origin planet**:

```sql
SELECT ... INTO v_origin FROM public.planets p
 WHERE p.id = p_origin_planet_id AND NOT p.is_destroyed FOR UPDATE;
```

Two concurrent dispatches by the same player from **different** planets therefore did not
serialise. Both counted the same free slots, both passed the assert, both inserted — N available
slots became N+1 active fleets. Nothing on the client has to be manipulated for this.

### The fix — `20261004010000_fleet_slot_player_lock`

`assert_player_fleet_slot_available` now takes the lock on the **player row** before counting:

```sql
SELECT pl.id INTO v_locked FROM public.players pl
 WHERE pl.id = p_player_id FOR UPDATE;
```

This is the single choke point every `fleet_movements` insert passes through, so one change covers
the RPCs *and* the AI. Only one lock is taken per call, so this lock cannot form a deadlock cycle;
the order relative to the pre-existing planet lock is unchanged (planet first, then player).

Signature, exception text (`FLEET_SLOTS_FULL: x/y`), volatility and ACL are all unchanged — this
is a correctness fix to an already-decided rule, not a policy change.

### OGameX divergence

OGameX computes fleet capacity from Computer Technology too, and additionally from the Commander
and Officers classes. **Those bonuses were deliberately not imported**: Dark Matter / Officers /
premium are out of scope for this mission, so LGI's cap is `1 + computer_technology` with no
premium source. See §"DARK MATTER — DEFERRED" below.

### Tests

```text
supabase/tests/fleet_slot_cap.sql — 20 PASS / 0 FAIL, LIVE, ROLLBACK, residue 0
  P1-P3  policy = 1 + computer_technology; no Dark Matter / Officers dependency
  L1-L3  the lock is taken on the PLAYER row, the trigger is live, the assert is the choke point
  C1-C3  all slots fillable; at the cap the assert AND the trigger both refuse one more
  R1-R2  COMPLETED and CANCELLED both release the slot (no orphan slots)
  R3     OUTBOUND / ARRIVED / HOLDING / RETURNING each count as occupied
  S1-S4  forged player id, null player id, no client INSERT, assert stays closed
  U1     get_player_fleet_slots() agrees with the engine numbers
```

**Declared limitation:** the harness is single-session. A genuine two-connection race cannot be
opened from it, so mutual exclusion is *derived from the lock* (asserted in L1) and from correct
serial behaviour — it is not an executed race. This is the same limitation the other fleet
fixtures record.

### DARK MATTER — DEFERRED, NOT TOUCHED

No premium slot bonus, no Officers, no Commander, no Dark Matter spend-to-extra-slot was added.
The cap implemented here is the base mechanic and is fully independent of premium economy.

---

## Stuck-state fix: a fleet can no longer be frozen by a past event (2026-09-30)

**Defect.** Four fleet settlement sites anchored the economy clock to the SCHEDULED EVENT TIMESTAMP
(`returns_at` / `arrives_at`), and `update_planet_resources_until` correctly refuses to move a planet
backwards (`INVALID_RESOURCE_TIMESTAMP`). The worker's per-fleet handler downgraded that error to a
WARNING, which rolls nothing back and surfaces nothing — so if the event was already BEHIND that
body's production clock, the settlement failed on every heartbeat, forever.

This is reachable on the ordinary event order: any player action on the body (`start_building`,
`cancel_building`, `load_fleet_cargo`, the merchant, or the UI's `sync_current_planet_resources`)
settles it to `now()`. Measured on LIVE: an ACS_HOLD flight whose `returns_at` was 4 h in the past
stayed `RETURNING` permanently with its 5 cruisers debited and never returned; a TRANSPORT whose
`arrives_at` was 2 h in the past stayed `ARRIVED` permanently and its cargo was never delivered.

**Fix.** One clamp per settlement site: settle at `greatest(<event timestamp>, last_calculated_at)`.

| Site | Body |
|---|---|
| `process_fleet_movements` (RETURNING) | origin |
| `resolve_transport_arrival` | destination |
| `resolve_deploy_arrival` | destination |
| `resolve_expedition_return` | origin |

* The `INVALID_RESOURCE_TIMESTAMP` guard is **untouched** — it still refuses any raw backwards
  timestamp; the worker simply stops asking for one.
* When the event is still in the FUTURE (the normal certified path) the clamp is a no-op and the
  arrival-time anchoring is byte-identical. When it is behind, there is no elapsed time left to
  credit, so settling at the current clock grants **zero** extra production and lets the fleet finish.
* No balance invented: no cost, time, formula or capacity changed. Fleet ordering (fleets before
  planets) preserved.

Migrations `20260930240000_fix_stuck_returning_fleet_resource_timestamp` and
`20260930241000_fix_stuck_arrival_resolvers_past_event_timestamp`; certified by
`supabase/tests/fleet_stuck_return_arrival_regression.sql` (13 PASS, LIVE, ROLLBACK, residue 0).
See `docs/audits/FLEET_STUCK_STATE_GAP_2026-09-30.md`.
