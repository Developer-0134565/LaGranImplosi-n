# 2026-10-01 — STUCK-STATE DE COLA: un evento vencido ya no congela el heartbeat

## El hueco

`complete_building` y `complete_research` liquidan la economía **en el timestamp del evento** con
`update_planet_resources_until_raw`, que rechaza correctamente mover el reloj de un planeta **hacia
atrás** (`INVALID_RESOURCE_TIMESTAMP`). Esa guarda es correcta y **no se toca**.

Si el reloj del cuerpo ya estaba pasado cuando la cola vencía, la liquidación lanzaba en **cada**
heartbeat. La fila se quedaba `BUILDING`/`RESEARCHING` **para siempre** y, como
`process_universe_tick` no aísla errores por planeta, **ningún planeta de ese universo liquidaba**.

Es la versión de cola del mismo stuck-state ya cerrado para flotas
(`20260930240000` / `20260930241000` / `20261001030000`).

## Cómo se adelanta el reloj de una cola pendiente

Los anchors de flota y combate usan la variante `_raw`, que **no recorre eventos**:
`resolve_attack_arrival → apply_attack_loot`, `resolve_expedition_return`, etc. Un planeta puede
quedar liquidado más allá de un evento de cola pendiente. A partir de ahí ese evento es **invisible
al walker** (`finishes_at > last_calculated_at` ya no se cumple) pero **sigue visible al predicado
del tick** (`finishes_at <= now()`): ésa es exactamente la ventana del atasco.

`complete_research` lo amplifica: recorre **todos** los planetas del jugador, así que **un** solo
planeta adelantado abortaba el bucle y la concesión para todo el mundo.

## Semántica: se COMPLETA (no se descarta)

La regla se dedujo del código, no se eligió:

* el tick selecciona `finishes_at <= now()` → todo lo vencido se completa;
* `complete_building` / `complete_research` **no** tienen rama `CANCELLED` **ni** `DELETE`;
* sólo `cancel_building` / `cancel_research` ponen `CANCELLED`, y son **acciones del jugador** con
  reembolso. No existe abandono automático.

Descartar una cola pagada sería inventar una regla y destruir recursos del jugador.

## El arreglo

El mismo clamp ya aceptado para flotas, **por planeta**:

```text
effective = greatest(<timestamp de la cola>, <last_calculated_at de ESE planeta>)
```

* Evento en el **futuro** (vía certificada normal) → no-op; el reloj queda **exactamente** en
  `finishes_at`, byte-idéntico (verificado).
* Evento **detrás** → no queda tiempo transcurrido que acreditar, así que se liquida en el reloj
  propio del cuerpo: **cero producción extra** y la cola completa.

En `complete_research` el clamp se calcula **dentro** del bucle, contra el planeta que se liquida:
un planeta ya adelantado se liquida en su propio reloj (no-op) en lugar de lanzar y abortar los
planetas restantes **y** la concesión. La investigación se completa **exactamente una vez**.

Se conserva `_raw` a propósito: es lo que evita el procesamiento recursivo mientras un walker ya
recorre ese mismo evento.

## Lo que NO se cambió

`update_planet_resources_until_raw` y su guarda; las guardas de idempotencia (`COMPLETED` → nivel /
`false`), `BUILDING_NOT_FINISHED`, `BUILDING_QUEUE_NOT_ACTIVE` y `BUILDING_LEVEL_MISMATCH`; la
concesión de niveles; el incremento de `fields_used`; la ruta de demolición; y todas las firmas,
volatilidad, `SECURITY` y `search_path` (los cuerpos se cortan de `pg_get_functiondef()`). Ninguna
de las dos funciones gana `EXECUTE` de cliente: siguen siendo internas.

Verificado por `supabase/tests/stuck_building_research_queue_regression.sql` (21 aserciones) y
`docs/audits/BUILDING_RESEARCH_STUCK_STATE_2026-10-01.md`.

---
# ECONOMY — LA GRAN IMPLOSIÓN

> **Sweep 2026-10-02: `NO OBJECTIVE ECONOMY GAP FOUND`** (0 líneas de código). Evidencia, candidatos
> descartados y decisiones de producto pendientes: `docs/audits/ECONOMY_GAP_SWEEP_2026-10-02.md`.
> En particular: `get_economic_sustainability_check` no tiene consumidor pero **no es gap** —
> `can_start_building` ya devuelve el mismo veredicto y motivo.

> Durable knowledge for resources, production, costs, storage and temporal settlement.
> Operational status lives in [`../PROJECT_CONTEXT_PROMPT.md`](../PROJECT_CONTEXT_PROMPT.md);
> the functional map lives in [`README_FUNCTIONAL_AUDIT.md`](README_FUNCTIONAL_AUDIT.md).

## Layer classification (keep this distinction explicit)

```text
AUTHORITATIVE  the engine path that actually produces/persists game state
PROJECTION     read-only helpers that estimate a future state; never the source of truth
LEGACY         older entry points kept for internal compatibility; do not use for new work
BROKEN         deployed but raising at runtime, with no consumers
```

## Authoritative surface

| Function | Role | Notes |
|---|---|---|
| `calculate_planet_production(planet)` | production per hour (metal/crystal/deuterium/energy) | universe rates × item bonuses × lifeform bonuses × **energy factor** (`LEAST(1, energy_production/consumption)`); energy output includes **Energy Technology** at `base × (1 + 0.05 × level)`; mined output includes **Plasma Technology** at `metal ×1.01 · crystal ×1.0066 · deuterium ×1.0033` per level (`energy` untouched) |
| `calculate_planet_storage(planet)` | storage capacities | uses `universes.storage_multiplier` |
| `update_planet_resources_until(planet, until)` | public temporal wrapper | settles resources **and** completes due building/research events |
| `update_planet_resources_until_raw(planet, until)` | settlement without event walking | used by `complete_building` to avoid recursive processing; raises `INVALID_RESOURCE_TIMESTAMP` when `until < last_calculated_at` |
| `process_planet_tick(planet)` | authoritative tick | locks planet, settles resources, completes due queue events |
| `sync_current_planet_resources(player, planet, until)` | client-facing settlement | SECURITY DEFINER; used by the frontend when opening Buildings |
| `calculate_universe_rates(universe)` | economy/production/building/research/fleet/expedition/lifeform rates | `base × evolution` (no hidden sqrt/cuberoot dampening) |
| `calculate_universe_evolution_rate(universe)` | E multiplier | consumed by rates, building time (√E) and fleet time (∛E) |
| `get_planet_economic_rates(planet)` | wrapper of `calculate_universe_rates` | — |
| `calculate_planet_production_snapshot` / `calculate_virtual_production` | deterministic variants | projection-style: no energy factor, no lifeform/item bonuses |

## Costs and times (authoritative per domain)

```text
buildings : calculate_building_cost(id, level) = base × cost_factor^(level-1)
            calculate_building_time(id, level, universe) = base_time × time_factor^(level-1) ÷ (building_speed × √E)
            calculate_building_energy_consumption(id, level)
research  : calculate_research_cost / calculate_research_time
ships     : calculate_ship_cost / calculate_ship_build_time
defense   : calculate_defense_cost / calculate_defense_build_time
fleet     : calculate_fleet_fuel_for_distance(distance, ship, qty) + travel time
            distance model: inter-galaxy 20000/unit · inter-system 2700+95/unit · inter-position 1000+5/unit · same 5
```

## Multipliers

```text
The `universes` table holds the per-universe parameters:
  economy_speed · production_speed · building_speed · research_speed · fleet_speed · expedition_speed ·
  lifeform_speed · resource_multiplier · storage_multiplier · fleet_debris_percentage ·
  defense_debris_percentage · ai_planet_density_target/tolerance · system_expansion_base_seconds/
  curve_exponent · special_galaxy_* · galaxy_roll_probability/interval_seconds
The evolution multiplier is applied AFTER the classic modifiers (calculate_universe_rates).

Energy Technology is an LGI gameplay rule, not the OGameX Fusion Reactor formula:
`calculate_planet_production` reads the owning planet player's `energy_technology` through
`get_player_research_level` and applies the +5% per level multiplier exactly once to the generated
energy before the existing energy-balance factor. The resulting energy therefore affects resource
production only through the existing energy pipeline; it does not directly multiply metal, crystal,
or deuterium.

Regression coverage is defined in `supabase/tests/energy_technology_production.sql`: it exercises
levels 0, 1, 10 and 20, single application, owner routing across two players, level-0 production
preservation and that `calculate_planet_energy_balance` passes the boosted production through
exactly once. **Executed LIVE 2026-09-23: 7/7 PASS, zero residue**, applied as the server-versioned
migration `20260923141520_apply_energy_technology_to_energy_output` (SECURITY INVOKER, one overload,
ACL and result signature unchanged, LF body preserved).

Plasma Technology is an LGI gameplay rule sourced from the classic reference rule that already lives
in this repository (`template/investigaciones.txt`: "1% / 0,66% / 0,33% por nivel") and consistent
with LGI's OGame-classic plasma data (cost 2000/4000/1000 with factor 2, plasma_turret 3000/300/10000,
bomber requiring plasma 5). `calculate_planet_production` reads the owning planet player's
`plasma_technology` through `get_player_research_level` (COALESCE -> 0, plasma 0 = no row at all) and
applies, exactly once and after the existing energy factor (order is immaterial: the energy factor does
not depend on plasma):
  metal     : production × (1 + 0.01   × level)
  crystal   : production × (1 + 0.0066 × level)
  deuterium : production × (1 + 0.0033 × level)
  energy    : unchanged — Energy Technology remains the only energy-production modifier
No rounding is introduced for metal/crystal/deuterium (they are never floored), so level 0 keeps the
previous production byte-identical. This is deliberately NOT the Energy Technology decision: different
formula, different resources, no floor.

Regression coverage: `supabase/tests/plasma_technology_production.sql` — **12/12 PASS LIVE 2026-09-23,
zero residue** (levels 0/1/5/20 per resource, single application, owner isolation, no-floor proof,
energy untouched, energy_factor coexistence with factor < 1). Applied as the server-versioned migration
`20260923192800_apply_plasma_technology_to_resource_production` (SECURITY INVOKER, one overload, ACL and
result signature unchanged, LF body preserved).
```

## Projection helpers (no consumers — do not wire them into the UI)

```text
project_building_production(planet, building)
  mixes the authoritative current value (calculate_planet_production) with a bare formula for the target
  value (no item/lifeform bonuses, no energy factor, bare energy for solar_plant) → can overstate a level-up.

calculate_building_production_delta(planet, building)   ← REPAIRED 2026-09-26 / INTERNAL ONLY
  It selected `r.economy_rate` / `r.production_rate`, but calculate_universe_rates() returns `economy` /
  `production`, so every call raised ERROR: column r.economy_rate does not exist.
  Migration `20260926082127` replaced the two wrong column names and closed its client EXECUTE: the helper is
  SECURITY INVOKER and reads `public.universes`, which has no SELECT grant for anon/authenticated, so that
  surface was structurally unusable (same reason `research_action_candidates` was retired). EXECUTE is now
  `postgres`/`service_role` only. It remains a gross projection (universe rates applied, energy not rate
  scaled, no Energy Technology / lifeform / item bonus and no energy-balance factor); never use it as a
  production oracle — `calculate_planet_production` is the only authority.
  Certified by `supabase/tests/building_production_delta_contract.sql` (10/10 PASS, LIVE 2026-09-26).
```

## Legacy surface

```text
update_planet_resources(planet)   → COMMENT: "Legacy resource updater retained for internal compatibility;
                                     authoritative callers must use process_planet_tick/update_planet_resources_until."
process_planet_tick_local(planet) → local shortcut; the evolution document records that the heartbeat must
                                     route through the complete planet tick path.
project_planet_resources / evaluate_action_at_time / inspect_* → read-only projections.
```

## Temporal semantics

```text
planet_resources.last_calculated_at is the settlement watermark.
Settlement is interval-based: production accrues as (per_hour × elapsed/3600) capped by storage capacity;
energy is a balance value, not a produced resource.
The evolution multiplier is applied over the evolution-weighted seconds between two timestamps
(calculate_universe_evolution_production_seconds), so a rate change during downtime is honoured.
```

## Access restriction affecting the client

```text
public.universes has a public RLS SELECT policy for anon/authenticated but NO table GRANT SELECT, so
calculate_universe_rates() / calculate_planet_production() / calculate_building_time() are NOT callable
from the browser (verified live: "permission denied for table universes"). Build/research/ship/defense
actions are unaffected because their RPCs are SECURITY DEFINER. Consequence (CLOSED 2026-09-27): the UI could only show the definition's "TIEMPO BASE" and the player never saw
production, energy or storage. Fixed by two owner-scoped DEFINER read contracts that DELEGATE in these helpers,
without granting `universes` to any role (see "Own-planet economy read contracts" below).
```

## Own-planet economy read contracts (2026-09-27)

Medido LIVE como el rol `authenticated` (no inferido): `calculate_planet_production`,
`calculate_planet_energy_balance`, `calculate_building_time`, `calculate_research_time`,
`calculate_ship_build_time`, `get_planet_economic_rates` y `get_planet_rate_snapshot` responden
`permission denied for table universes` — son SECURITY **INVOKER** y `universes` no tiene grant de tabla. En
cambio `can_start_research` / `can_build_ship` / `can_build_defense` / `can_start_demolition` SÍ devuelven su
tiempo ya calculado, porque son DEFINER: la vista de Edificios era la única que sólo podía enseñar el tiempo
base de la definición.

```text
20260927035324_planet_economy_read_contracts   (LIVE, migración única; ledger == nombre del fichero)
  get_planet_economy_overview(planet)   producción/h (calculate_planet_production), balance de energía/h
                                        (calculate_planet_energy_balance) y capacidades de almacén
                                        (calculate_planet_storage) del planeta PROPIO. Una fila; 0 filas si
                                        no hay sesión, no hay jugador o el planeta es ajeno/destruido.
  get_planet_building_preview(planet)   por definición de edificio: current_level, target_level (el MISMO que
                                        declara evaluate_building_start_internal, del que can_start_building es
                                        el contrato cliente), duration_seconds REAL y energy_delta_per_hour.
                                        La duración se compone exactamente como la cobra start_building:
                                        round(calculate_building_time(edificio, nivel_objetivo, universo) /
                                             (1 + bonus_activo_de_objeto building_speed_percent / 100), 4)
ACL      ambas: EXECUTE authenticated + service_role, nunca anon, nunca PUBLIC.
NO se abrió `universes` (la restricción de arriba sigue vigente y la fixture lo comprueba llamando a los
helpers directamente como `authenticated`: siguen denegados).
```

Decisiones registradas:

* **Energía = información, nunca puerta.** `start_building` y `evaluate_building_start_internal` no mencionan
  energía en ninguna rama (verificado sobre `prosrc`), así que LGI NO bloquea la construcción por energía; el
  contrato la expone como número y no se inventó ninguna regla de bloqueo.
  *(Esta afirmación es la regla histórica. Desde 2026-10-01 tiene UNA excepción deliberada y más específica,
  documentada más abajo: el pre-flight de autosostenibilidad. La energía sigue sin ser una puerta de
  construcción; lo único que puede rechazarse es la acción que colapsa la producción a cero.)*
* **Sin segundo oráculo.** El nivel objetivo viene del oráculo certificado y la energía/h del helper
  certificado; la fixture lo comprueba fila a fila (`target_level` == `can_start_building`, `energy_delta` ==
  `calculate_building_energy_delta`, `duración` == composición autoritativa) — incluido el caso con un objeto
  `building_boost_10` activo, donde la previsión se acorta (=/1.10) exactamente como la obra real.
* **UI** (`src/App.tsx`): la tarjeta de Edificios muestra `TIEMPO` real (y `ENERGÍA/h` del siguiente nivel); el
  resumen del cuerpo activo muestra producción/h por recurso, balance de energía/h y `ALMACÉN M/C/D` (el
  asentamiento recorta en la capacidad, así que verla evita perder producción sin aviso).
* **No cableado**: `project_building_production`, `project_planet_resources`, `evaluate_action_at_time` y
  `inspect_*` siguen prohibidos (sección anterior). Los rates del universo (`get_planet_economic_rates`)
  siguen bloqueados a propósito: no forman parte de este contrato.

Certificado por `supabase/tests/planet_economy_read_contracts.sql` — **15 PASS + 2 INFO, LIVE 2026-09-27,
ROLLBACK, residuo 0** (ACL; sin sesión; planeta propio; igualdad exacta con los tres helpers certificados;
duración/target_level/energía contra sus autoridades; bonus de objeto; planeta ajeno → 0 filas sin excepción,
ni siquiera cuando el helper delegado levantaría `PLAYER_NOT_OWNED`; y los helpers directos siguen denegados
para el cliente).

## Related documents

- [`README_FUNCTIONAL_AUDIT.md`](README_FUNCTIONAL_AUDIT.md) — domain map, gaps and test coverage
- [`README_UNIVERSE_EVOLUTION.md`](README_UNIVERSE_EVOLUTION.md) — E(t), scaling exponents and expansion
- [`README_GAME_ENGINE_AUDIT.md`](README_GAME_ENGINE_AUDIT.md) — construction audit and its guarantees
- [`../UNIVERSE_RATE_AND_FLEET_ENGINE_MONITOR.md`](../UNIVERSE_RATE_AND_FLEET_ENGINE_MONITOR.md) — canonical scaling and fleet-time audit

## Queue cancellation contract (2026-09-26)

`building_queue` and `research_queue` admit `CANCELLED` since the original schema and **no function ever wrote
it** (recorded gap). Migration `20260926082120` added the two RPCs; `20260926082529` fixed an OUT-parameter /
column ambiguity (`planet_id`) that the first version carried. Both are LIVE and certified by
`supabase/tests/queue_cancellation.sql` (13 PASS + 1 INFO, LIVE 2026-09-26).

```text
cancel_building(queue_id)   SECURITY DEFINER · EXECUTE: authenticated, service_role (never anon/PUBLIC)
cancel_research(queue_id)   SECURITY DEFINER · EXECUTE: authenticated, service_role (never anon/PUBLIC)
returns (queue_id, planet_id, [player_id,] building_id|research_id, target_level,
         refund_metal, refund_crystal, refund_deuterium, status = 'CANCELLED')
```

Refund policy — taken from OGameX, not invented (`BuildingQueueService::cancel()`, commit `7c420bad…`):

* OGameX refunds **exactly the price stored on the cancelled queue row** and only when the item had already
  started (`if ($queue_item->building === 1) { $planet->addResources(...) }`) — 100 %, no penalty, no partial
  salvage, no Dark Matter.
* LGI deducts at `start_*` time and stores no price, so the refund is **recomputed with the same certified
  cost function the charge used** (`calculate_building_cost` / `calculate_research_cost` at the row's stored
  `target_level`): refund == charge by construction, for every level, with no second price model.
* The refund is credited to the planet that was charged (`research_queue.planet_id` for research) with the
  same "add and let the global storage rule apply" convention as fleet-cargo delivery.

Decided semantics (explicit, per the mission's cancellation checklist):

```text
what is cancelled     the single active item of the queue (LGI holds one active item per queue/planet)
when                  status BUILDING / RESEARCHING and the row is not COMPLETED/CANCELLED
what is refunded      100 % of the charged metal/crystal/deuterium (no time refund, no Dark Matter)
when                  atomically with the status change (one SECURITY DEFINER transaction)
queue afterwards      free: the item is CANCELLED (never deleted, OGameX parity) and a new start is allowed
### Cancel UI consumer — IMPLEMENTED (2026-09-27)

Both RPCs were certified and **unusable from the browser**: no file in `src/` ever called them (the only match
for "cancel" in the frontend was a JS `cancelled` flag). `src/App.tsx` now renders a `CANCELAR` control on the
row of the active queue of the EDIFICIOS and INVESTIGACIÓN views and calls the certified contract with the queue
id only.

```text
what the UI sends    p_queue_id (one argument); never a player or planet id — ownership stays server-side
what the UI shows    the refund the contract RETURNS (metal/crystal/deuterium); no price is recomputed in React
when it is offered   status BUILDING (buildings) / RESEARCHING (research) — the only non-terminal status each
                     queue admits (`building_queue_status_check` / `research_queue_status_check`), so the
                     control is offered exactly when the contract accepts it
hangar / defensa     never offered: OGameX `UnitQueueService` states that unit-queue objects cannot be canceled
after the call       refreshPlanet() + loadView(): resources, the queue and every definition are re-read; the
                     client keeps no bookkeeping of levels or prices
```

Client-facing regression: `supabase/tests/queue_cancellation_ui_contract.sql` (**13 PASS + 2 INFO, LIVE
2026-09-27, rolled back, residue 0**). It pins the call shape (single `uuid` argument, `authenticated` EXECUTE
and never `anon`), the **exact return column list** declared in `src/lib/database.types.ts`, the UI precondition
against the schema's `status` CHECK, the refusal of `COMPLETED`/`CANCELLED` with zero mutation, the exact refund
of both accepted statuses (`metal_mine` L1 charge 60/15/0 → refund 60/15/0; `energy_technology` L1 0/800/400) and
that a **demolition row** (`building_queue.is_downgrade`, readable by the owner) refunds the DEMOLITION price
(90) and not the upgrade price (60) at ion 0.

Two facts measured while certifying it, recorded so they are not rediscovered:

* **The authoritative tick clamps.** A resource baseline at the storage cap is clamped by the tick that runs
  inside the cancel (`calculate_planet_storage` returns 100 000 for all three resources on the homeworld), so a
  fixture asserting exact refund deltas must derive its baseline from the storage contract instead of hardcoding
  a "large" number. This is the tick's normal settlement rule, not a cancellation rule.
* **The already-due race is atomic.** Pressing CANCELAR exactly when the item is due is refused with
  `BUILDING_QUEUE_NOT_CANCELLABLE: COMPLETED`, and the refusal unwinds the tick that had just completed it:
  status stays `BUILDING`, the level is not granted and nothing is refunded. The item completes on the next
  settlement, so a row can never be refunded **and** granted.

Observation (no change made): `building_queue_status_check` admits `BUILDING`/`COMPLETED`/`CANCELLED` only, so
the buildings view's `status IN (BUILDING, QUEUED)` filter is inert — a `QUEUED` row cannot exist.

## FUSION PLANT + CRAWLER — IMPLEMENTED (2026-09-26)

Both mechanics are LIVE. They touch the certified production function, so the integration is documented here in full.

```text
Migrations  20260926140000_fusion_plant_and_crawler_definitions   (both objects + prerequisite wiring + kind data)
            20260926140100_fusion_crawler_ship_kind_gate          (single server-side ship-kind authority)
            20260926140200_fusion_crawler_economy_integration      (calculate_planet_production patch)
Tests       supabase/tests/fusion_and_crawler.sql — 10 PASS + 1 INFO (LIVE, rolled back)

FUSION PLANT  900 / 360 / 180, cost factor 1.8, planet only; requirements deuterium_synthesizer 5 (building) and
              energy_technology 3 (research, via the generic building→research table).
  energy      OGameX `BuildingObjects` id 12: `30·L·(1.05 + 0.01·energy_technology)^L`, NOT speed-scaled, plus LGI's
              existing energy-percent bonus. Verified exactly: level 5 with energy_technology 3 adds 220 energy.
  fuel        OGameX: `−10·L·1.1^L`, multiplied by the universe speed like mine output. LGI expresses it as
              `10·L·1.1^L × economy × production` inside the per-hour rate because
              `update_planet_resources_until_raw` divides by that combined rate to recover the base per hour — the
              settlement therefore burns exactly `10·L·1.1^L` per universe hour (verified to 1e-4).
  fuel policy the reactor runs only while the planet holds deuterium. Official OGame stops the reactor without fuel;
              OGameX's own code applies its deuterium formula unconditionally, which would let an empty tank keep
              producing energy. LGI implements the OGame rule (documented adaptation, not an invention) so no free
              energy can exist: with deuterium = 0 the energy delta and the fuel burn are both exactly 0.
  no regression a planet without the building produces exactly what it produced before (verified by the fixture:
              the new terms are inert).

CRAWLER  2 000 / 2 000 / 1 000, ship type `civil`, planet only; requirements shipyard 4 (building) +
         combustion_drive 4, armour_technology 4, laser_technology 4 (research). Stationary: attack 1, shield 1,
         hull 4 000, cargo 0, fuel 0, speed 0 (OGameX `CivilShipObjects` id 217).
  bonus       `floor(mine_output × 0.0002 × effective_units)` per resource, applied to the MINE term
              (`+0.02 %` per unit). LGI applies it inside its multiplicative chain instead of OGameX's additive
              production index; the ordering is the only adaptation and it is verified by ratio in the fixture
              (100 crawlers → ×1.019277, 1000 → ×1.047550).
  cap         `effective_units = min(owned, (metal_mine + crystal_mine + deuterium_synthesizer) × 8)` (OGameX
              `getMaxUsableCrawlers`). Verified: 1000 crawlers produce exactly the 240-unit bonus.
  energy      50 per effective unit (OGameX `getCrawlerEnergyConsumption` at 100 % overload) added to the planet's
              energy CONSUMPTION, so an energy shortage throttles production through the existing production factor
              (verified: 20 crawlers on a low-energy planet cut metal output below 60 %).
  not modelled the crawler OVERLOAD percentage (0–150 %, a player setting in OGame) does not exist in LGI; 100 % is
              the OGame default and is what the formulas above assume.

KIND AUTHORITY (single, server-side)
  `building_definitions.valid_kinds` + `trg_enforce_building_kind_and_research` (buildings)
  `ship_definitions.valid_kinds`     + `trg_enforce_ship_kind`                (ships)
  Aligned with OGameX `valid_planet_types` (an EMPTY list means both kinds — `ObjectService::isObjectValidForPlanetType`):
  mines, solar plant and fusion plant are planet-only; the crawler is planet-only; lunar base, sensor phalanx and
  jump gate are moon-only; storages and the shipyard are legal on both. Defensive structures declare nothing in
  OGameX, so no defence is moon-banned and no gate is needed for them.
```

Still open (recorded, not invented)

```text
* Fusion plant's research_lab gate (OGameX requires a research laboratory at high levels) — LGI has no laboratory
  building; the OGameX fusion requirements that ARE expressible (deuterium_synthesizer 5 + energy_technology 3) are
  implemented.
* Crawler overload percentage and the Collector-class crawler multiplier — no character classes in LGI.
* The reuse/recycling of crawlers (OGame refunds 70 % when a crawler is sold) — no such mechanic exists in LGI.
```

COMPLETED             terminal: refused, level stays granted, nothing refunded
already-due item      the authoritative tick completes it inside the call, so the row stops being cancellable
                      and the refusal unwinds the tick with it: the item stays active, the level is not
                      granted, nothing is refunded, and the next successful settlement grants the level
                      exactly once
ownership             auth.uid() → players.user_id → planets.player_id; a foreign caller gets
                      PLANET_NOT_FOUND_OR_NOT_OWNED (building) / PLAYER_NOT_OWNED (research) and nothing is
                      written. No client-supplied player/planet id, no first-player/guest heuristic.
atomicity             refund + status in one transaction; a rejected call raises before any write, so a retry
                      can never duplicate or double-refund
shipyard / defence    deliberately NOT cancellable: OGameX states "unit queue objects cannot be canceled",
                      so those two queues keep their unreachable CANCELLED value (OGameX parity, not a gap)
```

```text
Known consequence to remember: because a refusal happens inside the same statement, the tick work performed
by the refused call (completing a due item, settling resources) is rolled back too. That is intentional: a
refused cancel must not be able to move resources or levels.
```

## Item bonuses are now actually applied (2026-09-25)


Expedition items were rewarded into `player_expedition_items` but could never be activated, because
`get_active_expedition_item_effect` reads only `expedition_item_uses` and the only function able to create
those rows (`use_expedition_item`) had no ownership gate and no client EXECUTE grant. As a result every item
bonus read by the economy was structurally `0`: `production_percent` (minas M/C/D), `storage_percent`
(capacidad de almacén) and — outside this document — `research_speed_percent`, `fleet_speed_percent`,
`building_speed_percent` and `expedition_slots`.

`20260925202506` hardened `use_expedition_item` (`auth.uid()` → `players.user_id` → player, optional planet
ownership, `FOR UPDATE` on the stack) and granted it to `authenticated`, so the pre-existing definitions now
take effect for their duration and expire by `expires_at`. Capacity and storage item bonuses are visible in
`calculate_planet_storage` / `calculate_planet_production` and are covered by
`supabase/tests/expedition_items_and_slots.sql` (storage +25 % and production +10 % asserted against the
authoritative functions). No new effect or formula was introduced.

## Building demolition (downgrade) — 2026-09-26

`20260926160000_building_demolition.sql` implements the OGameX downgrade contract (source:
`BuildingQueueService::addDowngrade`/`start`, `ObjectService::getObjectDowngradePrice`/`canDowngradeBuilding`,
`PlanetService::getBuildingDowngradeTime`, `BuildingQueue.is_downgrade`):

* `start_demolition(player, planet, building)` charges the **construction price of the level being removed**
  reduced by 4 % per `ion_technology` level (`floor` per resource, never negative) and queues one item with
  `building_queue.is_downgrade = true` and `target_level = current_level - 1`. `target_level >= 0` is now legal,
  so the last level can be removed; the `planet_buildings` row is kept at level 0 because every reader already
  aggregates with `COALESCE`/`MAX(level)` and the UPDATE keeps `trg_sync_moon_field_capacity` firing.
* Duration is the construction formula evaluated at the level being removed (OGameX
  `getBuildingDowngradeTime`), with a 1-second floor.
* `can_start_demolition` is the read contract (same shape as `can_start_building`, plus the ion level, the cost
  and the duration). Preview and dispatch both read the single authority `inspect_demolition`, so they cannot
  drift.
* Guards are data-driven, not hardcoded: a **present** building that still requires that level
  (`building_prerequisites`), an **active research** that requires it (`research_building_prerequisites`), an
  **active ship/defense order** that requires it (`ship_prerequisites` / `defense_prerequisites`) and a busy
  building queue. Reason codes: `DEMOLITION_LEVEL_ZERO`, `DEMOLITION_BLOCKED_BY_DEPENDENTS`,
  `DEMOLITION_BLOCKED_BY_ACTIVE_RESEARCH`, `DEMOLITION_BLOCKED_BY_ACTIVE_UNIT_QUEUE`,
  `BUILDING_QUEUE_ALREADY_ACTIVE`, `INSUFFICIENT_RESOURCES`, `PLANET_NOT_FOUND_OR_NOT_OWNED`,
  `PLAYER_NOT_OWNED_BY_AUTH_USER`.
* `complete_building` was patched (the upgrade path keeps `target = current + 1` and `fields_used + 1`) to
  settle a downgrade and release one field; `cancel_building` was patched to refund exactly what the demolition
  charged.
* ACL: `start_demolition` / `can_start_demolition` / `inspect_demolition` are `authenticated` + `service_role`
  only (no anon bypass); `calculate_building_demolition_cost` is a pure helper granted like the other
  `calculate_*` functions. The AI service actor needs no new API: it uses the certified `lgi.ai_worker` /
  `lgi.ai_player` contract (`ai_actor_begin` / `ai_actor_end`).

Fixture `supabase/tests/building_demolition.sql`: **18/18 PASS LIVE**, transactional with `ROLLBACK` and zero
residue. It also re-asserts the certified upgrade path (build → complete → field consumed) and the moon field
re-sync so the patch cannot silently break either.

Documented deviations from OGameX: the demolition is charged, never refunded (OGameX behaviour), the floor is
applied per resource, and the OGameX special cases (research_lab / missile_silo / terraformer) have no LGI
equivalent and were replaced by the data-driven guards above.

## can_start_building ownership gate (2026-09-26)

`20260926240000_harden_can_start_building_ownership.sql` closes the finding P2 of the integral Supabase↔frontend
audit. Reproduced LIVE before the fix, with a real planet:

```text
owner                 -> allowed=t reason=OK level=2 cost_metal=122.88 available_metal=89075.2
foreign authenticated -> allowed=t reason=OK level=0 cost_metal=48     available_metal=NULL   <- oracle
anonymous (claims {}) -> allowed=t reason=OK level=0                                          <- oracle
```

The function was `SECURITY INVOKER` with **no identity check**, so any actor (even an anonymous one) received a
positive decision about somebody else's planet: `planets` is public for the galaxy view, while the deciding reads
(`planet_buildings`, `planet_resources`) are RLS-filtered — the answer itself became an oracle.

**Fix:** the certified name is now `SECURITY DEFINER` with the same inline gate already used by
`inspect_demolition`, `can_build_defense` and `can_start_research`:

```text
1. AUTHENTICATION   auth.uid() is null -> allowed only for the declared AI actor (is_ai_actor_target)
2. OWNERSHIP        players.user_id = auth.uid() for the requested player
3. EVALUATION       the original logic, unchanged
```

* Refusals are **returned as a blocked row**, never raised: `AUTHENTICATION_REQUIRED` / `PLAYER_NOT_OWNED`, with every
  numeric/boolean column zeroed. The 13-column contract, the shape `App.tsx` reads (`(i ?? [])[0]`) and the reason
  codes the UI renders are untouched, so **no frontend change was needed**.
* The evaluation logic is **not reimplemented**: it is preserved verbatim as the internal
  `evaluate_building_start_internal` (ACL `service_role` only; client roles get *permission denied*) and the
  certified name delegates to it.
* `enforce_player_write_access` and the AI contract (`ai_decide_and_act` → `can_start_building` inside
  `ai_actor_begin`/`ai_actor_end`) are untouched: no bypass was added, the declared AI path is the existing one.

Tests: `supabase/tests/can_start_building_ownership.sql` — **12/12 PASS, transactional (ROLLBACK, zero residue)**:
owner keeps the authoritative answer; foreign actor blocked with no leaked condition; anonymous blocked; the owner can
still `start_building`; a foreign actor still cannot; the declared AI actor keeps a business answer (identical to the
preserved evaluator); an AI actor aiming at another player is blocked; the internal evaluator is unreachable from the
client; `can_start_building` is `DEFINER` with `anon`/`authenticated`/`service_role` EXECUTE; `enforce_player_write_access`
still guards 6 protected tables; and `can_start_demolition` (untouched sibling) still refuses foreign actors.

## Planet resources / storage read contracts — GAP A closeout (2026-09-26)

`get_current_planet_resources(planet)` and `calculate_planet_storage(planet)` are the two read contracts that feed the
certified availability oracles (`can_build_ship`, `can_build_defense`) and the resource projection helpers. Both were
**client-callable** (`PUBLIC EXECUTE`) while `SECURITY INVOKER`, and both depend on `universes`, which has **no client
SELECT grant** by design (`20260922050734_shipyard_availability_contract_definer`, post-condition "universes must not
be granted to client roles"). Every client call therefore aborted with an internal schema error instead of a decision:

```text
authenticated -> calculate_planet_storage(planet)
  ERROR 42501: permission denied for table universes    (line 10: planets JOIN universes)
authenticated -> get_current_planet_resources(planet)
  ERROR 42501: permission denied for table universes
    (get_current_planet_resources -> calculate_planet_production -> calculate_universe_rates line 13 -> universes)
```

Reproduced LIVE as the DEV authenticated actor before the fix.

**Fix (`20260926280000_fix_planet_resources_and_storage_read_contract`):** both become bounded `SECURITY DEFINER`
contracts (owner `postgres`, pinned `search_path`) with the same inline gate as their siblings:

```text
auth.uid() IS NOT NULL AND the planet is not owned by auth.uid() -> RAISE PLAYER_NOT_OWNED
auth.uid() IS NULL (service / worker context)                   -> gate skipped, behaviour unchanged
ACL                                                             -> authenticated + service_role (anon loses EXECUTE)
```

* **No formula, cost, production, capacity, rounding or projection was touched.** The bodies are patched by a
  guarded, byte-preserving substitution — the anchor must match exactly once, `replace(new, gate, '') = old` is
  asserted, and only then is the function replaced (the technique already used by
  `20260923095315_fix_participant_settlement_replay`). Return shape, volatility (`STABLE`) and error texts are the
  certified ones, and the same invariants are re-asserted by the migration's own post-condition block.
* `public.universes` keeps **no** client grant, and `calculate_universe_rates` / `calculate_planet_production` are
  untouched — so no foreign-planet oracle is created by the change.
* The gate deliberately does **not** reproduce the flagged `is_guest = true` branch of the `planet_resources` RLS
  policy (guest bypasses stay closed).

Tests: `supabase/tests/planet_resources_storage_read_contract.sql` — **10 PASS + 1 INFO, LIVE 2026-09-26,
transactional (`ROLLBACK`, zero residue)**: the owner receives the storage capacities (compared against an
independently recomputed expectation) and the full resource payload; the client answer is identical to the internal
computation (no drift in formula, rounding or projection); a foreign actor raises `PLAYER_NOT_OWNED` on both
contracts; `anon` is refused by the ACL; the service/worker context still reads a FOREIGN planet
(`999999/888888/777777`), which the fleet, combat, espionage and merchant settlement workers require; the contracts
are `DEFINER`, single-signature, pinned-`search_path` and gated; `universes` carries no client grant;
`calculate_universe_rates` stays `INVOKER`.

Residual as of 2026-09-26 (recorded, not fixed then): `calculate_building_time`, `calculate_ship_build_time`,
`calculate_defense_build_time`, `calculate_research_time`, `calculate_lifeform_*_time`,
`calculate_universe_evolution_*` and `calculate_planet_production` stayed `SECURITY INVOKER` with an explicit
`authenticated` EXECUTE (PUBLIC and `anon` had already been closed by `20260926300000`) and still raised the same
`42501` when a client called them directly — the deferred P3 hygiene declared by `20260922050734`, with no frontend
caller.

### P3 ACL cleanup — closed 2026-09-27 (`20260927130100_acl_p3_revoke_authenticated_invoker_helpers`)

The residual list above is now CLOSED. `20260926300000` had re-granted `authenticated` on those helpers because
PUBLIC was their only source; this migration revoked it on exactly that audited list:

```text
calculate_building_time(text,integer,uuid)                     calculate_lifeform_building_time(uuid,text,integer)
calculate_ship_build_time(uuid,text)                           calculate_lifeform_research_time(uuid,text,integer)
calculate_defense_build_time(uuid,text)                        calculate_universe_evolution_population_seconds(uuid,ts,ts)
calculate_research_time(uuid,text,integer)   [legacy INVOKER] calculate_universe_evolution_production_seconds(uuid,ts,ts)
calculate_research_time(text,integer,uuid)   [legacy INVOKER] calculate_universe_evolution_rate(uuid)
calculate_planet_production(uuid)                              calculate_universe_evolution_rate_at(uuid,ts)
```

Evidence gathered BEFORE revoking (measured LIVE as the DEV `authenticated` actor, recorded in the commit-style
review of that session):

* every one of the twelve FAILS for a client today — being SECURITY INVOKER they evaluate `public.universes`, which
  has no client SELECT grant by design → `permission denied for table universes`; the two lifeform helpers cannot even
  resolve their definition id through their client surface;
* no frontend/worker caller exists (`src/**`, `worker/**`, `scripts/**`); the only repository reference is the
  generated `src/lib/database.types.ts`, and `scripts/verify-buildings.mjs` probes `calculate_planet_production` and
  SKIPS on error by design;
* their LIVE callers are SECURITY DEFINER (privilege checked against the owner `postgres`) or INVOKER functions that
  are already unreachable (`simulate_*`, `evaluate_building_chain`, `calculate_universe_rates`) or that fail today for
  the same reason (`project_planet_resources`, `calculate_planet_energy_balance`) — those keep their own grant, so no
  working client path is broken by the revoke;
* no fixture asserts `authenticated` EXECUTE on any of the twelve (verified across `supabase/tests/**`).

NOT touched, deliberately: the 32-name client allow-list; `calculate_building_cost`, `project_planet_resources` and
`evaluate_action_at_time` (protected by `acl_surface_p3.sql`); every DEFINER contract (internal calls run as the
owner); and `calculate_planet_production_snapshot`, which WORKS for `authenticated` (measured) and is not in the list.

After the cleanup: `authenticated`-executable functions outside the allow-list 121 → 109, `anon`-reachable outside
the allow-list stays 0, ACL-level PUBLIC grants stay 0. `supabase/tests/acl_surface_p3.sql` was updated to the real
state (assertion 8 count + a new assertion 8b over the twelve signatures) — **10 PASS + 1 INFO, LIVE, ROLLBACK**.

Known, unchanged: `project_planet_resources` and `evaluate_action_at_time` keep `authenticated` (the certified P3
fixture protects them) even though they fail today for the `universes` / engine-view reason; that is a separate
read-contract question, not an ACL one, and fixing it would be a new contract design.

### P3 ACL — third pass: the DEAD client-reachable helpers (2026-09-27, `20260927140000`)

The paragraph above is superseded by measurement. An autonomous sweep probed every read contract the frontend
consumes as the DEV `authenticated` actor (31 OK / 3 failing) and found four helpers that are client-reachable while
EVERY possible client call can only return a permission error:

```text
get_planet_economic_rates(uuid)                    permission denied for table universes
get_planet_rate_snapshot(uuid)                     permission denied for table universes
project_planet_resources(uuid, numeric)            permission denied for function calculate_planet_production
evaluate_action_at_time(uuid, text, text, numeric) permission denied for view executable_optimization_candidates
```

`20260927140000_acl_p3_revoke_dead_client_invoker_helpers` revokes `public/anon/authenticated` on exactly those four
and keeps `service_role`: they are SECURITY INVOKER over `universes` / the engine analysis views / an engine-only
helper, no frontend, worker or script calls them (the frontend inventory was re-derived from EVERY
`supabase.rpc(...)` call site, including the `start_building`/`start_research`/`start_ship`/`start_defense`
dispatches chosen through a variable that an earlier regex inventory had missed), and no SECURITY DEFINER contract
depends on the client grant (`get_planet_economic_rates` is only called by `get_planet_rate_snapshot` and the
client-unreachable `simulate_*`; `project_planet_resources` only by `evaluate_action_at_time`;
`evaluate_action_at_time` by nobody).

NOT touched: the 32-name allow-list, every UI-called contract, and the read contracts measured as WORKING
(`calculate_building_cost`, `get_current_planet_resources`, `ui_defense_queue`, `ui_universe_galaxies`,
`get_universe_ranking`, `inspect_demolition`, `get_research_network_lab_level`) — revoking a working contract would
be the generic revocation the project forbids.

`supabase/tests/acl_surface_p3.sql` was corrected in the same change: its `v_internal` list (the "internal
dispatchers the UI calls") is rebuilt from the real call sites — it wrongly contained engine helpers the UI never
calls — the baseline count is 105, and a new assertion 8c pins the four dead helpers as engine-only while asserting
that every UI-called and working read contract keeps `authenticated`. Result: **11 PASS + 1 INFO, LIVE, ROLLBACK**.

Frontend type surface: the same sweep found seven names declared in the generated `src/lib/database.types.ts` that
do NOT exist in LIVE (`calculate_expedition_time`, `calculate_fleet_fuel`, `calculate_fleet_fuel_for_distance`,
`calculate_fleet_fuel_mixed`, `calculate_fleet_time`, `get_player_fleet_speed_multiplier`, `register_guest_player`).
Five are the legacy fleet cluster that `fleet_speed_classes.sql` assertion 9 certifies as having no live consumers,
`get_player_fleet_speed_multiplier` was replaced by `calculate_mission_fleet_speed_multiplier`, and
`register_guest_player` was retired with guest mode. No caller exists (`src/**`, `worker/**`, `scripts/**`), so the
entries were pruned from the types to remove the trap of compiling against a contract that cannot be called;
`npx tsc -b` and `npm run build` stay clean.


### The gate must NOT reach the engine settle path — regression fixed 2026-09-27

`20260927120200_fix_engine_settle_storage_regression` (found while re-running the espionage certification).

```text
SYMPTOM     resolve_espionage_arrival(<foreign target>) with `request.jwt.claims` set -> ERROR P0001 PLAYER_NOT_OWNED
            at calculate_planet_storage line 18, called from update_planet_resources_until_raw line 64.
CAUSE       the gate added by 20260926280000 lives on the CLIENT contract, but an ENGINE settle path
            (`update_planet_resources_until_raw`, reached by every arrival resolution) calls that same function for
            whatever planet it is settling — the TARGET of an espionage flight belongs to the other player. The
            assumption "auth.uid() IS NULL in the worker context" holds for pg_cron workers, not for an engine path
            running inside a session that carries a JWT.
FIX         the repository's internal/client split (`can_start_building` + `evaluate_building_start_internal`):
              · `calculate_planet_storage_internal(planet)` — the computation verbatim WITHOUT the gate, DEFINER,
                pinned search_path, `service_role` only;
              · `calculate_planet_storage(planet)` — the UNCHANGED client contract: certified gate (still
                `PLAYER_NOT_OWNED`, still `pl.user_id = auth.uid()`) + delegation;
              · `update_planet_resources`, `update_planet_resources_until_raw` and `execute_expedition_merchant_trade`
                (all `authenticated = false`, i.e. never a client path) were repointed by a guarded catalogue
                substitution (anchor asserted, idempotent, refuses to drift).
PROOF       post-conditions inside the migration: ACLs unchanged, gate still present verbatim, internal helper
            gate-free, and `calculate_planet_storage(p) = calculate_planet_storage_internal(p)` for EVERY planet with
            resources. The economy is untouched (formulas, multiplier, item bonus, rounding).
EVIDENCE    the resolver settles a foreign planet with a JWT present (RETURNING + 1 report) and
            `supabase/tests/counter_espionage.sql` passes again — 13 PASS.
```

The client contracts that read the OWN planet (`get_current_planet_resources`, `get_planet_economy_overview`) keep

## Resource-panel honesty: the dead `energy` stock and the invisible storage cap — CLOSED 2026-09-29

Two presentation defects found by the economy sweep. Both are **UI-only**: no RPC, no migration, no
formula, no cost, no capacity and no ACL changed. The engine was already correct in both cases.

### A — `planet_resources.energy` is a dead column presented as a fourth resource

**Measured LIVE.** The only writers of the column are two resets:
`20260926130200_moon_creation_and_destruction.sql:231` (`energy = 0`) and
`20260926297000_ai_empire_normalization.sql:78` (`energy = default`, i.e. 0). Every INSERT hard-codes
`energy = 0`. The settlement `update_planet_resources_until_raw` **reads** `pr.energy` and returns
it, but its single UPDATE writes only `metal, crystal, deuterium, last_calculated_at, updated_at`:

```sql
update public.planet_resources pr
   set metal = v_metal, crystal = v_crystal, deuterium = v_deuterium,
       last_calculated_at = p_until, updated_at = now()
 where pr.planet_id = p_planet_id;
```

So the stock is structurally `0` forever. This document already states the authoritative semantics —
**"energy is a balance value, not a produced resource"** (§Energy), and the fusion migration proves
the engine treats it as a flow (`20260926140200:62-69` folds `v_fusion_energy` into
`v_energy_production`). Meanwhile the UI rendered it as a resource:

* `src/App.tsx` overview: `ENERGÍA  {formatNumber(resources?.energy)} · {balance}/h` — always `0`;
* the same file's header bar: a `⚡` chip showing the same dead stock;
* `src/screens/pda/PdaShell.tsx`: a `ENERGIA` tile fed `Number(resources?.energy ?? 0)` — a fourth
  resource in a device that claims to read the empire's real state.

**Fix (presentation only).** The three dead reads are gone; the authoritative figures the contract
*already returns* are what is rendered:

* overview: `ENERGÍA` now shows the server's balance, `{economy.energy_balance_per_hour}/h`, next to
  the existing `ENERGÍA PROD/CONS` row;
* header bar: the `⚡` chip is removed, leaving the three real stocks;
* PDA: the tile is `ENERGIA /H` fed `economy.energy_balance_per_hour` (prop renamed
  `resourceSummary.energy → energyBalancePerHour` so the type states the semantics).

The engine is untouched: energy is still not accumulated, still is not a spendable resource, and no
player can spend or lose it.

### B — production stops at the storage cap and nothing showed it

**The engine is correct.** `update_planet_resources_until_raw` clamps with the same capacity helper
the rest of the system uses:

```sql
select s.metal_capacity, s.crystal_capacity, s.deuterium_capacity
  into v_metal_capacity, v_crystal_capacity, v_deuterium_capacity
  from public.calculate_planet_storage_internal(p_planet_id) s;

v_metal     := least(v_metal_capacity,     greatest(0, v_metal + v_metal_produced));
v_crystal   := least(v_crystal_capacity,   greatest(0, v_crystal + v_crystal_produced));
v_deuterium := least(v_deuterium_capacity, greatest(0, v_deuterium + v_deuterium_produced));
```

**The gap was the presentation.** The panel printed `ALMACÉN M/C/D` as three bare numbers, so a bank
whose production had already stopped looked exactly like a half-full one. The player could not tell
that a mine was producing nothing. This is the same class of defect as the earlier expedition
cargo-clamp closure ("could not tell *found nothing* from *found plenty, my cargo was too small*").

**Fix (presentation only).** One new formatter, `formatStorage(stock, capacity)`, returns
` · NN%` and ` · NN% ALMACÉN LLENO` when `stock >= capacity`. Both operands were already on the
client — the stock from the `planets … planet_resources(...)` read and the capacity from the
**same** `get_planet_economy_overview` row that already feeds the `ALMACÉN` line — so the panel only
compares two server values. It derives no rule, and the authoritative clamp stays in the engine.

```text
before   METAL   1.234.567 · +30.000/h
after    METAL   1.234.567 · 82% · +30.000/h
before   METAL   1.000.000 · +30.000/h        (production already halted, indistinguishable)
after    METAL   1.000.000 · 100% ALMACÉN LLENO · +30.000/h
```

### Verification

```text
static   npx tsc -b exit 0 · npm run build exit 0 (192 modules) · git diff --check clean
backend  no migration and no RPC: the engine, the clamp, the formulas and the capacities are
         byte-identical; only src/App.tsx and src/screens/pda/PdaShell.tsx changed
regression the two affected views still render the three real stocks, the three capacities, the
         energy PROD/CONS split and the per-hour energy balance
untouched economy core, settlement, storage calculation, fusion/crawler, every cost, every queue,
         the worker and the ACL
```

### Not decided here (still product decisions, recorded not invented)

Crawler overload %, Collector-class multiplier, crawler reuse, the fusion-plant research-lab gate,
general merchant / shop / Dark Matter premium economy — unchanged from §"Still open". The fusion
fuel gate remains intentionally evaluated from the pre-settlement stock (OGameX rule), and a planet
with a fusion plant and no deuterium mining legitimately reports a **negative**
`deuterium_per_hour`; the balance itself is re-clamped with `greatest(0, …)` and the sign is
surfaced by `formatRate`.

using the gated `calculate_planet_storage`; only engine paths were repointed.

## Crawler overload 0–150 % · Demolition + Ion Technology · Queue expiry (2026-10-03)

Misión OGameX-adaptada. **OGameX = referencia de comportamiento. LGI = autoridad.** De las tres
mecánicas sólo UNA era un gap real: las otras dos ya estaban conformes y se han **certificado sin
reescribir**.

Migración: `20261004000000_crawler_overload`. Fixture: `supabase/tests/crawler_overload_demolition_queue_expiry.sql`.

### Queue expiry — ya conforme, NO reescrito

```text
Una cola vencida (time_end <= now) se COMPLETA. No se cancela por el hecho de que el jugador
volviera después de que expirara el contador. Una cola pagada/acelerada que ya alcanzó su
time_end se liquida igual que una que el jugador nunca aceleró: no existe ninguna rama
`expired -> cancel` en LGI.
```

Comprobado sobre los cuatro procesadores (`process_building_queue_for_planet`,
`process_research_queue_for_player`, `process_shipyard_queue`, `process_defense_queue`): **ninguno
menciona `cancel`**; todos comparan `finishes_at <= …` y marcan `COMPLETED`. Certificado en vivo
con las cuatro colas sembradas ya vencidas: las cuatro terminan `COMPLETED` con el resultado
aplicado, y reprocesarlas **no** vuelve a aplicar nivel ni unidades (idempotencia).

`QUEUE EXPIRED` y `PLAYER CANCELS` siguen siendo caminos distintos: la cancelación conserva su
política y su reembolso. Esta misión **no** la tocó.

### Crawler overload — el gap real, implementado

LGI tenía el crawler fijo al 100 %: `+0.02 %` de producción por crawler efectivo y `50` de energía
por crawler efectivo. **No existía ningún porcentaje configurable** (0 columnas `%overload%` en todo
el schema `public`, medido el 2026-10-02). Ahora `planets.crawler_percentage` guarda un entero
`0–150` con `DEFAULT 100`, así que **el comportamiento de todos los cuerpos no cambia**.

```text
p = porcentaje / 100
energia = 50 * p                    si p <= 1
energia = 50 * p + 50 * (p - 1)     si p > 1        (equivalente a 50 * (2p - 1))

100 % -> 50      110 % -> 60      120 % -> 70      130 % -> 80      140 % -> 90      150 % -> 100
```

Por encima del 100 % el coste crece **más rápido** que la producción: ése es el compromiso que hace
que el overload sea una decisión y no un bonus gratis.

Pipeline, sin duplicar el modificador y con la autoridad en el servidor:

```text
crawler efectivo = min(crawlers poseidos, (metal+crystal+deuterium)*8)      calculate_crawler_effective_count
        ↓
porcentaje configurado 0-150                                            planets.crawler_percentage
        ↓
multiplicador de producción (bono de crawler * p)                        calculate_planet_production
        ↓
consumo energético (50*p, o 50*(2p-1))                                   calculate_crawler_overload_energy
        ↓
economy settlement                                                       calculate_planet_energy_balance
```

* El tope **no** depende del overload: subir el overload aumenta la potencia de cada crawler, no
  cuántos son útiles.
* La sostenibilidad se integra por la ruta **ya existente**: el consumo sigue saliendo de
  `calculate_crawler_energy_consumption`, la misma que consumen `calculate_planet_energy_balance` y
  `evaluate_economic_sustainability`. **No** se creó una segunda regla.
* El splice de `calculate_planet_production` es mínimo y verificable: 3 ocurrencias de
  `0.0002 * v_crawler_effective`, y el propio bloque **aborta** si no son exactamente 3 o si
  alguno de los `replace` no encaja (evita un no-op silencioso).

**Divergencia deliberada — gating por clase NO importado.** OGameX limita el overload a la clase
*Collector* (General 100 %, Collector 150 %). **LGI no tiene Character Classes ni Lifeforms.**
Crear ese sistema sólo para el crawler habría sido inventar infraestructura cerrada, así que **no
se importa**: el rango es `0–150 %` para todos los cuerpos. No se inventó un "Collector" ficticio.

Contratos:

```text
set_planet_crawler_percentage(player, planet, percentage)   SECURITY DEFINER · 0-150 · reject fuera de rango
get_planet_crawler_status(planet)                           añade crawler_percentage y crawler_production_multiplier
calculate_crawler_overload_energy(crawlers, percentage)     fórmula pura, IMMUTABLE, cerrada al cliente
calculate_crawler_effective_count(planet)                   tope, cerrada al cliente
```

Las columnas **existentes** de `get_planet_crawler_status` no cambian de nombre, tipo ni orden; las
dos nuevas van al final. Ownership por `auth.uid() → players.user_id`; un `player_id` falsificado o
un cuerpo ajeno se rechazan **en el servidor**, no ocultando botones.

### Demolition + Ion Technology — ya conforme, NO reescrito

```text
coste de demolición = coste de construir el nivel RETIRADO
                      × (1 - 4 % × nivel de Ion Technology)
                      → floor por recurso → mínimo 0
```

Ya existía `calculate_building_demolition_cost(building, level, ion)`, y `inspect_demolition` lo
llama con el Ion real del jugador antes de que `start_demolition` cobre nada. Verificado en vivo con
`metal_mine` nivel 10 (base 2306.6015…):

| Ion | metal | % del base |
|---|---|---|
| 0 | 2306 | 100 % |
| 1 | 2214 | 96 % |
| 5 | 1845 | 80 % |
| 10 | 1383 | 60 % |
| 25 | 0 | 0 % |

Nunca negativo (comprobado de Ion 0 a 60). `calculate_building_cost` es **fraccionario**; el `floor`
por recurso es lo que produce el entero final, no un redondeo.

Coste de demolición ≠ reembolso por cancelación: son conceptos distintos y esta misión no mezcló
ni redefinió la política de cancelación.

### Verificación

```text
fixture  supabase/tests/crawler_overload_demolition_queue_expiry.sql — 32 PASS / 0 FAIL, LIVE, ROLLBACK, residuo 0
static   npx tsc -b exit 0 · npm run build exit 0 · eslint 0 errors (7 warnings preexistentes)
         npm run cert:contracts PASS (75 nombres RPC) · git diff --check limpio
ui       src/App.tsx muestra el OVERLOAD del servidor y permite 0/50/100/110/120/130/140/150 %.
         No calcula producción ni energía: las muestra del contrato.
toque    calculate_planet_production (3 ocurrencias), calculate_crawler_energy_consumption (reescrita con
         overload), get_planet_crawler_status (2 columnas al final), 1 columna nueva, 1 RPC nueva.
         No se tocó ninguna otra fórmula, ni las colas, ni el motor de asentamiento.
```

## Queue retention — CLOSED / **RETAIN** (no purge) (2026-10-03)

> Decisión: **NO PURGAR.** No se escribió código. La medición no encontró ningún problema funcional,
> y cualquier periodo de retención habría sido inventado.

This closes the question left open as `PRODUCT DECISION REQUIRED` by the economy gap sweep.
**Queue expiry is untouched** — expired → `COMPLETED` remains exactly as certified (§Queue expiry
above). Nothing here converts `COMPLETED` into `CANCELLED` or touches refunds.

### Measurement (LIVE, read-only)

```text
queue             total  terminal  active  oldest       newest
building_queue       3         3       0  2026-09-18   2026-09-18
research_queue       5         5       0  2026-09-18   2026-09-19
shipyard_queue       1         1       0  2026-09-19   2026-09-19
defense_queue        0         0       0  —            —
TOTAL                9         9       0
```

### Why there is no problem to solve

```text
1. NO UI CONSUMER of terminal rows. Every client query filters to ACTIVE statuses:
     building_queue  .in('status',['BUILDING','QUEUED'])
     research_queue  .eq('status','RESEARCHING')
     shipyard_queue  .in('status',['BUILDING'])
     defense_queue   .in('status',['BUILDING','QUEUED'])
     MissileControlPanel .in('status',['BUILDING','QUEUED'])
   There is no construction/research/shipyard history screen anywhere.

2. NO GAMEPLAY DECISION depends on them. The three gates that could have been poisoned by a
   purge all filter to the active state:
     can_start_research            upper(q.status) = 'RESEARCHING'
     evaluate_building_start_internal  UPPER(rq.status) = 'RESEARCHING'
     inspect_demolition            upper(rq.status) = 'RESEARCHING'
   So deleting terminal rows would change NO behaviour.

3. NO DEPENDENTS. Zero inbound foreign keys reference any of the four queue tables: no child
   table, no report, no message and no history row hangs off them. (No blind CASCADE was ever
   at risk, because there is nothing to cascade.)

4. NO ACCUMULATION. 9 rows in the whole era, and **zero rows created in the last 14 days** —
   while 546 planets were created in that same window. The universe is active; the queues simply
   are not being written to. At this rate the tables cost nothing measurable.

5. ALL FOUR QUEUES ARE FULLY INDEXED, including status/finish composites
   (e.g. idx_research_queue_player_researching_finish). There is no scan pressure to relieve.
```

### Why purging would be wrong anyway

The schema has **no audit, history, log or event table at all** (verified against
`information_schema.tables`). The queue tables are therefore the *only* record of what an empire
built, researched and produced. Deleting terminal rows would be irreversible destruction of the
game's sole history — in exchange for **zero** functional benefit, because points 1–5 show
nothing consumes them and nothing is degrading.

### Why no period was chosen (no invented constants)

```text
OGameX   Its scheduled maintenance covers highscores, DarkMatterRegenerate, CleanupWreckFields,
         DeleteOldMessages, CleanupDestroyedPlanets and ResetDebrisFields.
         It defines NO queue-retention rule. OGameX therefore authorises nothing here.
LGI      Has a 7-day default, but in run_message_retention_worker — that window comes from
         OGameX's DeleteOldMessages and is a MESSAGES rule. Applying it to queues by analogy
         would be a category error, not a derivation.
```

So the possible retention periods were 7 / 30 / 90 days with **no source for any of them**.
Choosing one would have been inventing a policy. Choosing "keep everything" invents no constant
and is the only option that is safe when the benefit of the alternative is zero.

```text
QUEUE RETENTION
status:  CLOSED
policy:  RETAIN (indefinite)
purge:   DISABLED — not implemented, not needed
reason:  no consumer, no dependents, no accumulation, full indexes, and these rows are the
         only construction/research history the schema has
revisit: only if a queue-history screen is built (then retention becomes a real policy), or
         if growth ever becomes measurable — measure first, then decide with evidence
```

---

## Resource settlement: la carga de una flota no se destruye (2026-09-30)


**Regla.** El tope de almacena acota **lo que se produce**, nunca lo que ya se posee:

```text
settle_resource_stock(current, delta, capacity)
  = greatest( 0
      current
    + least( greatest(delta, 0), greatest(capacity - current, 0) )   -- produccion: solo hueco libre
    + least( delta, 0 ) )                                            -- consumo: siempre completo
```

`update_planet_resources_until_raw` y `update_planet_resources` delegan en ella: una sola autoridad,
dos llamadores. `IMMUTABLE`, `search_path` fijo, `EXECUTE` solo `service_role` (no es contrato de
cliente). Postura idéntica a `calculate_planet_production` y al `_internal` de
`20260927120200_fix_engine_settle_storage_regression`.

**Defecto corregido.** Ambas funciones terminaban en

```sql
v_metal := LEAST(v_metal_capacity, GREATEST(0, v_metal + v_metal_produced));
```

que recorta el **TOTAL**. Los resolvers de llegada (`resolve_transport_arrival`,
`resolve_deploy_arrival`, `resolve_expedition_return`) acreditan la carga sin tope, igual que
`PlanetService::addResources()` de OGameX. Resultado: un transporte que desbordaba un planeta lleno
se acreditaba entero y el **siguiente tick borraba el excedente** — medido en LIVE, 149 000 -> 100 000,
**49 000 metal destruidos sin evento ni informe**. El botin de expedicion sufria lo mismo.

**Evidencia.** `PlanetService::updateResourcesUntil` (PlanetService.php:1450-1460) limita el
incremento (`if (($current + $add) > $max) $add = $max - $current;`) y nunca reduce el stock; un
planeta por encima de su capacidad conserva los recursos y deja de producir hasta que el jugador
gaste el excedente. `addResources()` tampoco recorta por capacidad (solo `max(0,...)`): entrega y
produccion nunca compiten por el mismo tope en upstream. En LGI competian, y ganaba la produccion.

**Consecuencias de juego (intencionales).**

* Un planeta transportado por encima de su capacidad conserva el excedente y **no produce** hasta
  gastarlo. Es el comportamiento clasico.
* El consumo **nunca** se recorta: la planta de fusion sigue quemando deuterio con el almacen lleno.
  Sin separar produccion de consumo, arreglar el overflow habria roto el combustible de la fusion.

**No se inventa balance**: sin coste, tiempo, formula ni capacidad nueva. Se restaura upstream.
Certificado por `supabase/tests/resource_settlement_cargo_preservation.sql` — **18 PASS / 0 FAIL,
LIVE 2026-09-30, ROLLBACK, residuo 0**, con guarda anti-vacuidad (el planeta de prueba debe
producir de verdad; `bootstrap_new_player_state` no crea edificios).
Ver `docs/audits/RESOURCE_SETTLEMENT_GAP_2026-09-30.md`.

---

# 2026-10-01 — PRE-FLIGHT DE AUTOSOSTENIBILIDAD (guard contra soft-lock económico)

## El problema

`bootstrap_new_player_state` deja el planeta en **500 metal / 500 crystal / 0 deuterio y sin
edificios**, es decir **sin ninguna fuente de energía**.

Secuencia legal, sin trampas ni concessions, verificada contra los costes reales del catálogo:

```text
deuterium_synthesizer L1   -225 metal  -75 crystal     consumo 22/h
crystal_mine L1             -48 metal  -24 crystal     consumo 11/h
metal_mine L1               -60 metal  -15 crystal     consumo 11/h
crystal_mine L2             -72 metal  -36 crystal     consumo 24.2/h
metal_mine L2               -90 metal   -0 crystal     consumo 24.2/h
                           ────────────────────────────
restan                       5 metal   350 crystal     consumo total 70.4/h
```

`solar_plant` L1 cuesta **75 metal** y ya no es construible. Con `energy production = 0` y
`energy consumption = 70.4/h`, `production_factor = 0` y **toda** la producción de recursos se
detiene para siempre. La demolición no rescata (`inspect_demolition` exige recursos y devuelve
`INSUFFICIENT_RESOURCES`). Soft-lock económico real, reproducible y **alcanzable desde el
bootstrap**.

**Corrección sobre la secuencia que circulaba en auditorías previas:** la ruta
«shipyard L1 + crystal_mine L1 → 52 metal» **no es ejecutable desde un planeta recién creado**,
porque `shipyard` cuesta además **100 deuterio** y el arranque deja 0. Los números de esa ruta
eran correctos como aritmética, pero partían de un planeta que ya tenía deuterio. La secuencia
real y alcanzable es la de cinco pasos de arriba.

Además, en un planeta **sin ninguna fuente de energía** el primer consumidor ya colapsa la
producción por sí solo: no hace falta una secuencia larga. El guard rechaza ese primer consumo y
señala la recuperación; al construir la planta solar, toda la economía se abre.

## La decisión de producto

> Un jugador no debe poder iniciar una acción que deje su planeta **sin capacidad de
> autoabastecerse** cuando existe una alternativa económica razonable para recuperar o proteger
> la producción.

Esto **no revierte** «Energía = información, nunca puerta». La energía sigue sin bloquear una
construcción por ser baja. Lo único que se rechaza es la acción cuyo estado posterior *demuestra*
el colapso. Es una excepción de gameplay deliberada, más específica, y está anotada en la decisión
registrada de la sección anterior para que no se contradigan.

## Definición de autosostenibilidad

No se inventó ninguna fórmula. Se usa la de LGI:

```text
production_factor := GREATEST(0, LEAST(1, energy_production / energy_consumption))
```

El planeta se autoabastece si y solo si `consumption = 0` **o** `production > 0`. El soft-lock es
exactamente `consumption_after > 0 AND production_after <= 0`.

Ahorro (`resources >= cost`) **no** es suficiente: con recursos de sobra y energía a cero el
planeta sigue atrapado.

## El contrato

| Función | Rol | ACL |
| --- | --- | --- |
| `calculate_building_energy_output(building, level)` | Efecto energético **neto** de un nivel, en las unidades de `calculate_planet_production`. Positivo produce, negativo consume. Reutiliza `calculate_building_energy_consumption`. | `service_role` |
| `evaluate_economic_sustainability(planet, building, target_level)` | **Pre-flight autoritativo.** Simula el estado post-acción: `applicable, blocks, reason_code, reason, energy_*_now, energy_*_after, production_factor_after, recovery_available`. | `service_role` |

## Dónde se aplica — una sola autoridad para jugador e IA

El guard se cableó por *splice* anclado sobre `pg_get_functiondef()` (nada se reescribe a mano: se
conservan byte a byte firma, `RETURNS TABLE`, volatility, seguridad y `SET search_path`) en:

1. **`evaluate_building_start_internal`** — el oráculo certificado que ya comparten
   `can_start_building` (cliente), `get_planet_building_preview` (lectura) y
   `ai_decide_and_act_core` (IA).
2. **`start_building`** — **descubrimiento crítico**: esta función **no** delega en
   `can_start_building`; reimplementa todas las validaciones por su cuenta. Cablear solo el oráculo
   protegía las rutas *consultivas* pero **`start_building` directo seguía soft-loqueando** — justo
   la vía de atacante que la misión prohíbe. El pre-flight se aplica también aquí, **antes de
   cobrar**: una acción rechazada no cuesta recursos ni encola nada.

Por eso jugador e IA quedan protegidos por la **misma** autoridad, y el backend sigue siendo la
última barrera aunque el planificador de IA cambie.

## Qué acciones quedan protegidas (verificado contra `building_energy_definitions`)

| Acción | ¿Puede alterar energía/producción? | ¿Necesita guard? | Motivo |
| --- | ---: | ---: | --- |
| `metal_mine`, `crystal_mine` | **Sí** (consumo) | **Sí** | Único camino a `production_factor = 0` |
| `deuterium_synthesizer` | **Sí** (consumo) | **Sí** | Ídem |
| `solar_plant` | **Sí** (producción) | No | Es la **recuperación**; nunca se bloquea |
| `fusion_plant` | **Sí** (producción) | No | Ídem; solo si hay deuterio |
| `shipyard`, almacén, cía. | No (0 en `building_energy_definitions`) | No | `applicable = false`; cero falsos positivos |
| Investigación | No | No | No toca energía |
| Naves / defensas | No | No | No tocan energía |

Nada se bloquea indiscriminadamente: el guard solo es `applicable` cuando la acción mueve energía.

## Contrato de error

`reason_code = 'INSUFFICIENT_ENERGY_SUSTAINABILITY'`, con un `reason` que la UI puede mostrar tal
cual («Investiga o construye primero una mejora energética»). Los errores económicos previos
(`Recursos insuficientes`, `INSUFFICIENT_RESOURCES`, `PLAYER_NOT_OWNED`…) **no cambian**: la
comprobación va *después* de ellos, así que un jugador roto sigue viendo su error de siempre.

## Condición de escape

`blocks` solo es `true` si además `recovery_available`: el colapso se bloquea únicamente cuando el
planeta todavía tiene salida (ya tiene fuente de energía, o le alcanza el metal para la siguiente
planta solar / de fusión). Así el guard no convierte un mal momento en unCALLEJÓN sin salida, y
nunca impide construir la mejora que **sí** rescata.

## Tests

`supabase/tests/economic_sustainability_guard.sql` — fixture transaccional (ROLLBACK, residuo 0):
A acción segura, B acción peligrosa, C affordability conserva el error previo, D sin falsos
positivos, E reintentos/race, F IA (candidato peligroso rechazado y candidato seguro ejecutado,
ambos por el actor declarado), G ownership (no-owner 0 filas, owner 1 fila, anónimo denegado),
ACL y aserción anti-vacuidad.

| `get_economic_sustainability_check(planet, building)` | Mismo pre-flight, **owner-scoped** (`auth.uid()` → `players.user_id`). Cero filas para planeta ajeno/destruido, nunca excepción. Es la prevalidación de UI. | `authenticated` |

**Simulación pura:** el estado posterior se deriva aritméticamente de los helpers certificados. No
se muta el planeta y no se usa mutación+rollback como mecanismo de validación.

### Signo del delta (trampa real, documentada)

`calculate_building_energy_output` devuelve el **neto** (producción − consumo), así que un
consumidor da delta **negativo** (`crystal_mine` L1 = −11, no +11). La primera implementación
sumó ese delta al consumo, lo que lo invertía y dejaba el guard **siempre en `false`**: una sonda
en vivo reportaba `crystal_mine` L1 como +11/h de *producción*. Dos migraciones correctivas
quedan registradas en el ledger; la aserción `J` (anti-vacuidad) de la fixture impide que un guard
inerte vuelva a pasar por bueno.
