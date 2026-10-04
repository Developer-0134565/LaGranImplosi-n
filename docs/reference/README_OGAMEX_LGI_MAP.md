# OGAMEX → LA GRAN IMPLOSIÓN — SYSTEMATIC ARCHITECTURAL MAP

> ## ⚠️ SUPERSEDED IN PART — DO NOT TRUST AS CURRENT STATE (2026-10-03)
>
> Este mapa es de **2026-09-25**. Varias filas `MISSING` ya **no** lo son: contrastadas contra LIVE,
> estos sistemas están **implementados y cerrados** hoy:
>
> ```text
> Missile System          · Moon destruction   · Demolition + Ion
> recall_fleet            · wreck/message cleanup · Crawler overload
> ```
>
> **La evidencia LIVE actual tiene prioridad sobre este documento.** Para el estado vigente ver
> `docs/PROJECT_CONTEXT_PROMPT.md` §"GAMEPLAY GAP STATUS — CANONICAL" y
> `docs/audits/OGAMEX_FINAL_GAP_CHECK_2026-10-03.md`.
>
> El texto original se conserva intacto como registro histórico de la auditoría del 2026-09-25.
>
> **Status:** FIRST SYSTEMIC MAP — **2026-09-25**. Read-only audit: no code, no migration, no LIVE change.
> **Relationship to the older file:** [`OGAMEX_LGI_MAP.md`](OGAMEX_LGI_MAP.md) (2026-09-17) is the first-pass
> structural bridge (method + open audit targets). It is **not** deleted and remains valid as the method note;
> **this file is the per-domain map with states and classifications and supersedes it for gap analysis.**

## How to read this document

Comparison unit = **responsibility and behaviour**, never class/RPC names. A different architecture is **not**
automatically a gap: it is `ADAPTATION` when the responsibility is covered.

```text
States            : IMPLEMENTED · PARTIAL · MISSING · INTENTIONAL DIFFERENCE · OUT OF SCOPE · UNKNOWN
Classifications   : MATCH · ADAPTATION · BUG · PRODUCT DECISION · TECHNICAL GAP · OUT OF SCOPE · NEEDS INVESTIGATION
```

Rows marked `NEEDS INVESTIGATION` are explicitly **not asserted** as gaps.

## Evidence basis (measured 2026-09-25, read-only)

```text
LGI (LIVE catalogue + repository)
  public functions ......... 236        (overloads counted separately)
  relations ................ 87         (of which 21 views = analysis/advisor layer)
  SECURITY DEFINER ......... 73
  client-callable RPCs ..... 103        (EXECUTE granted to `authenticated`)
  RLS ...................... 66 tables / 66 policies
  triggers ................. 15         (ownership write guards on queues + fleet_movements)
  active pg_cron jobs ...... 2          (run_fleet_worker 1 s · process_universe_heartbeat 1 min)
  indexes .................. 198
  migrations in repo ....... 318 files  · tests: 18 SQL suites in `supabase/tests/`

OGameX (reference)
  clone pinned at .................. lanedirt/OGameX @ 7c420bad3478d7099791e1f33c920e9ff92822e8 (2026-09-21)
  app/ ............................. GameObjects · GameMissions · Services · Models · ViewModels · Http ·
                                     Console · Jobs · Observers · Events · GameConstants · GameMessages ·
                                     Actions · Enums · Factories · Facades · Providers · Exceptions
  DB migrations .................... 97 · tests/: Feature (~80) + Unit (~30)
  scheduling ....................... routes/console.php `Schedule::command(...)` (maintenance only)

Documents consulted: docs/PROJECT_CONTEXT_PROMPT.md · docs/architecture/README_ARCHITECTURE.md ·
docs/systems/{README_FLEET_ENGINE,README_COMBAT_ENGINE,README_ECONOMY,README_RESEARCH,
README_SHIPYARD_DEFENSE,README_DEFENSE_ENGINE,README_UNIVERSE_EVOLUTION,README_UNIVERSE_EVOLUTION_MONITOR,
README_FUNCTIONAL_AUDIT,README_GAME_ENGINE_AUDIT,README_IDENTITY_AND_ACCESS}.md ·
docs/reference/README_OGAMEX.md · docs/UNIVERSE_RATE_AND_FLEET_ENGINE_MONITOR.md · docs/MIGRATION_*.md
```

## A. UNIVERSE / TIME

| OGameX | Responsabilidad | L.G.I. | Estado | Clasificación | Evidencia |
|---|---|---|---|---|---|
| `GameConstants/UniverseConstants` (galaxias, sistemas ≤499, posiciones 1..15, `EXPEDITION_POSITION` 16) + `FleetController::validateCoordinates` | límites y topología del universo | `universe_galaxies.system_count` + validación en los dispatchers (`g<1, s<1, p<1, p>15`) y posición 16 para expedición | IMPLEMENTED | ADAPTATION | UniverseConstants.php; `start_fleet_mixed`; `universe_galaxies` |
| `SettingsService` (`economySpeed`, `fleetSpeed`, `researchSpeed`, `numberOfGalaxies`, settings en DB) | parámetros del universo | `universes` (economy/production/building/research/fleet/peaceful/war/holding/expedition/lifeform/resource/storage + expansión) y `calculate_universe_rates` | IMPLEMENTED | ADAPTATION | columnas `universes`; SettingsService.php |
| `Http/Middleware/GlobalGame` → `PlayerService::updateFleetMissions()` (709) + `FleetEventsController` (polling `/ajax/fleet/eventbox/fetch`) | resolución de eventos diferidos | `process_fleet_movements()` llamado por `pg_cron` **cada segundo** (`run_fleet_worker`) y ticks de economía (`process_planet_tick`, `process_universe_tick`) | IMPLEMENTED | ADAPTATION **deliberada**: LGI resuelve de forma asíncrona y global; OGameX resuelve por petición del jugador | GlobalGame.php:61; PlayerService:709; `cron.job` |
| `routes/console.php` `Schedule::command(...)`: highscores (5 min), `DarkMatterRegenerate` (5 min), `CleanupWreckFields`/`DeleteOldMessages` (hourly), `CleanupDestroyedPlanets` (daily), `ResetDebrisFields` (weekly) | trabajo programado de mantenimiento | `pg_cron`: `run_fleet_worker()` (1 s) + `process_universe_heartbeat()` (1 min); sin jobs de mantenimiento equivalentes | IMPLEMENTED / PARTIAL | ADAPTATION + TECHNICAL GAP (higiene: las colas `COMPLETED` no se purgan) | console.php; PROJECT_CONTEXT §7 |
| — (sin equivalente) | reloj persistente y catch-up tras downtime | `universe_clock` (`last_tick_at`, `next_tick_at`, intervalo) + `process_universe_clock` | IMPLEMENTED (LGI-unique) | ADAPTATION (capacidad inexistente en OGameX) | ENGINE_MANIFEST; `universe_clock` |
| — (sin equivalente) | evolución del universo E(t) y escalado por categoría | `calculate_universe_evolution_rate(_at)`, `calculate_universe_scaling(_at)` (E^1 / E^0.5 / E^(1/3)) | IMPLEMENTED (LGI-unique) | OUT OF SCOPE para comparación | README_UNIVERSE_EVOLUTION.md |
| — (sin equivalente) | expansión de galaxias/sistemas y galaxias especiales | `process_universe_system_expansion`, `process_universe_galaxy_roll`, `universe_expansion_state`, `universe_galaxies` | IMPLEMENTED (LGI-unique) | ADAPTATION | README_UNIVERSE_EVOLUTION.md |
| `NPCPlanetService`, `NPCPlayerService`, `NPCFleetGeneratorService`, `Jobs/CreateLegorMoon`, `Console/Commands/Admin/InitializeLegorAccount` | entidades NPC controladas por comandos de desarrollo | `reconcile_universe_ai_population` + `universe_population_state` + `players.player_type='AI'` (densidad 5–10 %) | IMPLEMENTED | ADAPTATION (OGameX siembra NPCs puntualmente; LGI reconcilia densidad de forma continua) | ENGINE_MANIFEST; README_UNIVERSE_EVOLUTION.md |
| `GenerateHighscores` / `GenerateHighscoreRanks` / `GenerateAllianceHighscores` (programados) + `HighscoreService` | puntuaciones y ranking | `players.points` / `players.rank` + `get_universe_top1_points` + job `run_ranking_worker` (pg_cron) + **categorías 2026-09-26** (`economy_points` / `research_points` / `military_points`, ranks por categoría, `get_universe_ranking_by_category`) | IMPLEMENTED (general + categorías) / OUT OF SCOPE (alliance ranking) | MATCH + OUT OF SCOPE (no existe subsistema de alianzas) | README_RANKING «Category scores» |
| `DarkMatterService` + `DarkMatterRegenerateCommand` | materia oscura como recurso persistente | `players.dark_matter` (sólo se acredita por expedición) | PARTIAL | PRODUCT DECISION | `calculate_expedition_dark_matter_amount` |
| `ResetDebrisFields`, `CleanupWreckFields`, `CleanupDestroyedPlanets`, `DeleteOldMessages` | mantenimiento programado | — | MISSING | OUT OF SCOPE / TECHNICAL GAP (higiene) | PROJECT_CONTEXT §7 |
| `Ban`, `VacationMode` (+ `CheckBanned` middleware) | estado de cuenta | — | MISSING | OUT OF SCOPE | Http/Middleware; models |

## B. ECONOMY

| OGameX | Responsabilidad | L.G.I. | Estado | Clasificación | Evidencia |
|---|---|---|---|---|---|
| `PlanetService::updateResources()` (devengo por horas transcurridas + cap de almacén al consultar) | producción y devengo temporal | `update_planet_resources_until(_raw)` + `calculate_planet_production` (devengo por segundos × tasa, cap por almacén, factor de energía) | IMPLEMENTED | MATCH / ADAPTATION | PlanetService 1451-1478; README_ECONOMY |
| `BuildingObjects` (minas 30/20/10·L·1.1^L, solar 20·L·1.1^L, fusión) | producción por edificio | mismas fórmulas base + factor de energía + Plasma/Energy Technology + bonos lifeform/item; **fusión ausente** (no implementada a propósito: ver NEXT CANDIDATES 4) | PARTIAL | ADAPTATION + PRODUCT DECISION (integración del consumo de deuterio de la fusión) | `calculate_planet_production`; BuildingObjects.php |
| almacén `5000·floor(2.5·exp(20L/33))` | capacidad de almacenamiento | `100000 · 2^nivel × universes.storage_multiplier` | IMPLEMENTED | INTENTIONAL DIFFERENCE (curva propia de LGI) | `calculate_planet_storage`; BuildingObjects storage |
| `PlanetService::updateResourcesUntil()` — el tope de almacén se aplica **sólo al incremento** (`if (($current + $add) > $max) $add = $max - $current;`), nunca al stock ya poseído; combinado con `addResources()` (usado por `TransportMission::processArrival`), que **no** recorta por capacidad (sólo `max(0,…)`) | liquidación de almacén: la carga entregada por una flota nunca debe competir con la producción por el tope | `settle_resource_stock(current, delta, capacity)` (IMMUTABLE, `service_role` only): producción → sólo hueco libre; consumo → siempre completo; resultado con suelo 0. Delegada por `update_planet_resources_until_raw` y `update_planet_resources`. **DEFECTO CORREGIDO**: ambas terminaban en `LEAST(capacity, current + produced)`, que recortaba el TOTAL ⇒ el excedente entregado por transporte/deploy/expedición se acreditaba y se destruía en el siguiente tick (medido en LIVE: 149 000 → 100 000, 49 000 metal perdidos) | IMPLEMENTED 2026-09-30 | MATCH | `20260930230000`; `tests/resource_settlement_cargo_preservation.sql` 18/18; `docs/audits/RESOURCE_SETTLEMENT_GAP_2026-09-30.md` |
| `ObjectService::getObjectPrice/getObjectTime` + `GameObjectPrice` | costes y tiempos | `calculate_building_cost/time`, `calculate_research_cost/time`, `calculate_ship_cost/build_time`, `calculate_defense_cost/build_time` | IMPLEMENTED | MATCH | inventario de funciones |
| `BuildQueueService` / `ResearchQueueService` / `UnitQueueService` (multi-ítem, `cancel`, `addDowngrade`, DM halving/instant) | colas de construcción | `building_queue` / `research_queue` / `shipyard_queue` / `defense_queue` — un solo ítem activo; **cancelación de building y research implementada 2026-09-26** (`cancel_building` / `cancel_research`, reembolso 100 % del precio cobrado) y **demolición/downgrade implementada 2026-09-26** (`start_demolition` / `can_start_demolition` / `inspect_demolition`: coste = precio del nivel retirado −4 %/nivel de `ion_technology`, `is_downgrade`, nivel 0 permitido, cancelación reembolsa lo cobrado); shipyard/defensa sin cancelación | PARTIAL | TECHNICAL GAP CERRADO para building/research/**demolición** (fórmula y guardas tomadas de OGameX, no inventadas) + PRODUCT DECISION pendiente solo para multi-ítem/DM | README_ECONOMY «Queue cancellation contract» + «Building demolition» |
| `PlanetService::deductResourcesAndUnitsAtomic` | débito atómico de recursos+unidades | `FOR UPDATE` + `UPDATE` en la misma transacción dentro de cada `start_*`; liquidación previa con `update_planet_resources_until` | IMPLEMENTED | ADAPTATION | `start_building`/`start_research`/`start_ship`/`start_defense` |
| **`PlanetServiceFactory::planetData()`** (banda de temperatura por posición 1..15) + **PR #514** (mergeado: `temp_min = temp_max − 40`, rango de 40°) | temperatura planetaria derivada de la posición | `planet_temperature_for_position(position)` (banda OGameX verbatim, punto medio determinista) → `planets.temperature_min/max` → `planet_temperature(planet)`; backfill de los 692 planetas y los 4 escritores (`provision_player`, `resolve_colonize_arrival`, `reconcile_universe_ai_population`, `settle_moon_creation_for_battle`) | IMPLEMENTED 2026-09-30 | MATCH (con INTENTIONAL DIFFERENCE: punto medio en vez de `rand(lo,hi)`) | `20260930160000`; `docs/audits/PLANET_TEMPERATURE_SYSTEM_2026-09-30.md` |
| **`BuildingObjects.php:86`** `10·L·1.1^L·(1.44 − 0.004·T_avg)` | factor de temperatura del **deuterio** | el mismo factor en `calculate_planet_production` (rango 0.56 pos 1 … 1.96 pos 15); el término crawler NO se multiplica, igual que en OGameX (`calculateCrawlerProduction()` corre tras `calculateMine()`) | IMPLEMENTED 2026-09-30 | MATCH | `tests/plasma_technology_production.sql` 12/12; `tests/planet_temperature.sql` 6-7 |
| **`StationObjects.php`** `nano_factory` id 15, `GameObjectPrice(1000000, 500000, 100000, 0, 2)`, `requirements [computer_technology 10, robot_factory 10]`, `valid_planet_types = [Planet]` | fábrica de nanorobots | `20260930210000`: definición verbatim + `calculate_nanite_factory_build_speed(planet) = 2^nivel` plegada en la tasa efectiva de edificios, naves y defensas | IMPLEMENTED 2026-09-30 | MATCH | `tests/nanite_and_crawler_balance.sql` 1-5 |
| **`PlanetService::getTechnologyResearchTime()`** — sin término nanite | el nanite **no** acelera la investigación | `calculate_research_time` intacta; la migración aborta si alguna vez aparece `nanite` en su cuerpo | IMPLEMENTED | MATCH (distinción de tipos de OGameX respetada) | `tests/nanite_and_crawler_balance.sql` 6 y 12 |
| `PlanetService::getUnitConstructionTime()` usa `(metal + cristal)/2500` | tiempo base de unidades | LGI usa `base_build_time_seconds` por objeto (convención de toda la tabla) y **NO** `(1+robot)` en unidades | IMPLEMENTED | **INTENTIONAL LGI DIFFERENCE** (documentada; revertirla reabriría la decisión cerrada del Robot Factory) | `docs/audits/GAP_CLOSURE_2026-09-30.md` §3.1 y §6 |
| `StationObjects.php` `missile_silo` id 44 (20000/20000/1000, shipyard 1), `DefenseObjects.php` `anti_ballistic_missile` id 502 (missile_silo 2) e `interplanetary_missile` id 503 (missile_silo 4 + impulse_drive 1), con ranuras 1 y 2 por silo nivel | bloque de misiles | — | MISSING | **GAP ESPECIFICADO, NO IMPLEMENTADO**: requiere un nuevo tipo de misión de flota + settlement ⇒ sistemas CLOSED | `docs/audits/GAP_CLOSURE_2026-09-30.md` §2 y §5 |
| `StationObjects.php` `shipyard → robot_factory 2` y `space_dock → shipyard 2` | prerrequisitos de estación | ausentes | OUT OF SCOPE | la primera **rompería el hangar lunar** (robot_factory es PLANET-only y el prerrequisito es por cuerpo); la segunda es una mecánica LGI ya CLOSED | `docs/audits/GAP_CLOSURE_2026-09-30.md` §4 |
| **`CivilShipObjects.php:171`** `floor((T_max + 140)/6) · n` | **energía del satélite solar** (antes inexistente: la nave era inerte) | misma expresión sumada a la energía planetaria junto a solar y fusión | IMPLEMENTED 2026-09-30 | MATCH | `tests/planet_temperature.sql` 8-9 (630/310/50 exactos) |
| **`CivilShipObjects.php`** precio `GameObjectPrice(0, 2000, 500, 0)`, `requirements [shipyard 1]`, sin `valid_planet_types` | ficha completa del satélite | idéntica: 0/2000/500, un solo prerrequisito, `{PLANET,MOON}` | MATCH | MATCH | `tests/solar_satellite.sql` 1-3 |
| **`GameObjectProperties($obj, 2000, 1, 0, 0, 0, 1)`** → SI 2000, escudo 1, **ataque 0**, velocidad 0, carga 0, combustible 1 | perfil táctico del satélite | casco 200 (= SI/10, convención LGI), escudo 1, **ataque 0 CORREGIDO 2026-09-30** (LGI tenía 1, copiado del crawler), velocidad 0, carga 0; **combustible 0 ≠ 1 upstream, inerte** (la velocidad 0 corta el despacho antes de calcularlo) | IMPLEMENTED | MATCH salvo el combustible (divergencia declarada, sin efecto alcanzable) | `20260930200000_solar_satellite_combat_profile.sql`; `tests/solar_satellite.sql` 19 |
| `PlanetService::getFlightShipAmount()` excluye el satélite ("Do not count solar satellite as ship") | recuento de naves voladoras | — | OUT OF SCOPE | **la función no tiene NINGÚN llamante en todo el upstream**: intención sin consumidor, no hay regla que implementar | `prosrc` de `public` |
| `PlanetService::getPlanetTempAvg/Min/Max` (leen `planets.temp_min/temp_max`) | getters de temperatura | `planet_temperature(planet)` — **total**: nunca devuelve 0 filas ni NULL (UUID aleatorio ni UUID NULL) | IMPLEMENTED | ADAPTATION (el nombre de las columnas LGI es `temperature_*`) | `20260930161000` |
| `HalvingService::calculateHalvingCost/halve*/complete*` (DM: 750 DM/30 min, topes por tipo) | aceleración con DM | — | MISSING | PRODUCT DECISION | HalvingService.php |
| `DarkMatterService` + `DarkMatterTransactionService` + `DarkMatterTransaction` | economía premium | `players.dark_matter` (sólo ingresos por expedición) | PARTIAL | PRODUCT DECISION | `players` |
| `MerchantService`, `ShopController`, `PremiumController`, `RewardsController`, `PaymentController` | tienda, mercado y pagos | `resolve_expedition_merchant` + `execute_expedition_merchant_trade`, y desde 2026-09-27 también el contrato de CLIENTE (`get_player_expedition_merchant`, `trade_with_expedition_merchant`) | PARTIAL | la variante de expedición queda IMPLEMENTED y alcanzable; tienda/premium siguen OUT OF SCOPE / PRODUCT DECISION | Services list; funciones de expedición |
| `ObjectService::getObjectDowngradePrice` + `addDowngrade` | demolición/degradación con rescate | — | MISSING | PRODUCT DECISION (la tasa base de rescate no está definida; el mockup LGI declara +1 %/nivel de ion) | README_RESEARCH §13; `template/edificios.txt` |
| `Resources`/`Resource` value objects + `ProductionIndex` | modelo de recursos | columnas `metal/crystal/deuterium/energy` en `planet_resources` + `fleet_movements` | IMPLEMENTED | ADAPTATION | esquema |
| `CharacterClassService` (bonos económicos de clase) | bonos de personaje | — (LGI usa lifeforms/items) | MISSING | OUT OF SCOPE | CharacterClassService.php |

## C. FLEET / MISSIONS

| OGameX | Responsabilidad | L.G.I. | Estado | Clasificación | Evidencia |
|---|---|---|---|---|---|
| `FleetMissionService` (`mission_type` numérico 1..15, persistencia, duración, consumo) | ciclo de vida de la misión | `fleet_movements` + `fleet_movement_ships` + `process_fleet_movements` (switch por `mission_type`) + familia `resolve_*_arrival` | IMPLEMENTED | ADAPTATION | README_FLEET_ENGINE; `process_fleet_movements` |
| `GameMission::start` + `startMissionSanityChecks` (recursos, unidades, slots, misión posible) + `deductMissionResources` | despacho validado y atómico | `start_fleet`, `start_fleet_mixed`, `start_colonize_fleet`, `start_support_fleet` (requisitos, ownership, destino, combustible; débito en la misma transacción) | IMPLEMENTED | ADAPTATION | README_FLEET_ENGINE §2–§5 |
| Recursos en el despacho (`request()->input('metal'…)`) | carga transportada | **post-despacho**: `load_fleet_cargo` (owner-gated, capacidad, disponibilidad, whitelist de misión) | IMPLEMENTED | INTENTIONAL DIFFERENCE (modelo propio de LGI, documentado) | README_FLEET_ENGINE §24 |
| `UnitCollection::getTotalCargoCapacity` + `CapacityPropertyService` (hyperspace 5 %/nivel) | capacidad de carga | `calculate_fleet_cargo_capacity` = Σ cantidad × `cargo_capacity × (1 + 0.05·hyperspace)` | IMPLEMENTED | MATCH (sin bonos de clase) | `calculate_player_ship_cargo_capacity` |
| `SpeedPropertyService`, `FuelPropertyService`, `GameObjectSpeedUpgrade` | velocidad y consumo por motor | `calculate_player_ship_speed`, `calculate_player_ship_fuel_consumption`, `calculate_player_fleet_fuel_for_distance`, `calculate_mission_fleet_speed_multiplier`, `calculate_fleet_travel_time` | IMPLEMENTED | MATCH / ADAPTATION | README_FLEET_ENGINE §3 |
| `FleetController::dispatchCheckTarget` + `GameMission::isMissionPossible` | viabilidad de la misión | validación inline en los dispatchers + `check_ship_requirements` | IMPLEMENTED | ADAPTATION | `start_fleet_mixed` |
| `PlayerService::getFleetSlotsInUse/Max` (`1 + computer_technology`, +2 General) | límite de flotas simultáneas | **derivación implementada 2026-09-26** (`calculate_player_max_fleet_slots`, `calculate_player_fleet_slots_in_use`, `get_player_fleet_slots`; 8 PASS + 1 INFO). Sin enforcement: adoptar el tope es **PRODUCT DECISION**. Los slots de **expedición** (`get_player_expedition_slots`) son otro sistema y no se tocaron | PARTIAL | ADAPTATION + PRODUCT DECISION (adopción del tope) | README_FLEET_ENGINE §30 |
| `FleetUnionService` + `FleetUnion`/`FleetUnionInvite` (ACS: crear/unir/uniones disponibles) | agrupación ACS | `planet_support_authorizations` + `start_support_fleet` (ACS_HOLD **Fase A**) | PARTIAL | PRODUCT DECISION (falta el productor/agrupación y la liquidación multi-atacante) | README_COMBAT_ENGINE §24; PROJECT_CONTEXT §7 |
| `AcsDefendMission` | apoyo defensivo | rechazado explícitamente (`COMBAT_SUPPORT_NOT_READY`) | MISSING | TECHNICAL GAP (bloqueado por la agrupación ACS) | `start_support_fleet` |
| `FleetController::dispatchRecallFleet` + `GameMission::cancel` | recall de flota | — (auditoría 2026-09-25: no existe ningún RPC `recall_*`/`cancel_*`, ni columna `recalled_at`, ni superficie de UI; `status='CANCELLED'` nunca se escribe) | MISSING | PRODUCT DECISION (combustible del retorno con `recall_fuel_recovery_percent` sin definir · duración del tramo de vuelta de una flota a medio camino · recall de `ACS_HOLD`/HOLDING) | README_FLEET_ENGINE §27.3 |
| `FleetTemplate` + rutas `/ajax/fleet/templates` | plantillas de flota | — | MISSING | OUT OF SCOPE | Models; routes |
| `MissileMission` (+ misiles en `AttackMission`) | ataque con misiles | — (tampoco existen ABM/IPM ni silo) | MISSING | PRODUCT DECISION | GameMissions; DefenseObjects |
| `MoonDestructionMission` | destrucción lunar | — (no existe tipo luna) | MISSING | PRODUCT DECISION | GameMissions |
| `PhalanxService`, `JumpGateService` | falanx y puerta de salto | — | MISSING | OUT OF SCOPE (dependen de lunas) | routes/web.php; Services |
| `PlanetMoveService`, `PlanetAbandonController` | mover / abandonar planeta | — (`planets.is_destroyed` existe pero ninguna función lo activa) | MISSING | PRODUCT DECISION (abandono) · OUT OF SCOPE (move) | `is_destroyed = true` → NONE |
| `FleetEventsController` (`eventbox`/`eventlist`) | visibilidad de flota para el cliente | vista Flota + `fleet_movements` leído con RLS de dueño | IMPLEMENTED | ADAPTATION | src/App.tsx; política `fleet_movements_select_access` |

### C.1 Matriz de capacidades por misión (L.G.I., verificada en código)

`fleet_movements.mission_type` (CHECK) admite 10 nombres; los estados reales del ciclo son estos:

| Misión | Despacho | Llegada | Retorno | Recall | Carga | Combate | Loot |
|---|---|---|---|---|---|---|---|
| `TRANSPORT` | sí (`start_fleet`/`start_fleet_mixed`) | sí — entrega los recursos al destino | sí (vuelve vacío) | no | sí — entregada | no | no |
| `DEPLOY` | sí | sí — transfiere naves **y carga**, `COMPLETED` | no | no | sí — entregada | no | no |
| `COLONIZE` | sí (`start_colonize_fleet`) | sí — crea la colonia y la **siembra** con la carga | no | no | sí — sembrada | no | no |
| `ESPIONAGE` | sí | sí — genera informe y pasa a `RETURNING` | sí | no | sí — regresa al origen | no (contra-espionaje no implementado) | no |
| `RECYCLE` | sí (autoselecciona el campo de escombros más cercano) | sí — recoge escombros | sí | no | no — la carga se **sobrescribe** con el hallazgo | no | no |
| `EXPEDITION` | sí | sí — desenlace determinista por flota | sí | no | sí — el hallazgo se **suma** a la carga | sí (piratas/alienígenas) | no |
| `ATTACK` | sí | sí — resuelve combate | sí (supervivientes) | no | **abierto (PG-09)** | sí | sí (PG-09/10) |
| `ACS_HOLD` | sí (`start_support_fleet`, con autorización) | sí — pasa a `HOLDING` | sí (al vencer `holding_until`) | no | sí — regresa al origen | no | no |
| `HOLDING` | — (estado interno: el despacho lo rechaza) | — | sí | no | — | no | no |
| `DEFEND` | — (rechazado: `COMBAT_SUPPORT_NOT_READY`) | — | — | no | — | — | — |

## D. COMBAT

| OGameX | Responsabilidad | L.G.I. | Estado | Clasificación | Evidencia |
|---|---|---|---|---|---|
| `BattleEngine` (abstracta) + `PhpBattleEngine`/`RustBattleEngine` + `BattleUnit` | motor de rondas | `resolve_combat` → `initialize_individual_combat_units` → `process_combat_round_v2` (≤6 rondas) → `resolve_pending_target_damage` | IMPLEMENTED (certificado) | ADAPTATION | README_COMBAT_ENGINE §14–§17 |
| `AttackerFleet`/`DefenderFleet` + `BattleResult`/`BattleResultRound`/`*FleetResult` | participantes y resultado | `combat_battles`, `combat_battle_participants`, `combat_rounds`, `combat_round_snapshot_units`, `combat_individual_units` | IMPLEMENTED | ADAPTATION | README_COMBAT_ENGINE §19/§24 |
| `AttackPropertyService`/`ShieldPropertyService`/`StructuralIntegrityPropertyService` (+10 %/nivel) | estadísticas con tecnologías | `get_combat_ship_attack/shield/hull`, `get_combat_defense_attack/shield/hull` (+10 %/nivel, snapshot al crear la batalla) | IMPLEMENTED | MATCH | README_COMBAT_ENGINE §4 |
| `BattleUnit` (integridad estructural /10 **una vez**) | hull efectivo | `combat_hull_from_integrity` + `(hull/10)` sobre un `hull` que ya es SI/10 → **1/10 del hull efectivo de OGameX** con ataque/escudo idénticos | UNKNOWN | NEEDS INVESTIGATION (convención de balance; LGI es internamente consistente) | README_COMBAT_ENGINE §24; `get_combat_ship_hull` |
| `BattleUnit::damagedHullExplosion()` (<70 %) | explosión de la unidad | ledger de explosión por disparo (<70 %) | IMPLEMENTED | MATCH | README_COMBAT_ENGINE §14 |
| `GameObjectRapidfire` (`addRapidfire`) | fuego rápido | `combat_rapidfire` (52 filas SHIP) + `expand_rapidfire_chain_v2` | IMPLEMENTED | MATCH | tabla `combat_rapidfire` |
| `LootService::calculateLootCapacityConstrained` + `distributeLoot` | saqueo y capacidad | `apply_attack_loot` (capacidad de la composición **ORIGINAL** — PG-09; reparto proporcional a la capacidad **superviviente** — PG-10) | IMPLEMENTED | ADAPTATION + PRODUCT DECISION (PG-09/10 ratificados; ATTACK con carga sigue abierto) | README_COMBAT_ENGINE §22/§24 |
| `DefenseRepairService` (+ `repairRate` configurable, reglas por tipo) | reparación de defensas | `repair_defenses_after_combat` (70 % uniforme; sin regla especial de cúpulas, DG-05) | PARTIAL | INTENTIONAL DIFFERENCE | README_COMBAT_ENGINE §14.21 |
| `DebrisFieldService` + `createDebrisField` | creación de escombros | `create_combat_debris` + `calculate_combat_ship/defense_debris` × `fleet_debris_percentage` / `defense_debris_percentage` (idempotente por batalla) | IMPLEMENTED | MATCH | README_COMBAT_ENGINE §14 |
| `WreckFieldService` + `CleanupWreckFields` + `Space Dock` | campos de restos recuperables | — | MISSING | OUT OF SCOPE | Services; Console |
| `TacticalRetreatService` + `users.tactical_retreat_ratio` | retirada táctica | — | MISSING | OUT OF SCOPE | Services; migrations |
| `BattleReport` (GameMessages) + `BattleReport` model | informe de batalla | `get_player_battle_reports` (contrato autenticado) + vista Mensajes | IMPLEMENTED | ADAPTATION | README_COMBAT_ENGINE |
| `AttackerFleet::getSurvivingCargoCapacity` + `survivingCargo` (proporcional) | carga tras el combate | la carga de LGI **no** forma parte del modelo de batalla (sobrevive íntegra) | PARTIAL | PRODUCT DECISION (PG-09 abierto para ATTACK con carga precargada) | README_FLEET_ENGINE §25 |

## E. BUILDINGS / RESEARCH / SHIPYARD / DEFENSE / LIFEFORMS

| OGameX | Responsabilidad | L.G.I. | Estado | Clasificación | Evidencia |
|---|---|---|---|---|---|
| `BuildingObjects` + `StationObjects` (12: minas, solar, fusión, almacenes, robot/nano factory, shipyard, research lab, terraformer, silo, alliance depot, space dock, lunar base, phalanx, jump gate) | catálogo de edificios | `building_definitions` (**14 LIVE** — la lista de 8 era de 2026-09-21; planet/moon según `valid_kinds`) | PARTIAL | **SHIPPED `fusion_plant` 2026-09-26** (`20260926140000/…40200`, política de combustible resuelta: el reactor se detiene sin deuterio; ver "Real state now") + **`research_lab` SHIPPED 2026-09-26**. PRODUCT DECISION sólo para los que exigen subsistema nuevo: robot/nano factory, terraformer, silo, lunares, depot, space dock | listado LIVE; README_RESEARCH §1; tabla "Real state now" |
| `ResearchObjects` (16) + requisito `research_lab` + `CalculationType::MAX_COLONIES / MAX_EXPEDITION_SLOTS / MAX_FLEET_SLOTS` | catálogo de investigación y efectos de cálculo | `research_definitions` (16) + `research_prerequisites` (16 filas, research→research) + `research_building_prerequisites` (**mecanismo 2026-09-25; 16 gates ACTIVOS desde `20260926180000`**) | PARTIAL | MATCH en catálogo + SHIPPED (laboratorio de investigación + IRN, `20260926180000`) | README_RESEARCH §13-§14 |
| `CivilShipObjects` + `MilitaryShipObjects` (16 + `crawler`) | catálogo de naves | `ship_definitions` (17 con `crawler`) + `ship_prerequisites` (45 filas) | PARTIAL | **SHIPPED `crawler` 2026-09-26** (`20260926140000/…40200`: +0.02 %/unidad, tope `(minas)×8`, 50 energía/unidad; ver "Real state now") | listado LIVE; tabla "Real state now" |
| `DefenseObjects` (8 + `anti_ballistic_missile` + `interplanetary_missile`) | catálogo de defensas | `defense_definitions` (8) + `defense_prerequisites` (18 filas) | PARTIAL | PRODUCT DECISION (misiles + silo) · **SHIPPED `robot_factory` 2026-09-30** (ver "Real state now") | listado LIVE |
| `GameObjectRequirement` (combinación libre de investigación y edificios) | prerequisitos | tres tablas separadas; `building_prerequisites` existe y está **vacía** (0 filas) | PARTIAL | TECHNICAL GAP (mecanismo/contenido de prerequisitos de edificio) | `building_prerequisites` (0 filas) |
| `GameObjectPrice` (metal/crystal/deuterium/**energy** + factor) | coste de objeto | `base_metal/crystal/deuterium` + `cost_factor` — sin dimensión de energía | PARTIAL | INTENTIONAL DIFFERENCE (el coste en energía de gravitón no es expresable) | README_RESEARCH §13 |
| `GameObjectProduction` (fórmulas por objeto; fusión dependiente de energy tech) | producción por objeto | `calculate_planet_production` (minas/solar + factor de energía + tecnologías + lifeform/item) | IMPLEMENTED | ADAPTATION | README_ECONOMY |
| `BuildingQueueService` / `ResearchQueueService` / `UnitQueueService` + `*QueueViewModel` + `ObjectAjaxTrait` | colas, procesado y tiempos de UI | `building_queue`/`research_queue`/`shipyard_queue`/`defense_queue` + `process_*_queue(_until)` + `complete_*`; UI vía `can_start_building`/`can_start_research`/`can_build_ship`/`can_build_defense` | IMPLEMENTED | ADAPTATION | README_SHIPYARD_DEFENSE; README_GAME_ENGINE_AUDIT |
| `ObjectService::objectRequirementsMet` | comprobación de requisitos | `check_ship_requirements`, `check_defense_requirements`, `can_start_building`, `can_start_research`, `can_build_ship/defense` | IMPLEMENTED | ADAPTATION | inventario de funciones |
| `TechtreeController` (`/techtree`) | árbol tecnológico | — | MISSING | OUT OF SCOPE / LOW | Http/Controllers |
| — (OGameX no tiene lifeforms: 1 mención aislada) | especies, edificios, investigaciones, población y efectos | `lifeform_definitions` (4), `lifeform_building_definitions` (48), `lifeform_research_definitions` (72), `planet_lifeforms`, `player_lifeform_discoveries`, `process_lifeform_tick`, efectos consumidos por producción y flota | IMPLEMENTED (LGI-unique) | OUT OF SCOPE | ENGINE_MANIFEST |
| Objetos definidos **en código** (`*Objects.php`) | fuente de verdad del catálogo | definiciones en **tablas** (`*_definitions`) | IMPLEMENTED | ADAPTATION (permite editar el catálogo sin desplegar) | `*_definitions` |

## F. EXPEDITIONS

| OGameX | Responsabilidad | L.G.I. | Estado | Clasificación | Evidencia |
|---|---|---|---|---|---|
| `ExpeditionMission::getOutcomeWeights()` (10 pesos: ships, resources, delay, speedup, nothing, black hole, pirates, aliens, dark matter, merchant) | desenlace aleatorio ponderado | `expedition_settings` (11 pesos, incluye **items**) + `select_expedition_outcome` | IMPLEMENTED | ADAPTATION | ExpeditionMission:67-100; `expedition_settings` |
| Tirada aleatoria por evento | generación del azar | `expedition_event_random(fleet_id, stream)` — **determinista por flota** (reproducible y auditable) | IMPLEMENTED | ADAPTATION (LGI-unique) | `expedition_event_random` |
| `PlayerService::getExpeditionSlotsInUse/Max` (`floor(√astrophysics)` + settings + Discoverer) | slots de expedición | `get_player_expedition_slots` = `1 + expedition_settings.bonus_expedition_slots + objetos activos` (`20260925202506`); `get_active_expedition_count` cuenta las flotas activas | IMPLEMENTED | INTENTIONAL DIFFERENCE (sin `astrophysics`/`Discoverer`) + TECHNICAL GAP **CLOSED 2026-09-25** (`bonus_expedition_slots` ya tiene lector; el cliente usa `get_player_expedition_slot_status()`) | README_FLEET_ENGINE §26 |
| `ExpeditionOutcomeType` (Failed, FailedAndDelay, FailedAndSpeedup, GainShips, GainDarkMatter, GainResources, GainMerchantTrade, GainItems, LossOfFleet, BattlePirates, BattleAliens) | tipos de desenlace | `resolve_expedition_pirates/aliens/black_hole/merchant/item/return` + `select_expedition_delay_multiplier`, `select_expedition_speedup_percentage`, `select_expedition_reward_tier/variant`, `select_expedition_resource_type` | IMPLEMENTED | MATCH | README_FLEET_ENGINE §12 |
| `ExpeditionMission::processArrival` (recursos = carga previa **+** hallazgo) | carga y hallazgo | `resolve_expedition_arrival` (ADITIVO desde `20260925171816`); el informe registra sólo el hallazgo | IMPLEMENTED | MATCH | README_FLEET_ENGINE §25 |
| `processExpeditionGainShipsOutcome` con tope por capacidad de carga | recompensa de naves | `get_expedition_ship_candidates`, `calculate_expedition_ship_quantity/cost/reward_budget`, `expedition_ship_tiers` (12), `calculate_expedition_points_for_ship` | IMPLEMENTED | MATCH | funciones LIVE |
| `PathfinderExpeditionDebrisHarvestTest` + `ReaperDebrisCollectionTest` | recoger escombros en expedición | parcial: `calculate_expedition_pathfinder_multiplier` (bonus de recursos con Pathfinder), sin recolección de escombros | PARTIAL | INTENTIONAL DIFFERENCE | funciones LIVE; tests OGameX |
| Duración/sostenimiento de la expedición | tiempo de espera y retorno | `expedition_hold_seconds` + `calculate_expedition_total_hold_seconds`, `calculate_expedition_delay_seconds`, `calculate_expedition_speedup_seconds` | IMPLEMENTED | ADAPTATION | README_FLEET_ENGINE §12 |
| `DarkMatterService` (recompensa) | materia oscura | `calculate_expedition_dark_matter_amount` + `players.dark_matter` | IMPLEMENTED | MATCH | funciones LIVE |
| Items de expedición (`GainItems`) | objetos | `expedition_item_definitions` (8), `player_expedition_items`, `expedition_item_uses`, `get_active_expedition_item_effect`, `use_expedition_item` (owner-gated y con EXECUTE `authenticated` desde `20260925202506`), `resolve_expedition_item` | IMPLEMENTED | MATCH (LGI más profundo: efectos activos con duración; hasta 2026-09-25 se premiaban pero no podían activarse) | README_FLEET_ENGINE §26 |
| Configuración por universo | pesos del desenlace | **`20260925202506` replicó la configuración del proyecto en el universo ACTIVO** (`cf021ece`): resuelve de verdad (certificado 22/22) | IMPLEMENTED | ADAPTATION | README_FLEET_ENGINE §26 |
| Bonus de slots por ajustes de servidor | slots extra | `get_player_expedition_slots` = 1 + `bonus_expedition_slots` + objetos activos (`20260925202506`); el helper interno queda cerrado a roles cliente y el cliente usa `get_player_expedition_slot_status()` | IMPLEMENTED | MATCH | README_FLEET_ENGINE §26 |

## G. IDENTITY / OWNERSHIP / SECURITY (vista arquitectónica)

| OGameX | Responsabilidad | L.G.I. | Estado | Clasificación | Evidencia |
|---|---|---|---|---|---|
| Laravel Fortify + sesión + middleware `GlobalGame` (`$player->planets->current()`) | identidad y contexto de juego | `auth.uid()` → `players.user_id` → `players.id` → planeta/flota del jugador; `provision_player(text,text)` (SECURITY DEFINER, search_path vacío) | IMPLEMENTED | ADAPTATION: la autoridad vive en SQL, no en un middleware PHP | README_IDENTITY_AND_ACCESS |
| Controladores + servicios que resuelven el dueño desde la sesión | autorización de operaciones | 73 `SECURITY DEFINER` + 103 RPC con EXECUTE para `authenticated` + gates `auth.uid()`/`PLAYER_NOT_OWNED` | IMPLEMENTED | ADAPTATION | `information_schema.routine_privileges` |
| (sin RLS: la autorización es de aplicación) | aislamiento de datos | RLS en 66 tablas / 66 políticas (lectura por dueño) | IMPLEMENTED | ADAPTATION | `pg_policies` |
| (sin triggers de propiedad) | protección de escritura directa | 15 triggers `trg_enforce_player_write_*` sobre colas y `fleet_movements` | IMPLEMENTED | ADAPTATION (LGI-unique) | `pg_trigger` |
| `Admin` middleware + roles/permisos (`spatie/permission`) | administración | `dashboard_widgets` + tablas de admin; sin modelo de roles/permisos equivalente | PARTIAL | OUT OF SCOPE | Http/Middleware; tablas |
| `IsolatedAccountUserTest` + `CreatesForeignFixtures` | aislamiento entre cuentas | pruebas de ownership y ACL (hardening 2026-09-18/21) | IMPLEMENTED | MATCH | README_OWNERSHIP_HARDENING |
| (sin sesiones invitado) | sesiones anónimas | LGI tuvo invitados: retirados, con **residuo** (migración `20260920120800` sin aplicar; ramas `is_guest` en los dispatchers y `EXECUTE` de `anon` en algunos RPC) | PARTIAL | TECHNICAL GAP (hardening decidido, pendiente) | PROJECT_CONTEXT §7 |
| `PaymentController` + `ShopController` | pagos y compras | — | MISSING | OUT OF SCOPE | Http/Controllers |

## H. ARQUITECTURA TRANSVERSAL (autoridad, proceso, observabilidad)

| OGameX | Responsabilidad | L.G.I. | Estado | Clasificación | Evidencia |
|---|---|---|---|---|---|
| Controllers → Services → Eloquent Models (petición/respuesta PHP) | camino de ejecución | RPC/`SECURITY DEFINER` en Postgres + `src/` como presentación (nunca autoridad) | IMPLEMENTED | ADAPTATION | README_ARCHITECTURE |
| Laravel Scheduler + colas (`Jobs`) | trabajo diferido | `pg_cron` (2 jobs) + reloj persistido + catch-up en SQL | IMPLEMENTED | ADAPTATION | `cron.job`; ENGINE_MANIFEST |
| Constantes y definiciones en código | fuente de verdad del contenido | tablas `*_definitions` editables en base de datos | IMPLEMENTED | ADAPTATION | tablas de definición |
| i18n en ficheros `lang/*` + `GameMessages` | textos y mensajes | mensajes de error de los contratos (strings en SQL) + textos de UI en el frontend; `player_messages` existe y está **dormida** (0 productores/lectores) | PARTIAL | TECHNICAL GAP (mensajería interna) | `player_messages` |
| Pest: ~80 Feature + ~30 Unit tests | cobertura de comportamiento | 18 fixtures SQL transaccionales (`supabase/tests/`) ejecutadas LIVE con ROLLBACK | PARTIAL | ADAPTATION (la cobertura vive en SQL; no replica el volumen de OGameX) | `supabase/tests/` |
| Debugbar, logs, `TestRaceCondition*` commands | observabilidad y prueba de concurrencia | `universe_process_health` + monitor público saneado + `pg_cron` `run_details`; la concurrencia se prueba con replays/locks, sin arnés dedicado | PARTIAL | ADAPTATION + TECHNICAL GAP (sin arnés real de concurrencia) | README_UNIVERSE_EVOLUTION_MONITOR; `universe_process_health` |
| `ViewModels` (Building/Research/Unit/Galaxy/Queue) | proyección de UI | vistas de análisis (`*_action_candidates`, `empire_*`, `next_action`) + frontend que consume RPCs de contrato | PARTIAL | ADAPTATION (LGI añade una capa analítica que OGameX no tiene) | 21 vistas LIVE |

## OPEN GAPS

`CRITICAL` = bloquea otras mecánicas · `HIGH` = funcional e importante, no bloqueante · `MEDIUM` = puede
esperar · `LOW` = menor. Cada entrada cita su evidencia; ninguna se ha implementado.

### CRITICAL
- **Agrupación ACS / multi-atacante** — bloquea `DEFEND`, la liquidación multi-atacante, el late-join y el
  reparto por flota. Evidencia: `start_support_fleet` rechaza `DEFEND` (`COMBAT_SUPPORT_NOT_READY`), el motor
  no crea participantes `DEFENDER/FLEET` y la liquidación falla cerrada. Estado: PRODUCT DECISION (paquete
  PG-08/09/10/17/18 ya decidido; falta el **productor** que crea/une participantes).
- **Lunas** — no existen tipo luna, `lunar_base`, `sensor_phalanx`, `jump_gate` ni destrucción lunar; bloquea
  falanx, salto y toda la parte lunar de la flota. Evidencia: `planets` sin tipo; OGameX `PlanetType` con
  `Moon`/`DebrisField`/`DeepSpace`. Estado: PRODUCT DECISION.

### HIGH
- **`expedition_settings` ausente en el universo del humano** (`cf021ece-…`): `resolve_expedition_arrival`
  lanza `Invalid expedition weights for universe`, así que las expediciones **no pueden resolverse** en ese
  universo. Evidencia: consulta LIVE + fixture 2026-09-25 (README_FLEET_ENGINE §25). Estado: PRODUCT DECISION
  (es una fila de configuración; faltan los pesos).
  → **CLOSED 2026-09-25** (`20260925202506`): la fila se replicó en el universo activo con los pesos que el
  propio proyecto ya tenía configurados (mismos valores, provenance en el repositorio) y la resolución real
  está certificada (README_FLEET_ENGINE §26).
- **ATTACK con carga precargada** — `apply_attack_loot` usa la capacidad de la composición ORIGINAL (PG-09) y
  no contempla la carga; OGameX escala la carga con los supervivientes y limita el retorno a la capacidad
  superviviente. Estado: **OPEN PRODUCT DECISION** (no inventar la regla).
- **Fleet slots (`computer_technology`)** — no existe límite de flotas simultáneas. Evidencia: `fleet_slot` /
  `max_fleet` → NONE en `prosrc`; sólo hay slots de expedición. Estado: PRODUCT DECISION.
- **Cupo de colonias y gating de posición (`astrophysics`)** — no existe cupo ni restricción por posición.
  Evidencia: `max_planet` → NONE; `resolve_colonize_arrival` con `fields_total = 100` fijo. Estado: PRODUCT
  DECISION.
- **IRN / laboratorios de investigación** — sin edificio de laboratorio y sin prerequisitos de edificio para
  investigación. Evidencia: `research_prerequisites` sólo research→research; 0 edificios de laboratorio.
  Estado: PRODUCT DECISION (auditoría cerrada; no reabrir).
- **Contra-espionaje / pérdida de sondas** — el informe se emite siempre y las sondas siempre regresan.
  Evidencia: `resolve_espionage_arrival`; en OGameX `CounterEspionageService` + `EspionageMission:112-178`.
  **Fórmula verificada verbatim el 2026-09-26**:
  `chance% = floor(clamp(0..100, naves_defensor × (nivel_esp_defensor − nivel_esp_atacante + 1) / (sondas × 4) × 100))`
  (dado 1..100; 0 → nunca, 100 → siempre) y, si dispara, OGameX resuelve una batalla entre las sondas y las
  naves del defensor (defensa excluida). Implementarlo exige esa batalla + decidir si las sondas destruidas
  dejan escombros → detalle en `README_ESPIONAGE_ENGINE.md` §4. Estado: PRODUCT DECISION.
- **Comportamiento de la IA** — la población IA se reconcilia pero no actúa; OGameX tiene `NPCPlanetService`,
  `NPCPlayerService`, `NPCFleetGeneratorService`. Evidencia: ningún dispatcher invocado por IA. Estado:
  NEEDS INVESTIGATION (no se afirma gap: requiere definir el comportamiento deseado).

### MEDIUM
- Colas: cancelación implementada para **building y research** (2026-09-26, reembolso 100 % del precio
  cobrado); shipyard y defensa siguen sin cancelación por paridad OGameX («unit queue objects cannot be
  canceled») y sus filas `COMPLETED` siguen sin purgar.
  → **CLOSED en el cliente 2026-09-27**: la UI los consume (`src/App.tsx`, control CANCELAR de la cola activa) y
  `supabase/tests/queue_cancellation_ui_contract.sql` fija la forma de llamada, las columnas devueltas, la
  precondición de estado y el reembolso de demolición (13 PASS + 2 INFO LIVE, rolled back).
- Ranking: `players.points` / `rank` **IMPLEMENTADO 2026-09-26** (`20260926091604`): `calculate_player_points`,
  `recalculate_player_points`, `recalculate_universe_ranking`, `get_universe_ranking`
  (17 PASS + 1 INFO en `supabase/tests/player_ranking_points.sql`; detalle en `README_RANKING.md`). Sin
  scheduler: los dos RPC de refresco son `service_role` y nadie los invoca todavía → GAP de planificación.
- Mensajería interna: `player_messages` sin productores; **infraestructura endurecida y ya legible 2026-09-26**:
  `20260926091605` cerró la política `USING (true)` con grants de escritura a `anon`, y
  `20260926095835` añadió el contrato owner-scoped (`get_player_messages`, `mark_message_read`; 12 PASS + 1 INFO
  junto con el contrato de informes de espionaje). Sigue sin productores: qué evento se convierte en mensaje es
  una decisión de producto.
- Prerequisitos de edificio: `building_prerequisites` **vacía** y, verificado el 2026-09-26, correctamente
  vacía: ninguno de los 8 edificios LGI tiene un requisito de edificio en OGameX (los que existen, p. ej.
  `shipyard → robot_factory 2`, dependen de edificios que LGI no define). El único par respaldado por OGameX es
  `fusion_plant → deuterium_synthesizer 5 + energy_technology 3`, que además exige la dimensión
  edificio→investigación (inexistente: `can_start_building` / `start_building` sólo leen
  `building_prerequisites`, que es edificio→edificio) → forma parte de la decisión de producto de la fusión.
- `fusion_plant`: **IMPLEMENTADO 2026-09-26** (`20260926140000/…40100/…40200`) — la decisión de producto de la política de combustible
  quedó resuelta e inscrita (el reactor se detiene sin deuterio). `crawler`: **IMPLEMENTADO** el mismo día
  (+0,02 % por unidad, tope por minas). Ambos re-certificados LIVE el 2026-09-29 (10 PASS). Ver "Real state now".
- `expedition_settings.bonus_expedition_slots` sin lector (configuración muerta).
  → **CLOSED 2026-09-25**: leído por `get_player_expedition_slots` (base + ajustes + objetos) y expuesto al
  cliente por `get_player_expedition_slot_status()`.
- Objetos de expedición premiados pero no activables (`use_expedition_item` huérfana y sin EXECUTE cliente).
  → **CLOSED 2026-09-25** (`20260925202506`): owner-gated, con EXECUTE `authenticated`; los seis efectos
  verificados en sus consumidores (README_FLEET_ENGINE §26).
- `calculate_building_production_delta` BROKEN (columnas inexistentes) y 3 procesadores de investigación huérfanos.
- ACL del cálculo de flota: `calculate_fleet_distance`, `calculate_fleet_travel_time` y
  `calculate_fleet_distance_to_coordinates` conservaban el grant `PUBLIC`/anon/authenticated siendo helpers
  internos (el último, sólo `PUBLIC`).
  → **CLOSED 2026-09-25** (`20260925211615` + `20260925211804`): sólo `service_role`; los cuatro dispatchers
  (SECURITY DEFINER, `postgres`) conservan EXECUTE y `src/**` no los invocaba (README_FLEET_ENGINE §27.2).
- Sin arnés real de concurrencia (la idempotencia se prueba por replays).

### LOW
- Árbol tecnológico (`/techtree` en OGameX), wreck fields, retirada táctica, plantillas de flota,
  movimiento/abandono de planeta, notas/chat/buddies, comerciante general, regeneración de materia oscura,
  reset de escombros, limpieza de planetas destruidos.
- Claves declaradas y nunca aplicadas (`civilian_ship_speed_percent`, `recall_fuel_recovery_percent`).
- Residuo de autorización invitado (`20260920120800` sin aplicar).

### PRODUCT DECISIONS (no las debe tomar el agente)
```text
1.  ATTACK: ¿la carga precargada se pierde proporcionalmente a los supervivientes (OGameX) o sobrevive
    íntegra (LGI hoy)? ¿el saqueo descuenta la carga precargada de la capacidad (PG-09)?
2.  PG-09 (capacidad de saqueo) y PG-10 (destinatario/reparto) — decididos en el acta; ratificación pendiente
    (README_COMBAT_ENGINE §22).
3.  Pesos de `expedition_settings` para el universo del humano. → **RESUELTO 2026-09-25** reutilizando la
    configuración que el propio proyecto ya había definido (mismos valores); siguen siendo un dato ajustable
    por producto.
4.  ¿Se adopta el cupo de colonias (astrophysics) y el gating de posiciones?
5.  ¿Se adopta el límite de flotas (computer_technology)?
6.  ¿Se adopta IRN con laboratorios de investigación?
7.  ¿Entran las lunas (base lunar, falanx, puerta de salto, destrucción lunar) en el alcance del producto?
8.  ¿Se adopta economía premium (gasto de DM: halving/instantáneo, comerciante, tienda)?
9.  ¿Debe la IA actuar (flotas, ataques) o permanecer pasiva como población de fondo?
10. Convención de hull: ¿se reconcilia con OGameX (SI/10 una sola vez) o se mantiene la escala propia de LGI?
11. ¿Se adopta el contra-espionaje con pérdida de sondas?
12. Cancelación de colas: ¿existe y con qué reembolso?
```

## NEXT CANDIDATES

Lista **factual** (sin ranking ni puntuación). La selección final no la hace el agente.

```text
1. `expedition_settings` para el universo del humano
   evidencia:  la tabla tiene 1 fila (universo 86900cbc) y ninguna para cf021ece; `resolve_expedition_arrival`
               lanza 'Invalid expedition weights for universe' (README_FLEET_ENGINE §25, medido 2026-09-25)
   dependencia: ninguna técnica — es una fila de configuración
   riesgo:      técnico bajo · requiere decidir los pesos (producto)
   estado:      PRODUCT DECISION (deja inoperativa una mecánica ya implementada en ese universo)
   → DONE 2026-09-25: replicado en el universo activo con los pesos ya definidos por el proyecto y certificado
     (README_FLEET_ENGINE §26); los pesos siguen siendo datos ajustables por producto.

2. Prerequisitos de edificio para investigación (base de laboratorios de investigación e IRN)
   evidencia:  `research_prerequisites` sólo research→research; OGameX exige `research_lab` en 12+ tecnologías
               (`ResearchObjects.php`); IRN ya auditado como PRODUCT DECISION
   dependencia: edificio de laboratorio (producto) y extensión del modelo de prerequisitos
   riesgo:      medio — toca el contrato de investigación hoy certificado
   estado:      PRODUCT DECISION

3. Cancelación de cola con reembolso (building / research / shipyard / defense)
   evidencia:  los 4 CHECK admiten `CANCELLED` y **ninguna** función lo escribe; OGameX tiene `cancel()`,
               `addDowngrade()` y `HalvingService` (DM)
   dependencia: ninguna técnica
   riesgo:      medio — la política de reembolso es una decisión de producto y afecta a la economía
   estado:      **DONE 2026-09-26 para building y research** (`cancel_building` / `cancel_research`, LIVE
                `20260926082120` + fix de ambigüedad `20260926082529`, 13 PASS + 1 INFO en
                `supabase/tests/queue_cancellation.sql`). La política de reembolso NO se inventó: OGameX
                `BuildingQueueService::cancel()` devuelve exactamente el precio almacenado de un ítem ya
                iniciado (100 %, sin penalización) y el reembolso LGI se recalcula con la misma función de
                coste que cobró. `UnitQueueService` documenta que las unidades NO se pueden cancelar, así que
                shipyard y defensa quedan deliberadamente sin cancelación (paridad OGameX, no un hueco).
                Queda como PRODUCT DECISION solo el multi-ítem, el reembolso de demolición (+1 % de ion) y la
                aceleración con DM.

4. `fusion_plant`
   evidencia:  contrato OGameX (900/360/180, factor 1.8; requisitos `deuterium_synthesizer 5` +
               `energy_technology 3`; energía `30·L·(1.05 + 0.01·energy_technology)^L`) **verificado el
               2026-09-26 contra `BuildingObjects.php` @ 7c420bad**, que además define un consumo que el
               registro anterior no recogía: `deuterium_formula = -10·L·1.1^L`.
   dependencia: no es «una rama de fórmula». El consumo no puede viajar en `deuterium_per_hour` porque el
               asentamiento divide la producción/hora por (economía × producción) del universo y la
               pondera por evolución: un consumo absoluto quedaría escalado por la velocidad del universo.
               Modelar el consumo exige además decidir qué pasa cuando el deuterio no alcanza (OGame para
               el reactor) — política que LGI no tiene y que el modelo de energía no puede expresar.
   riesgo:      alto si se publica a medias: una `fusion_plant` sin consumo sería energía gratuita y
               distorsionaría la economía certificada.
   estado:      PRODUCT DECISION (decisión de producto, no técnica) — **deliberadamente NO implementado**.
                Todo el contrato está determinado y registrado; falta la decisión de política de combustible
                (y, si se adopta el laboratorio, su gate `research_lab 12`, que LGI no representa).

5. `crawler`
   evidencia:  OGameX id 217 + `template/hangar.txt` (taladradores, +0,02 % M/C/D por unidad, tope por minas)
   dependencia: producción por unidad + regla del tope
   riesgo:      medio — afecta a la producción de todos los planetas
   estado:      PRODUCT DECISION (tope) + TECHNICAL GAP

6. Lunas (tipo de planeta + base lunar / falanx / puerta de salto / destrucción lunar)
   evidencia:  OGameX `PlanetType::Moon`, `CreateLegorMoon`, `JumpGateService`, `PhalanxService`,
               `MoonDestructionMission`, `MoonFieldRestrictionTest`
   dependencia: extender el modelo de planeta (tipo luna) con ownership y RLS
   riesgo:      alto — toca planetas, combate, flota y visibilidad
   estado:      PRODUCT DECISION (gating de alcance)

7. Ranking / puntuaciones
   evidencia:  `players.points` y `players.rank` existen; no hay job que los recalcule (OGameX:
               `GenerateHighscores`/`GenerateHighscoreRanks` cada 5 min; `get_universe_top1_points` sólo lee)
   dependencia: fórmula de puntos
   riesgo:      técnico bajo
   estado:      TECHNICAL GAP + PRODUCT DECISION (fórmula)

8. Wreck fields (campos de restos recuperables)
   evidencia:  OGameX `WreckFieldService`, `CleanupWreckFields`, `Space Dock`, tests dedicados; LGI no tiene
               tabla ni hook
   dependencia: enganche post-combate (`create_combat_debris` ya existe) + `space_dock`
   riesgo:      medio
   estado:      OUT OF SCOPE actual (requiere decisión de alcance)

9. Comportamiento de la IA
   evidencia:  OGameX `NPCPlanetService`/`NPCPlayerService`/`NPCFleetGeneratorService`; LGI sólo reconcilia
               densidad (`reconcile_universe_ai_population`), sin dispatchers invocados por IA
   dependencia: despacho de flotas por IA + reglas de comportamiento
   riesgo:      alto — equilibrio y carga del worker
   estado:      NEEDS INVESTIGATION

10. Convención de hull frente a OGameX
    evidencia:  `get_combat_ship_hull`/`get_combat_defense_hull` aplican `(hull/10)` a un `hull` que ya es SI/10
                (OGameX aplica la división una sola vez) → 1/10 del hull efectivo con ataque/escudo idénticos
    dependencia: decisión de balance
    riesgo:      alto — motor de combate certificado y sus 8 fixtures
    estado:      PRODUCT DECISION

11. Contra-espionaje con pérdida de sondas
    evidencia:  OGameX `CounterEspionageService` — fórmula verificada verbatim el 2026-09-26:
                `chance% = floor(clamp(0..100, naves_defensor × (nivel_esp_defensor − nivel_esp_atacante + 1)
                / (sondas × 4) × 100))`, dado 1..100, y batalla sondas vs naves del defensor en
                `EspionageMission:112-178`. LGI emite siempre el informe y devuelve las sondas
    dependencia: batalla con el motor de combate contra las naves del defensor + decidir si las sondas
                destruidas dejan escombros y si el defensor recibe aviso
    riesgo:      medio — cambia economía de combate si se implementa sin la decisión de escombros
    estado:      PRODUCT DECISION (fórmula determinada; política batalla/escombros no). Detalle en
                `README_ESPIONAGE_ENGINE.md` §4; NO implementado a propósito
```

## LIMITATIONS OF THIS MAP

- **OGameX se leyó de forma dirigida** (listados completos de `app/**` + lectura de los ficheros clave:
  `*Objects.php`, `GameMission`, `PlanetService`, `BattleUnit`, `PhpBattleEngine`, misiones, `routes/*`,
  `console.php`). Los servicios grandes (`WreckFieldService`, `HalvingService`, `MerchantService`,
  `PhalanxService`, `AllianceService`, `CharacterClassService`, `HighscoreService`) se citan por **firma y rol**,
  no por lectura completa → sus filas no afirman fórmulas.
- Las cifras LIVE se midieron el **2026-09-25** (236 funciones, 87 relaciones, 66 políticas RLS, 2 jobs `pg_cron`,
  198 índices). El motor cambia por sí solo (expansión de galaxias y población IA).
- Las filas `NEEDS INVESTIGATION` están marcadas explícitamente y **no** deben leerse como gaps.
- Este documento **resume y enlaza**: el detalle normativo sigue en los READMEs de dominio
  (`docs/systems/README_*.md`). Cuando un gap se cierre, actualizar **su fila** aquí y el README de dominio;
  no duplicar análisis extensos en `docs/PROJECT_CONTEXT_PROMPT.md`.

## GAMEPLAY COMPLETION SWEEP — status update (2026-09-26)

This section supersedes the rows it names above (`PARTIAL` / `PRODUCT DECISION` / `TECHNICAL GAP`). It is written by
the implementation mission, not by a new audit; the evidence is the LIVE migrations and the fixtures listed here.
LIVE history was repaired to match the repository file names (10 rows: `20260926120000` … `20260926124035`).

### Promoted to IMPLEMENTED (LIVE 2026-09-26, tested)

| Subject (row above) | Real state now | Evidence |
|---|---|---|
| Fleet limit `1 + computer_technology` (A — was PRODUCT DECISION) | **IMPLEMENTED + ENFORCED server-side** for every dispatch path | `20260926121000_fleet_slots_enforcement`; `tests/fleet_slots_enforcement.sql` 6 PASS |
| Fleet recall (LOW: «retirada táctica») | **IMPLEMENTED** (owner-gated, atomic, mirror leg, cargo preserved, replay-safe) | `20260926122000_fleet_recall_contract`; `tests/fleet_recall.sql` 7 PASS |
| Espionage: counter-espionage, probe loss, debris, defender notice (D — was PRODUCT DECISION) | **IMPLEMENTED** against the existing Combat Engine | `20260926124000/…4010/…4020/…4030/…4035`; `tests/counter_espionage.sql` 13 PASS |
| Espionage: reveal gating of report contents (jump 11, «no level gating») | **IMPLEMENTED** (OGameX `canRevealData`) | same migrations; fixture assertions 3 and 12 |
| Ranking refresh job (A — TECHNICAL GAP) | **IMPLEMENTED + SCHEDULED** every 5 minutes (`lagranimplosion-ranking-refresh`) | `20260926123000_ranking_refresh_scheduler`; `tests/ranking_refresh_worker.sql` 6 PASS |
| Messages: producers (messaging block) | **IMPLEMENTED** — Messages is now the central event inbox | `20260926120000/…20010`; `docs/systems/README_MESSAGING_ENGINE.md` |
| Ranking / fleet-slot / recall / espionage UI (jumps 54/55) | **IMPLEMENTED (basic)** — no new architecture, no authority in the client | `src/GameplayEnginePanel.tsx`, `src/App.tsx` |

ACS settlement (PG-08/09/10/17/18) was ALREADY implemented by the previous block (`20260922060013` +
`20260923095315`); this mission verified it is in the LIVE history and did not rewrite the Combat Engine.


### Still open after this sweep (with the evidence already gathered)

```text
1. MOONS (jump 6 — answered "implement now"; NOT delivered)
   BLOCKED BY A SCHEMA DECISION, not by missing rules. The rules are recorded below so a follow-up needs no
   re-research:
     model        OGameX PlanetType::Moon: one moon per planet, SAME coordinates, own buildings and resources.
                  LGI `planets` has UNIQUE (universe_id, galaxy, system, position): shared coordinates require
                  dropping it, adding two partial unique indexes plus a kind/parent link, and re-checking every
                  certified coordinate lookup (worker colonisation guard, galaxy view, distance helpers). That is
                  the "modelar correctamente su identidad" decision this block could not take safely in its
                  remaining budget.
     creation     chance% = floor(debris.total / 100 000) clamped to the universe maximum; roll 1..100.
                  diameter = floor(sqrt(x + 3 × debris / 100 000) × 1000), x ∈ [10, 20] random, capped at 8 944 km.
                  field_max = 1 (LGI has no character classes); temp_max = average position temperature,
                  temp_min = temp_max − 40.
     lunar_base   id 41, 20 000 / 40 000 / 20 000, factor 2, MOON only, no prerequisites, +3 fields per level.
     sensor_phalanx id 42, 20 000 / 40 000 / 10 000, factor 2, requires lunar_base 1, MOON only;
                  range = level² − 1 systems each direction (same galaxy), 5 000 deuterium per scan.
     jump_gate    id 43, 2 000 000 / 4 000 000 / 2 000 000, factor 2, requires lunar_base 1 +
                  hyperspace_technology 7, MOON only; the destination moon needs its own gate;
                  cooldown = (60 / war_fleet_speed) minutes × (1 − 0.10 × (level − 1));
                  not transferable: solar_satellite, crawler.
     destruction  only against a foreign moon and with ≥ 1 Deathstar;
                  success = clamp(0, 100, (100 − sqrt(diameter)) × sqrt(deathstars));
                  Deathstar loss = clamp(0, 100, sqrt(diameter) / 2); a real battle runs first, then the roll;
                  a destroyed moon must not leave orphan relations.
2. FUSION PLANT (jump 4 — answered "implement now"; NOT delivered)
   The FORMULA is fully determined and recorded (900/360/180 factor 1.8; deuterium_synthesizer 5 +
   energy_technology 3; energy `30·L·(1.05 + 0.01·energy_technology)^L`; deuterium consumption `−10·L·1.1^L` per
   hour). What is NOT determined is how LGI's linear devengo (`update_planet_resources_until`, a closed-form
   accrual capped by storage) expresses OGame's «the reactor stops when the tank is empty»: the fuel gate makes the
   accrual state-dependent, and shipping the building without that gate would create FREE ENERGY — explicitly
   forbidden by the mission. It needs one economy decision (per-interval gate vs. event-driven fuel check) plus a
   re-test of the certified economy.
3. CRAWLER (jump 5 — answered "implement now"; NOT delivered)
   Rules recorded (id 217, 2 000/2 000/1 000, shipyard 4 + combustion_drive 4 + armor_technology 4 +
   laser_technology 4, planet only, +0.02 % M/C/D per unit with a cap tied to the mine levels, energy consumption,
   and an overload percentage the schema does not have). It touches the same devengo as the fusion plant, so it was
   left with it rather than half-shipped.
4. AI BEHAVIOUR (jump 9 — answered "active basic AI"; NOT delivered)
   Blocked by the ownership contract every dispatcher enforces: `start_building`, `start_research`, `start_ship`
   and `start_fleet*` derive the actor from `auth.uid()` (plus `enforce_player_write_access`), and an AI player has
   no session. An AI tick therefore needs its own service-role contract with an explicit actor parameter and the
   same ownership cross-checks — a new contract, not a workaround. OGameX reference: `NPCPlanetService`,
   `NPCPlayerService`, `NPCFleetGeneratorService`.
5. DEMOLITION (jump 3 — answered "only with sufficient certainty"; GAP)
   OGameX `BuildingQueueService::addDowngrade()` exists, but the refund / ion-technology policy could not be read
   with certainty here; the queue cancellation contract (100 % refund of a started item) remains the only refund
   path. Not invented.
6. Wreck fields, tactical retreat, planet relocation, notes/chat/buddies, dark-matter regeneration and premium
   economy: OUT OF SCOPE (unchanged).
```

### Verification performed with this sweep

```text
git diff --check ... clean (only LF→CRLF advisories)
npx tsc -b ......... exit 0
npm run build ...... worker + client bundles emitted by Vite (its reporting plugin writes to stderr, which
                     PowerShell surfaces as a non-zero exit code; the build itself completed)
LIVE ↔ repo ........ 10 new migrations, history repaired to the file-name convention
residue ............ 0 (every fixture ends in ROLLBACK and asserts its own writes)
NOT RE-RUN ......... the pre-existing suites that received the fleet-slot fixture prerequisite were not executed
                     again in this session (they only gained a computer_technology level; no assertion changed)
```


## GAMEPLAY COMPLETION SWEEP II — status update (2026-09-26, second pass)

Supersedes the named rows below/above. Evidence = the LIVE migrations + fixtures listed; no new audit was performed.

### Promoted to IMPLEMENTED

| Subject (row above) | Real state now | Evidence |
|---|---|---|
| `fusion_plant` (NEXT CANDIDATES 4 — was PRODUCT DECISION / deliberately not implemented) | **IMPLEMENTED**: 900/360/180 factor 1.8, deuterium_synthesizer 5 + energy_technology 3, energy `30·L·(1.05+0.01·ET)^L`, fuel burn `10·L·1.1^L` inside the authoritative rate, reactor stops without deuterium | `20260926140000/…40100/…40200`; `tests/fusion_and_crawler.sql` 10 PASS; README_ECONOMY |
| `crawler` (NEXT CANDIDATES 5 — was PRODUCT DECISION + TECHNICAL GAP) | **IMPLEMENTED**: id 217, shipyard 4 + combustion_drive 4 + armour_technology 4 + laser_technology 4, planet only, `+0.02 %` of mine output per effective unit, cap `(mines)×8`, energy 50/unit | same fixture; README_ECONOMY |
| Planet-kind authority (`valid_planet_types` was absent in LGI) | **IMPLEMENTED**: `building_definitions.valid_kinds` + `ship_definitions.valid_kinds` with one trigger per family, aligned with OGameX (empty list = both kinds) | `20260926130100/…140000/…140100`; moon fixture 7/9/10 |
| AI ownership blocker (jump 9 — NEEDS INVESTIGATION / failed for lack of session) | **CONTRACT IMPLEMENTED**: `ai_actor_begin` / `is_ai_actor_target` / `ai_actor_end` + gate integration, AI acts through the same dispatchers; no gate weakened | `20260926150000/…150100`; `tests/ai_service_actor.sql` 9 PASS; README_AI_ENGINE |
| Moon polish D2/D3/D4 (see README_MOON_ENGINE §9) | phalanx outputs verified; `MoonsPanel` UI added; kind gate closed; D1 future; D5 product decision | `src/GameplayEnginePanel.tsx`, README_MOON_ENGINE §9 |
| `robot_factory` (was GAP-05 "TECHNICAL GAP, cero bloqueos") | **IMPLEMENTED / LIVE VERIFIED**: `building_definitions.robot_factory` 400/120/200 factor 2, PLANET only, no prerequisite; `calculate_robot_factory_build_speed(planet)` returns `1 + level`; the divisor is applied at ONE point per queue family — `calculate_ship_build_time`, `calculate_defense_build_time`, `calculate_research_time(uuid,uuid,text,integer)`, and a new planet-aware `calculate_building_time(text,int,uuid,uuid)` overload used by `start_building` + `get_planet_building_preview`. Research inclusion is an explicit product decision. E2E fixture 14 PASS + 1 INFO | `20260930090000_robot_factory.sql`; `tests/robot_factory.sql`; classic OGame wiki "Robotics Factory" (`Build time = Base time / (1 + R)`, 2026-05-16) |

### Still open after this pass (evidence gathered, classification recorded)

```text
1. AI BEHAVIOUR POLICY (jump 9) — the execution contract exists; the policy (priority list, cadence, per-tick
   budget, reserve, colonisation/expedition and attack rules) is a PRODUCT DECISION. OGameX runs NPC work from
   console/queue services and does define such policies, but they are tuned to its own settings; transcribing them
   would be inventing a policy here. README_AI_ENGINE.md §4 lists exactly what is missing.
2. WRECK FIELDS (jump / low) — OGameX `WreckFieldService` + Space Dock + `CleanupWreckFields`. LGI has no table, no
   building and no cleanup job: a new subsystem → PRODUCT DECISION / OUT OF SCOPE.
3. FUSION `research_lab` gate - **CLOSED 2026-09-26** (`20260926180000`). This line previously read
   'LGI has no laboratory building (the same open decision recorded for the 14 research gates)'. That is no
   longer true: `research_lab` exists and all 16 OGameX laboratory gates are enforced. Reconciled 2026-09-28.
4. CRAWLER OVERLOAD — player-set 0–150 % does not exist in LGI; 100 % (OGame default) is what is implemented.
5. DEDICATED MOON DESTRUCTION MISSION — the mechanic works through the ATTACK + Deathstar hook; a first-class
   mission type would touch the certified dispatch/worker pipeline → FUTURE.
6. Everything else in the earlier "still open" list is unchanged (demolition refund policy, dark-matter
   regeneration, premium economy, tactical retreat, planet relocation, notes/chat/buddies, alliance ranking).
```

### OGameX classification for this pass

```text
fusion plant      FOUND (BuildingObjects id 12 + GameObjectProduction::calculateMine) → ADAPTED (fuel policy: OGame
                  rule instead of OGameX's unconditional formula, because the latter creates free energy)
crawler           FOUND (CivilShipObjects id 217 + calculateCrawlerProduction / getMaxUsableCrawlers /
                  getCrawlerEnergyConsumption) → ADAPTED (multiplicative vs additive bonus ordering documented)
kind gates        FOUND (ObjectService::isObjectValidForPlanetType, empty list = both) → ADAPTED (data + triggers)
AI actor          FOUND (NPC* services run outside the web session) → ADAPTED (explicit declarable actor); the
                  behaviour policies were NOT copied (they would be an invented policy)
wreck field       FOUND but INCOMPATIBLE with the current LGI schema (no table/building) → PRODUCT DECISION
moon destruction
mission type      FOUND (MoonDestructionMission) but NOT ADOPTED (the outcome hook already implements the rules)
```

## Demolition / downgrade — CLOSED (2026-09-26)

```text
OGameX source   BuildingQueueService::addDowngrade()/start(), ObjectService::getObjectDowngradePrice()/
                canDowngradeBuilding(), PlanetService::getBuildingDowngradeTime(), BuildingQueue.is_downgrade
LGI adaptation  building_queue.is_downgrade + `target_level >= 0`; new start_demolition / can_start_demolition /
                inspect_demolition (single authority) + calculate_building_demolition_cost; complete_building
                and cancel_building patched (the certified upgrade contract is byte-for-byte preserved).
Rules adopted   Demolishing COSTS the construction price of the level being removed, reduced by 4 % per
                ion_technology level (floor per resource, never negative); duration = the construction formula
                at the removed level (1 s floor); one level per queue item; level 0 reachable; blocked by a
                present building that needs the level, by an active research that needs it, by an active
                ship/defense order that needs it, and by a busy building queue; cancelling refunds exactly
                what the demolition charged.
Adaptations     LGI queues one building item per planet, so OGameX "level_after_queue" is always the current
                level; OGameX's hardcoded research_lab / missile_silo / terraformer guards become data-driven
                checks on research_building_prerequisites / ship_prerequisites / defense_prerequisites (LGI has
                none of those objects); fields_used mirrors the certified +1 per level with -1 per demolished
                level; a fully demolished building keeps its planet_buildings row at level 0 because every
                reader aggregates with COALESCE/MAX(level) and the UPDATE keeps trg_sync_moon_field_capacity
                firing (a DELETE would silently skip the moon re-sync).
Test            supabase/tests/building_demolition.sql — 18/18 PASS LIVE (transactional, ROLLBACK, residue 0)
LIVE            20260926160000_building_demolition (history version = repository file prefix)
UI              minimal control in the buildings view (preview + confirm) — server remains the authority
```

### State of the transversal sweep III (2026-09-26)

```text
CLOSED                        demolition / downgrade (above)
                              ranking per-bucket scores (OGameX HighscoreService types 1/2/3) — columns,
                              calculator, per-category ranks, category read contract and UI selector
                              research_lab + the 16 research gates + IRN — definition (200/400/200, factor 2,
                              PLANET only), the OGameX gate table filled into the certified mechanism and the
                              laboratory network applied to the research time (OGameX divisor ratio)
                              dedicated moon-destruction mission — CHECK, war speed class, start_moon_destruction,
                              widened resolver guards, worker routing; roll stays in the certified hook
                              message/espionage retention worker — OGameX DeleteOldMessages window (7 days,
                              batches of 1000), player_messages + espionage_reports, pg_cron daily 04:00
                              colony cap by astrophysics — 1 homeworld + max(1, round(astro/2)); moons never
                              count; gates at dispatch (start_colonize_fleet) and creation (resolve_colonize_arrival)
                              AI player policy — economy (energy first, then the lowest mine) → research list →
                              colony; 60 % budget, 1000 deuterium floor, one action per player per tick, all
                              through the certified authorities and the ai_actor contract; pg_cron every 5 min
                              (LGI-defined policy: OGameX has no player-AI policy, only an NPC fleet generator)
                              wreck field + Space Dock — one field per coordinate, extension by later battles,
                              ACTIVE/REPAIRING/BLOCKED, Space Dock building (LGI price curve), recovery
                              least(100, 20+8*level) %, free repairs at 5*level ships/h, 72 h decay worker;
                              producer = additive battle hook on combat_unit_state losses; pg_cron every 10 min
APPROVED / NOT STARTED        (none — every block approved by the owner is closed)
CLOSED 2026-09-26 (20260926180000)  research_lab + the research-building gates are IMPLEMENTED and certified:
                              the research_lab building exists and `research_building_prerequisites` ships the SIXTEEN
                              OGameX gates (energy 1, laser 1, computer 1, combustion 1, impulse 2, armour 2,
                              espionage 3, astrophysics 3, ion 4, weapons 4, plasma 4, shielding 6, hyperspace drive 7,
                              hyperspace 7, IRN 10, graviton 12). The owner-approved activation is 16, NOT 14.
                              Authority: check_research_building_prerequisites -> can_start_research + start_research.
                              Certified by supabase/tests/research_building_prerequisites.sql (7 PASS re-verified LIVE
                              2026-09-28) and research_lab_and_irn.sql (14 PASS). Re-verified 2026-09-28: all 16
                              gates block and unblock correctly, cross-planet buildings never satisfy a gate, and no
                              anon / cross-owner / client-supplied player_id path can start research.
                              [Provenance: this row previously read 'BLOCKED (product decision) ... intentionally empty',
                              which described the pre-20260926180000 state. Reconciled 2026-09-28 against LIVE.]
BLOCKED (product decision)    wreck field + Space Dock subsystem (OGameX WreckFieldService is ~38 KB / 28
                              methods: active/blocked/repairing states, per-coordinate ownership, decay
                              cleanup and a dedicated building — a new subsystem, not an integration)
                              colonisation/colony cap, fleet-count policy, AI behaviour policy (priority
                              list, cadence, budget, reserve), message/espionage retention window
GAP                           none — the dedicated moon-destruction mission was CLOSED on 2026-09-26
                              (`20260926190000`: mission CHECK, war speed class, `start_moon_destruction`,
                              `resolve_attack_arrival`/`resolve_combat` guards widened, worker routing; the
                              destruction roll stays in the certified hook). 6/6 assertions PASS LIVE. Two
                              latent certified defects were fixed on the way: the ambiguous `ship_id` deduction
                              in `start_fleet_mixed` and the second ATTACK-only guard in `resolve_combat`.
OUT OF SCOPE                  Lifeforms (explicit for this version), premium/DM shop and payments, alliances,
                              chat/buddies/notes, planet relocation, tactical retreat, fleet templates,
                              account states (ban/vacation)
```


## Expedición — comerciante alcanzable desde el cliente (2026-09-27)

```text
GAP medido LIVE   el desenlace MERCHANT (`weight_merchant` = 0.4 en el universo activo `cf021ece`) escribía la
                  oferta en `player_expedition_merchants` (política `deny_direct_api_access`) y el informe la
                  anunciaba, pero NADA podía consumirla: `execute_expedition_merchant_trade` era service_role-only
                  y no tenía ningún llamador, el Worker no invoca RPCs y no hay Edge Functions.
IMPLEMENTADO      20260927024948_expedition_merchant_trade_contract — `get_player_expedition_merchant()`
                  (lectura owner-scoped, una fila siempre) + `trade_with_expedition_merchant(...)` (identidad
                  `auth.uid()` → `players.user_id`, propiedad del cuerpo comprobada, delegación ÍNTEGRA en la
                  función ya LIVE); UI `ExpeditionMerchantPanel` en la vista de Expediciones.
CERTIFICADO       supabase/tests/expedition_merchant_trade.sql — 15 PASS + 2 INFO LIVE (ROLLBACK, residuo 0):
                  ACL, actor sin sesión, sin oferta, cuerpo ajeno, lectura owner-scoped, comercio 100 cristal →
                  150 metal al cambio 3/2/1, un solo comercio, sin doble premio, recurso equivocado, recursos
                  insuficientes, recorte por almacén sin desbordar, aislamiento por actor y argumentos inválidos.
NO TOCADO         la función interna sigue service_role-only (el actor IA / service_role necesita su propio
                  `p_player_id`); tienda, comerciante general y economía premium (gasto de DM) siguen fuera de
                  alcance; no se modificó ningún contrato certificado ni se añadió fórmula alguna.
```

## Restos visibles para el jugador + transparencia económica (2026-09-27)

```text
GAP 1 medido LIVE   `calculate_planet_production` / `calculate_planet_energy_balance` / `calculate_building_time`
                    respondían `permission denied for table universes` al rol `authenticated` (son INVOKER y
                    `universes` no tiene grant): la vista de Edificios sólo podía mostrar el TIEMPO BASE y el
                    jugador no veía producción, energía ni almacén. Los oráculos hermanos
                    (`can_start_research`, `can_build_ship`, `can_build_defense`, `can_start_demolition`) sí
                    devolvían su tiempo, así que era una omisión de superficie, no un diseño.
IMPLEMENTADO 1      20260927035324_planet_economy_read_contracts — `get_planet_economy_overview(planet)` y
                    `get_planet_building_preview(planet)`, DEFINER owner-scoped, que DELEGAN en los helpers
                    certificados (duración compuesta igual que `start_building`, incluido el bonus de objeto).
                    `universes` NO se abrió. UI: tiempo real por edificio + ENERGÍA/h + producción/almacén en el
                    panel del cuerpo activo.
CERTIFICADO 1       supabase/tests/planet_economy_read_contracts.sql — 15 PASS + 2 INFO LIVE (ROLLBACK).

GAP 2 medido LIVE   `debris_fields` (política `deny_direct_api_access`) no tenía NINGÚN contrato: la misión
                    RECYCLE del servidor (campo MÁS CERCANO) era ciega y el jugador no podía ver restos.
IMPLEMENTADO 2      20260927035703_universe_debris_read_contract — `get_universe_debris(universe, galaxy, system)`
                    con el universo VALIDADO contra `auth.uid()` → `players.user_id` (0 filas si no pertenece).
                    La tabla sigue cerrada (productores y recolector internos). UI: restos por posición en la
                    vista de galaxia + contador de campos del sistema.
CERTIFICADO 2       supabase/tests/universe_debris_read_contract.sql — 10 PASS + 1 INFO LIVE (ROLLBACK).

NO HECHO A PROPÓSITO un RECYCLE dirigido por coordenadas desde la galaxia: `start_fleet_mixed` no acepta
                    coordenadas y el contrato certificado elige el campo más cercano; haría falta un contrato de
                    despacho nuevo y NO se inventó.
```

## Espionaje → informes → ACL: barrido de evidencia (2026-09-27)

```text
MEDIDO LIVE        `espionage_reports` sigue cerrada (`deny_direct_api_access`, 0 filas por lectura directa) con un
                   único lector owner-scoped; el inventario de 41 RPC del frontend existe completo y es
                   ejecutable por `authenticated`; ninguna función DEFINER de `public` carece de `search_path`;
                   `anon` sólo alcanza los 3 nombres de la allow-list.
GAP 1 (higiene)    `supabase/tests/counter_espionage.sql` no era ejecutable: una sentencia suelta después de
                   `ROLLBACK`. Eliminada → el fixture vuelve a correr (13 PASS).
GAP 2 (backend ✅   el payload certificado (`out_fleet` / `out_defenses` ya gateados por la regla de revelado)
  / frontend ❌)   no tenía consumidor: el panel mostraba sólo recursos y sondas, y `{}` no distinguía «no
                   revelado» de «nada». → 20260927120100 expone `out_ships_revealed` / `out_defenses_revealed`
                   DERIVADOS en servidor del snapshot almacenado; la UI pinta ambos mapas con los nombres de
                   `ui_ship_definitions` / `ui_defense_definitions`. 7 PASS.
GAP 3 (cross-owner) cinco contratos DEFINER llamables por el cliente leían edificios/investigación de OTRO imperio
                   sin misión de espionaje (`get_research_network_lab_level`, `calculate_research_time`,
                   `calculate_max_colony_slots`, `check_colony_cap`, `calculate_player_category_scores`).
                   → 20260927120000 aplica la puerta de identidad ya certificada (+ propiedad del planeta).
                   6 PASS. Ningún worker se ve afectado (`authenticated = false`).
REGRESIÓN          `resolve_espionage_arrival` moría con `PLAYER_NOT_OWNED` en cualquier sesión con JWT: el settle
                   del planeta objetivo pasa por `update_planet_resources_until_raw` → `calculate_planet_storage`,
                   que desde 20260926280000 lleva la puerta del CONTRATO DE CLIENTE. La certificación de espionaje
                   no era reproducible (el fixture de gating lo tapaba vaciando `request.jwt.claims`).
                   → 20260927120200 separa cálculo interno (`calculate_planet_storage_internal`, service_role) del
                   contrato de cliente (puerta intacta + delegación) y reapunta los consumidores de motor;
                   equivalencia numérica verificada en la migración para TODOS los planetas.
REPLAY              espionage_report_gating 17 PASS · counter_espionage 13 PASS · reveal flags 7 PASS ·
                   cross-owner 6 PASS. Resolver verificado con JWT presente (RETURNING + 1 informe).
NO INVENTADO       añadir edificios/investigación al informe (umbrales OGameX 5/3 y 7/4): sería una capacidad NUEVA
                   del jugador → decisión de producto, aislada.
```


## Espionaje: edificios + investigación en el informe · P3 ACL cerrado (2026-09-27)

```text
GAP (producto, ahora AUTORIZADO)  el informe certificado sólo llevaba naves y defensas; las dos categorías restantes
                  de OGameX (edificios y investigación) no existían en el payload. El propietario autorizó el alcance,
                  así que se ha implementado con la regla de OGameX verificada en el commit fijado
                  7c420bad3478d7099791e1f33c920e9ff92822e8 (`EspionageMission::canRevealData`, umbrales 5/3 y 7/4).
IMPLEMENTADO      20260927130000_espionage_report_buildings_and_research — columnas `buildings` y `research`
                  (machine-name → nivel) + las cuatro banderas de revelado almacenadas en la llegada; el resolver
                  escribe las dos secciones nuevas con `jsonb_object_agg` sobre `planet_buildings` del CUERPO
                  objetivo y `player_research` del PROPIETARIO objetivo, y guarda '{}' cuando la regla lo niega. Las
                  dos banderas antiguas pasan a leerse del snapshot almacenado, con backfill idéntico a la expresión
                  que ya evaluaba el contrato (0 desviaciones, verificado en la propia migración).
UI                `EspionageReportsPanel` muestra EDIFICIOS e INVESTIGACIÓN con los nombres de
                  `ui_building_definitions` / `ui_research_definitions`, o «no revelados (nivel insuficiente)» cuando
                  la bandera es falsa; la fila ESPIONAJE del centro de mensajes informa de los cuatro estados.
CERTIFICADO       espionage_read_contract_reveal_flags.sql 13 PASS (bloque dirigido por tabla con seis
                  configuraciones nivel/sondas y la expectativa DERIVADA de la regla OGameX) ·
                  espionage_report_gating.sql 17 PASS (replay, sin regresión).
P3 ACL CERRADO    `20260927130100_acl_p3_revoke_authenticated_invoker_helpers` revocó `authenticated` sobre la lista
                  auditada de 12 helpers SECURITY INVOKER que fallaban cerrados (`permission denied for table
                  universes`) y sin ningún consumidor de cliente; `service_role` conserva el acceso. Estado medido:
                  `authenticated` fuera de la allow-list 121 → 109, `anon` fuera de la allow-list 0, grants PUBLIC 0.
                  acl_surface_p3.sql actualizado (nueva aserción 8b) — 10 PASS.
NO TOCADO         allow-list de 32 RPC; `calculate_building_cost`, `project_planet_resources` y
                  `evaluate_action_at_time` (protegidos por el fixture P3); todos los contratos DEFINER;
                  `calculate_planet_production_snapshot` (funciona para `authenticated`, fuera de la lista).
```


## Barrido autónomo: edificios/investigación certificados · ACL muerta cerrada (2026-09-27)

```text
GAP A (producto autorizado)  espionaje con edificios e investigación: IMPLEMENTADO en 20260927130000 y CERTIFICADO
                  en esta misión con una prueba de derivación independiente (6/6 PASS, ROLLBACK): denegación por
                  presupuesto de sondas, umbral de edificios exacto (5), ambas categorías con 7 sondas, y la vía de
                  NIVEL con una sola sonda (atacante 4 vs 0) revelando las cuatro secciones. Aislamiento cross-owner 0.
                  Regresión durable: espionage_read_contract_reveal_flags.sql (13 PASS) + espionage_report_gating.sql (17).
GAP B (ACL P3)    primera ola verificada (20260927130100, doce helpers) y AMPLIADA: una sonda autónoma de TODOS los
                  contratos de lectura que consume el frontend (31 OK / 3 fallos) descubrió cuatro helpers alcanzables
                  por el cliente cuyo único resultado posible es un error de permisos (`get_planet_economic_rates`,
                  `get_planet_rate_snapshot`, `project_planet_resources`, `evaluate_action_at_time`).
                  20260927140000 revoca public/anon/authenticated sobre exactamente esos cuatro y conserva
                  service_role. Baseline: authenticated fuera de la allow-list 109 → 105; anon 0; grants PUBLIC 0.
                  acl_surface_p3.sql corregido (lista v_internal real + nueva aserción 8c) → 11 PASS.
SWEEP             colonización verificada de extremo a extremo · mensajes/producers alcanzables · expediciones sin
                  contratos huérfanos · economía 31/31 contratos de lectura OK · IA DORMANT (609/609 perfiles, el
                  worker sólo rota sobre `status='ACTIVE'`) → la política de activación sigue siendo decisión de
                  producto · siete entradas obsoletas de `database.types.ts` (cluster de flota retirado,
                  `get_player_fleet_speed_multiplier`, `register_guest_player`) podadas: la superficie tipada ya
                  coincide con LIVE · lecturas directas RLS verificadas.
PENDIENTE         certificación browser del flujo de flotas: ítem final reservado (ENVIRONMENT BLOCKED: sin driver y
                  sin credencial humana). No simulado.
```

