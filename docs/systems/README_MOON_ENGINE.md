# MOON ENGINE — LA GRAN IMPLOSIÓN

> Moons as first-class domain entities: identity model, creation from combat debris, lunar base, sensor phalanx,
> jump gate, destruction, contracts and tests.
> Related: [`README_FLEET_ENGINE.md`](README_FLEET_ENGINE.md), [`README_COMBAT_ENGINE.md`](README_COMBAT_ENGINE.md),
> [`README_MESSAGING_ENGINE.md`](README_MESSAGING_ENGINE.md),
> [`../reference/README_OGAMEX_LGI_MAP.md`](../reference/README_OGAMEX_LGI_MAP.md).
> Operational status: [`../PROJECT_CONTEXT_PROMPT.md`](../PROJECT_CONTEXT_PROMPT.md).

## 1. Accepted model (user decision, 2026-09-26)

```text
planets.kind              'PLANET' | 'MOON'   (existing rows default to PLANET)
planets.parent_planet_id  a moon points at its planet; one moon per planet (partial unique index)
coordinates               the global UNIQUE (universe_id, galaxy, system, position) is REPLACED by two partial
                          unique indexes: a moon shares its planet's coordinates while one moon per coordinate is
                          still enforced
lookups                   every coordinate lookup that means "a planet" filters kind = 'PLANET' explicitly
ownership                 unchanged: a moon belongs to its planet's owner (enforced at write time)
extra columns             moon_diameter_km, jump_gate_cooldown_until
```

Migrations (LIVE 2026-09-26): `20260926130000_moon_domain_model`, `…30100_moon_buildings`,
`…30200_moon_creation_and_destruction`, `…30400_sensor_phalanx`, `…30500_jump_gate`, `…30600_moon_read_contracts`,
`…30610_moon_read_contract_destroyed_filter`, `…30800_coordinate_lookup_kind_filter`.

## 2. Creation from combat (OGameX `BattleEngine` + `PlanetServiceFactory`)

```text
chance%   = floor(debris_total / 100 000) clamped to the universe maximum. LGI has no `maximumMoonChance` setting,
            so the classic OGame maximum of 20 % is applied as a documented constant.
roll      = 1..100 <= chance, deterministic: floor(fleet_event_random(fleet, 'moon_creation') * 100) + 1 — a pure
            function of the fleet's immutable dispatch timestamps, therefore replay-safe.
diameter  = floor(sqrt(x + 3 × debris / 100 000) × 1000), x ∈ [10,20], capped at 8 944 km.
fields    = 1 (+3 per lunar base level, see §3).
temp      = average of the parent planet's temperatures (max), min = max − 40.
hook      AFTER INSERT on `combat_debris_generations`: that table already holds exactly one row per battle that
          produced debris, so the roll happens once, only for battles whose debris can form a moon, and the
          certified combat path is untouched. Provenance lives in `moon_creation_rolls`.
```

Live evidence (fixture assertions 9/10): 6 667 destroyed probes → 2 000 100 debris → chance 20 % → a moon of
**8 831 km** with its own resources and the "Moon formed" message.

## 3. Buildings and the two new generic gates

```text
lunar_base      20 000 / 40 000 / 20 000, factor 2, MOON only, no requirements, +3 fields per level
sensor_phalanx  20 000 / 40 000 / 10 000, factor 2, MOON only, requires lunar_base 1
jump_gate       2 000 000 / 4 000 000 / 2 000 000, factor 2, MOON only, requires lunar_base 1 +
                hyperspace_technology 7

building_definitions.valid_kinds text[] not null default '{PLANET}'        the kind gate
building_research_prerequisites(building_id, research_id, required_level)  building → research requirements (the
                                                                           mirror of the existing
                                                                           research → building mechanism)
BEFORE INSERT trigger on building_queue (trg_enforce_building_kind_and_research) enforces BOTH. The pre-existing
`building_prerequisites` (building → building) keeps being enforced by `start_building`, which was not modified.
```

Field capacity: a moon's stored `fields_total` is kept equal to `1 + 3 × lunar_base level` by the `planet_buildings`
trigger `trg_sync_moon_field_capacity`, so the existing `fields_used >= fields_total` checks in `start_building` and
`can_start_building` work unchanged.

## 4. Sensor Phalanx — `scan_with_phalanx(player, moon, galaxy, system)`

```text
ownership   the caller must own the moon (auth.uid() → players.user_id, or a service-role call cross-checked
            against the stored owner)
building    the moon must own a sensor_phalanx (level >= 1)
range       same galaxy only; |target_system − moon_system| <= level² − 1   (level 2 → 3 systems)
cost        5 000 deuterium per scan, taken from the MOON's own resources, atomic (FOR UPDATE)
result      the in-flight (OUTBOUND/RETURNING) fleets heading to the scanned system, with owner, mission, ships and
            ETA — a fleet outside the range can never be observed
rejections  PHALANX_MOON_NOT_FOUND / PHALANX_MOON_NOT_OWNED / PHALANX_NOT_BUILT /
            PHALANX_TARGET_OUT_OF_GALAXY / PHALANX_TARGET_OUT_OF_RANGE / PHALANX_INSUFFICIENT_DEUTERIUM
```

## 5. Jump Gate — `execute_jump_gate(player, source_moon, target_moon, ships)`

```text
ownership   both moons must be moons of the same player
building    both moons must own a jump gate
cooldown    seconds = (60 / war_fleet_speed) minutes × (1 − 0.10 × (level − 1)) — OGameX `JumpGateService`
            BASE_COOLDOWN_MINUTES 60 with 10 % per level above 1. Stored in `planets.jump_gate_cooldown_until`;
            a jump inside the window is refused with JUMP_GATE_ON_COOLDOWN.
ships       every ship must exist, carry a positive quantity, be transferable (solar_satellite and crawler are NOT,
            per OGameX) and be owned by the source moon
cost        none (OGameX charges no deuterium)
atomicity   the ship move and the cooldown start happen in one transaction; the fixture asserts both moons'
            quantities plus the stored cooldown
```

## 6. Destruction (OGameX `MoonDestructionMission`)

```text
trigger     AFTER UPDATE on `combat_battles` when `finished_at` goes NULL → value (happens exactly once per battle)
            and the battle carried >= 1 Deathstar against a moon. The battle itself is a normal ATTACK resolved by
            the certified engine; this hook only applies the moon-specific outcome.
success%    clamp(0, 100, (100 − sqrt(diameter)) × sqrt(deathstars)), deterministic roll
RIP loss%   clamp(0, 100, sqrt(diameter) / 2), applied only when the moon survives, per Deathstar unit
destroyed   the moon keeps its row (`is_destroyed = true`, so no relation is orphaned), loses ships (→ the debris of
            its fleet at the same coordinates), buildings and defences; its resources are zeroed
survived    the attacking fleet loses the rolled Deathstars: `fleet_movement_ships` is rewritten, so the returning
            fleet carries the survivors
provenance  `moon_destruction_attempts` (unique per battle) + a message for each side
```

## 7. Contracts and ACL

| Object | Role | ACL |
|---|---|---|
| `get_player_moons()` | owner-scoped moon overview (identity, parent, diameter, fields, cooldown, resources, buildings) | `authenticated`/`service_role`, never `anon` |
| `scan_with_phalanx(...)` | phalanx scan | `authenticated`/`service_role`, never `anon` |
| `execute_jump_gate(...)` | jump | `authenticated`/`service_role`, never `anon` |
| `calculate_moon_field_capacity`, `calculate_moon_creation_chance`, `calculate_jump_gate_cooldown_seconds` | read-only derivations | `service_role` |
| `settle_moon_creation_for_battle`, `settle_moon_destruction_for_battle` | engine settlement (trigger-driven) | `service_role` |

## 8. Tests (LIVE 2026-09-26, rolled back, zero residue)

```text
supabase/tests/moon_engine.sql      13 PASS + 1 INFO
  chance formula (0 / 1 / 19 / 20 / clamped) · a moon must share its planet's coordinates · a moon follows its
  planet owner · moon and planet coexist at the same coordinates · one moon per planet · lunar base level 3 → 10
  fields · a moon building is refused on a planet · the jump gate requires hyperspace_technology 7 · creation from
  battle debris with the OGameX diameter formula · creation provenance/message/resources/identity/fields ·
  successful destruction (row kept, ships/buildings gone, fleet debris created, no Deathstar loss) · the four
  coordinate lookups filter kind = 'PLANET' · ACL
supabase/tests/moon_services.sql    11 PASS + 1 INFO
  phalanx ownership · range = level² − 1 · never crosses galaxies · 5 000 deuterium charged and the incoming fleet
  reported · refused without deuterium · stationary ships cannot jump · unavailable ships refused · jump gate
  ownership · a jump moves exactly the requested ships and starts the cooldown · the cooldown refuses a second jump ·
  ACL
LIMITATION  both fixtures are single-session harnesses; concurrency is not executed. The deterministic roll is what
  lets a fixture SEARCH a favourable dispatch instant (bumping `arrives_at`) instead of faking randomness.
```

## 9. Moon polish — D1…D5 classified (2026-09-26)

```text
D1 DEDICATED MOON DESTRUCTION MISSION — SUPERSEDED 2026-09-26 (CLOSED; original classification kept below)
   CLOSED 2026-09-26 by `20260926190000_moon_destruction_mission.sql`: mission CHECK, war-speed class,
   `start_moon_destruction`, the two widened ATTACK-only guards, worker routing and the UI entry. The roll stayed in
   the certified hook. 6/6 assertions PASS LIVE. Detail:
   [`README_FLEET_ENGINE.md`](README_FLEET_ENGINE.md) §"Dedicated moon destruction mission".
   Original note, kept for provenance:
   FUTURE (not invented)
   OGameX has `MoonDestructionMission` as a first-class mission type. LGI's `fleet_movements.mission_type` CHECK
   admits seven missions plus ACS_HOLD/HOLDING, the dispatcher validates that set, and the worker routes by mission
   type; adding a new type would touch the certified dispatch + worker pipeline for a mechanic that ALREADY WORKS:
   an ATTACK battle against a moon carrying at least one Deathstar triggers the destruction roll (success chance,
   Deathstar loss, debris, provenance, messages). What is missing is only dispatch-time validation (own moon, target
   kind) and a dedicated UI entry. Classified as FUTURE WORK, no formula invented.

D2 SENSOR PHALANX OUTPUTS — VERIFIED (no change needed)
   `scan_with_phalanx` returns the in-flight (OUTBOUND/RETURNING) fleets whose DESTINATION coordinates are the
   scanned system: owner name, mission type, status, coordinates, arrival/return instants and the ship map. It is
   reachable only by the moon's owner, only within `level² − 1` systems of the same galaxy, and it charges 5 000
   deuterium per call. Nothing sensitive is exposed beyond what the OGameX contract allows (a fleet outside the
   range can never be observed, and no resource/planet data of the target is returned). Fleets LEAVING the scanned
   planet are still not listed — a documented scope note, not an authorization leak.

D3 LUNAR UI — IMPLEMENTED (basic)
   `src/GameplayEnginePanel.tsx` gained `MoonsPanel` (identity, parent planet, diameter, fields used/total, lunar
   base / sensor phalanx / jump gate levels, jump-gate cooldown countdown, moon resources) reading the owner-scoped
   `get_player_moons()`; it is mounted on the overview screen next to the ranking panel. It holds no authority and
   derives ownership from the parent planet. The phalanx/jump-gate ACTION forms are not in the UI yet (the contracts
   are callable and tested).

D4 KIND GATE — IMPLEMENTED (single server-side authority)
   `building_definitions.valid_kinds` + `trg_enforce_building_kind_and_research` (buildings) and
   `ship_definitions.valid_kinds` + `trg_enforce_ship_kind` (ships) are the ONE authority; the UI never decides.
   Aligned with OGameX `valid_planet_types`, where an EMPTY list means both kinds
   (`ObjectService::isObjectValidForPlanetType`): mines, solar plant and fusion plant are planet-only, the crawler is
   planet-only, lunar base / sensor phalanx / jump gate are moon-only, and storages plus the shipyard are legal on
   both (updated by `20260926140000`). Defensive structures declare nothing in OGameX, so no defence is moon-banned
   and no defence gate is required — verified, not assumed.

D5 WRECK FIELD — SUPERSEDED 2026-09-26 (implemented BACKEND-ONLY; still out of scope for the UI)
   CLOSED 2026-09-26 by `20260926230000_wreck_field_space_dock.sql` (+ `20260926270000` helper ACL hardening):
   `planet_wreck_fields`, the LGI-defined `space_dock` curve (PLANET + MOON, max 10) and the repair/worker contracts
   are LIVE and `supabase/tests/wreck_field_space_dock.sql` is 9/9 PASS. It stays a deliberately backend-only
   subsystem (every contract is postgres/service_role, there is no client read contract), so it is NOT a lunar UI gap
   and no lunar UI follows from it. Detail:
   [`README_FLEET_ENGINE.md`](README_FLEET_ENGINE.md) §"Wreck field + Space Dock".
   Original note, kept for provenance:
   PRODUCT DECISION (out of scope)
   OGameX `WreckFieldService` + `CleanupWreckFields` + a Space Dock building model a salvaged remains field after
   moon/planet destruction. LGI has no wreck-field table, no space dock and no cleanup job, and the OGameX formulas

## 10. Cuerpo activo (planeta o luna) + superficie lunar — 2026-09-26

Segunda fase de la superficie jugable: el concepto de **cuerpo activo** deja de derivarse del `homeworld` y pasa a
ser una selección explícita del jugador sobre cuerpos **propios**; sobre ese contexto se conecta todo el bloque
lunar con los contratos LIVE existentes (0 RPC nuevas, 0 cambios de ACL, 0 cambios de esquema).

### 10.1 Selección de cuerpo (planetas y lunas propias)

```text
fuente de verdad   `planets` filtrado por player_id = jugador y is_destroyed = false: el mismo listado que ya
                   alimenta la superficie incluye ahora `kind` y `parent_planet_id`, así que planetas y lunas
                   son cuerpos de primera clase y un cuerpo ajeno no puede activarse nunca.
estado             `selectedBodyId` en App; se persiste en localStorage (`lagranimplosion-active-body`) para que
                   la elección sea deliberada y estable entre sesiones.
valor inicial      el capital marcado en BD (`is_homeworld`): un atributo real del cuerpo, no una heurística de
                   "primer planeta disponible". Si el cuerpo elegido deja de existir (luna destruida, colonia
                   perdida) la superficie **anuncia** el cambio de cuerpo activo en el aviso de la vista.
consumidores       overview · edificios · investigación · hangar · defensas · flota · expediciones · luna ·
                   galaxia (origen de flota por defecto) · demolición de edificios: todos leen `activePlanet`
                   (= cuerpo activo) o reciben `activePlanetId`.
interfaz           barra lateral agrupada (PLANETAS / LUNAS con contador), chip de cuerpo activo en la cabecera,
                   `.neo-planetbar` para el chrome de plantilla y un botón "ACTIVAR LUNA" en la vista lunar.
origen de flota    `FleetDispatchPanel` recibe el cuerpo activo como origen por defecto y permite elegir
                   cualquier cuerpo propio (incluidas lunas) como origen del despacho.
```

### 10.2 Superficie lunar conectada

```text
edificios lunares   `can_start_building` / `start_building` sobre el cuerpo activo + cola `building_queue`;
                    planetas y lunas comparten el mismo motor y la capacidad de campos de la luna la mantiene
                    el trigger `trg_sync_moon_field_capacity` (1 + 3 × base lunar).
falange             `scan_with_phalanx(p_player_id, p_moon_id, p_galaxy, p_system)` con selector de luna propia,
                    galaxia/sistema objetivo, tabla de flotas detectadas (propietario, misión, estado, destino,
                    llegada/regreso, naves) y mensajes de rechazo literales del servidor.
puerta de salto     `execute_jump_gate(p_player_id, p_source_moon_id, p_target_moon_id, p_ships)` con origen y
                    destino limitados a lunas propias, lista de naves de la luna de origen y cooldown devuelto
                    por el servidor (también mostrado por luna en la tabla lunar).
destrucción lunar   misión `MOON_DESTRUCTION` en el panel de flota con el contrato dedicado
                    `start_moon_destruction(p_player_id, p_origin_planet_id, p_destination_planet_id, p_ships)`:
                    destino por coordenadas → luna ajena, exige ≥ 1 deathstar y reutiliza el motor de flotas
                    certificado (el desenlace lo aplica el hook de combate).
componentes         `src/MoonServicesPanel.tsx` (nuevo: lunas, falange, puerta de salto) ·
                    `src/screens/fleet/fleetContracts.ts` + `useFleetDispatch.ts` + `FleetModules.tsx` (misión MOON_DESTRUCTION,
                    migrada desde `FleetCommandPanel.tsx` al LGI UI Engine conservando contratos y cálculos) ·
                    `src/GameplayEnginePanel.tsx` (`MoonsPanel` en overview) ·
                    `src/App.tsx` (selector de cuerpo activo, grupo LUNAS y cuerpo activo del chrome —región `planet.bodies`— y entrada
                    de menú "Luna"; `TemplateChrome.tsx` ya no existe tras la migración al LGI UI Engine).
```

   are tied to a building and a service LGI does not have. Implementing it would be a new subsystem, so it stays an
   explicit scope/product decision; the destroyed moon's fleet debris IS already merged into the ordinary debris
   field at the same coordinates (§6).
```



### 10.3 Puerta de tipo de cuerpo: lectura optimista, escritura autoritativa (hallazgo)

`can_start_building` y `can_build_ship` **no** evalúan la puerta de tipo: comprobado LIVE, en una luna
`can_start_building(metal_mine)` responde `allowed=true / reason=OK` mientras `start_building` la rechaza con
`BUILDING_NOT_AVAILABLE_FOR_KIND: metal_mine is not available on a MOON` (la autoridad real es el trigger
`trg_enforce_building_kind_and_research` / `trg_enforce_ship_kind`). La superficie resuelve la asimetría **sin
tocar ningún contrato certificado**: lee la declaración `valid_kinds` de `building_definitions` /
`ship_definitions` (dato público, legible por `authenticated`) y con ella renderiza la disponibilidad
("No disponible en LUNA / PLANETA"), dejando el rechazo del servidor como autoridad final. `defense_definitions`
no tiene `valid_kinds` porque ninguna defensa está vetada por tipo, coherente con el bloque lunar original.


```text
verificado LIVE (rol authenticated, transaccional con ROLLBACK, residuo 0)
  metal_mine={PLANET} · lunar_base={MOON} · sensor_phalanx={MOON} · jump_gate={MOON}
  metal_storage/crystal_storage/deuterium_tank={PLANET,MOON} · light_fighter/deathstar/solar_satellite={PLANET,MOON}
  start_building(sensor_phalanx) en luna   → aceptado · cola 'sensor_phalanx→nivel 3 (BUILDING)' ·
                                             coste debitado 80000/160000/40000 sobre 900000/900000/400000
  start_building(metal_mine) en luna       → BUILDING_NOT_AVAILABLE_FOR_KIND ·
                                             BUILDING_QUEUE_ALREADY_ACTIVE cuando la cola estaba ocupada
  get_player_moons()                       → 2 lunas propias con edificios y campos 0/10 y 0/4 (trigger de campos)
  scan_with_phalanx(luna, 1:1)             → 1 flota en tránsito 'DevPlayer · TRANSPORT OUTBOUND → [1:1:3]' ·
                                             400000 → 395000 de deuterio (5 000 por escaneo, repetible)
  scan_with_phalanx(luna, 1:9)             → PHALANX_TARGET_OUT_OF_RANGE: system 9 is 8 systems away (range 3 at level 2)
  scan_with_phalanx(luna, 2:1)             → PHALANX_TARGET_OUT_OF_GALAXY: 2 <> 1
  execute_jump_gate(A → B, 3 cazas)        → naves {"light_fighter": 3} · cooldown 3600 s persistido ·
                                             origen 5 → 2 · destino 0 → 3 · segundo salto → JUMP_GATE_ON_COOLDOWN
  start_moon_destruction(planeta → luna ajena, 1 deathstar)
                                           → flota MOON_DESTRUCTION OUTBOUND con la luna objetivo como destino
  start_moon_destruction(luna propia)      → MOON_DESTRUCTION_TARGET_OWN
  start_moon_destruction(planeta ajeno)    → MOON_DESTRUCTION_TARGET_NOT_A_MOON
  start_moon_destruction(sin deathstar)    → MOON_DESTRUCTION_DEATHSTAR_REQUIRED
residuo tras ROLLBACK                      lunas=0 · cuerpos de fixture=0 · edificios de fixture=0 · flotas=0 ·
                                           computer_technology sin fila · mensajes=0 · intentos de destrucción=0
```

### 10.4 Hallazgos de esta fase

```text
BUG (fuera de alcance, reportado)   `get_current_planet_resources(uuid)` y `calculate_planet_storage(uuid)` están
                                    concedidos a `authenticated` pero internamente leen `public.universes` (que no
                                    tiene grant para ese rol a través de `calculate_universe_rates`), así que la
                                    llamada falla con `42501 permission denied for table universes`. La superficie
                                    no los consume (usa `sync_current_planet_resources`, SECURITY DEFINER); se
                                    reporta, no se toca.
NOTA DE FIXTURE                     en una luna sin almacenes, cualquier contrato que liquide recursos
                                    (`update_planet_resources_until`) los ajusta a la capacidad real del cuerpo:
                                    un delta grande de deuterio en una fixture sin almacenes es el propio modelo de
                                    almacenamiento, no un sobrecoste de la mecánica (con almacenes el escaneo
                                    cuesta exactamente 5 000).
E6 no concluyente                   el salto de un `solar_satellite` quedó enmascarado por el cooldown recién
                                    iniciado (devolvió JUMP_GATE_ON_COOLDOWN); la regla de naves no transferibles
                                    ya está cubierta por el fixture certificado `moon_services.sql`.
SIN CAMBIOS                         ningún contrato certificado, ninguna ACL, ninguna migración y ninguna tabla.
```

## 11. Verificación integral de la superficie lunar + H6 cerrado — 2026-09-26

Fase de verificación (no de reconstrucción): se auditó lo ya conectado, se cerró el defecto que rompía la
superficie de edificios con cuerpo lunar y se completó la matriz de verificación con evidencia LIVE. La
superficie lunar no se rediseñó.

### 11.1 H6 CERRADO — la rama de rechazo tipada que rompía Buildings (planeta y luna)

`evaluate_building_start_internal` (helper interno, ACL `postgres`/`service_role`) devolvía literales enteros sin
castear en las seis columnas `numeric` de **tres** ramas de rechazo, de modo que el contrato público
`can_start_building` no devolvía el rechazo sino que fallaba con
`42804 structure of query does not match function result type`:

```text
"Planeta no encontrado o no pertenece al jugador"   cuerpo ajeno, destruido o inexistente  ← rompía la vista lunar
"Edificio inexistente"                              p_building_id desconocido              ← el H6 reportado
"Nivel máximo alcanzado"                            edificio ya al máximo                  ← también roto
```

Consecuencia real en la superficie: la vista de EDIFICIOS llama a `can_start_building` **por cada definición** para
pintar disponibilidad; si el cuerpo activo quedaba obsoleto (luna destruida, colonia perdida) o un edificio estaba
al máximo, la vista entera fallaba en vez de mostrar el rechazo.

Arreglo (`20260926212048_fix_building_start_internal_numeric_return_type`, sólo tipos, 18 literales → `0::numeric`):

```text
alcance        una función interna; el contrato público `can_start_building` NO se toca (ya casteaba sus propios
               literales) y conserva firma, cuerpo, ACL y comportamiento.
seguridad      la migración exige encontrar exactamente los 3 bloques heredados y comprueba por md5 que la
               definición resultante es exactamente la reescritura esperada antes de confirmar (auto-verificada).
idempotencia   si los bloques ya no existen, no hace nada (no-op con NOTICE).
LIVE           md5 de la definición = 299fe1715730317ac710e2d9d9ef9b87 · 18 casteos · ACL sigue siendo
               postgres/service_role (authenticated NO puede ejecutarla) · can_start_building intacto.
```

Verificación funcional (rol `authenticated`, transaccional con ROLLBACK):

```text
OK (regresión)  can_start_building(luna propia, lunar_base 3)  → allowed=t · nivel 3→4 · coste 160000/320000/160000
H6 reportado    can_start_building(luna propia, 'no_existe')   → allowed=f · "Edificio inexistente"
cuerpo ajeno    can_start_building(luna ajena, lunar_base)     → allowed=f · "Planeta no encontrado o no pertenece al jugador"
cuerpo inexistente can_start_building(id desconocido, …)       → allowed=f · mismo rechazo
nivel máximo    can_start_building(luna propia, space_dock 10) → allowed=f · "Nivel máximo alcanzado"
contrato público can_start_building(player ajeno, …)           → allowed=f · PLAYER_NOT_OWNED
escritura       start_building(luna ajena) → PLANET_NOT_FOUND_OR_NOT_OWNED (sin cambios) ·
                start_building(luna propia) → aceptado y cola creada (sin cambios)
```



### 11.2 Matriz de verificación (evidencia LIVE, rol `authenticated`, todo en transacciones con ROLLBACK)

```text
Funcionalidad        Backend                        Frontend            Owner            Ajeno / inválido            Error del servidor
-------------------  -----------------------------  ------------------  ---------------  --------------------------  --------------------------------------
cuerpo activo        planets(kind,parent_planet_id)  selector + vistas   PASS (propios)   PASS (no activable)         — (ownership por player_id)
edificios lunares    can_start_building/start_…     vista EDIFICIOS     PASS             can_start_building → raz.   PLANET_NOT_FOUND_OR_NOT_OWNED (write) ·
                                                                                                             BUILDING_NOT_AVAILABLE_FOR_KIND (tipo)
demolición lunar     can_start_demolition/start_…   vista EDIFICIOS     PASS (nivel 3→2) PASS (no listado)           —
Phalanx              scan_with_phalanx              MoonServicesPanel   PASS (0/1 flotas) PHALANX_MOON_NOT_OWNED ·    PHALANX_NOT_BUILT · PHALANX_MOON_NOT_FOUND ·
                                                                                         PHALANX_INSUFFICIENT_DEUTERIUM (5000 vs 100) · rango/galaxia
Jump Gate            execute_jump_gate              MoonServicesPanel   PASS (3 cazas)    JUMP_GATE_TARGET_MOON_NOT_OWNED ·
                                                                                         JUMP_GATE_TARGET_NOT_BUILT · JUMP_GATE_NOT_BUILT ·
                                                                                         JUMP_GATE_SHIPS_UNAVAILABLE · JUMP_GATE_ON_COOLDOWN (3600 s)
Moon Destruction     start_moon_destruction         FleetCommandPanel   PASS (flota OUTBOUND → luna ajena) · TARGET_OWN · TARGET_NOT_A_MOON ·
                                                                                         DEATHSTAR_REQUIRED
Flota desde luna     start_fleet_mixed/colonize/…   FleetCommandPanel   PASS (TRANSPORT con origen = luna, EXPEDITION desde luna) ·
                                                                                         carga 45/52.50 · recall → RETURNING · ACS_HOLD → SUPPORT_AUTHORIZATION_REQUIRED
Investigación        can_start_research/start_…     vista INVESTIGACIÓN  PASS con laboratorio · luna sin laboratorio →
                                                                                         RESEARCH_REQUIREMENTS_NOT_MET con `research_lab` nivel 0/3
```

Nota de capacidad (valida la UI): `load_fleet_cargo` devolvió `45 / 52.50` para 1 caza ligera — la UI muestra la
capacidad **base** declarada en `ship_definitions` (50) como cota inferior y el servidor aplica sus bonificaciones,
tal y como dice el panel.

### 11.3 Observaciones y clasificaciones de esta fase

```text
IMPLEMENTED + VERIFIED      selector de cuerpo activo · edificios lunares · demolición · Phalanx · Jump Gate ·
                            Moon Destruction · flota desde luna · expediciones desde luna · investigación con luna
                            activa (razón autoritativa del laboratorio efectivo)
IMPLEMENTED + CONNECTED     `valid_kinds` como fuente de disponibilidad por tipo de cuerpo (sin listas paralelas)
PRODUCT DECISION            COLONIZE desde una luna: el contrato certificado sólo exige `colony_ship` en el cuerpo
                            de origen, el cap de colonias y un destino libre — no comprueba el tipo del origen, así
                            que LGI lo permite (OGame no lo permite). Documentado, no alterado: decidir paridad es
                            producto, no UI. La superficie muestra lo que responda el servidor.
BY DESIGN (no gap)          completar colas: no existe RPC `complete_building`; la finalización la ejecutan los
                            workers (`process_building_queue`) y la UI espera a las marcas temporales.
OBSERVACIÓN DE PROCEDENCIA  el archivo `20260926240000_harden_can_start_building_ownership.sql` no coincide con la
                            versión registrada en LIVE (`20260926133901`), preexistente a esta fase. Esta fase ha
                            dejado su propia migración con la versión registrada (`20260926212048`). No se renombra
                            trabajo previo ajeno a la misión.
SIN CAMBIOS                 motor de flotas, RLS, ACL de clientes, tablas y contratos certificados (salvo el arreglo
                            de tipos descrito, en una función interna).
```

## 12. MOON FINAL VERIFICATION — 2026-09-28

Repetición de la verificación del dominio lunar contra el repositorio y contra LIVE: no se añadió ninguna mecánica
lunar, no se rediseñó ninguna superficie y no se modificó ningún contrato ni ninguna fixture certificados.

```text
status        CLOSED — D6 CORREGIDO y certificado el 2026-09-28 (ver §12.4)
tests         supabase/tests/moon_engine.sql               13 PASS + 1 INFO · LIVE 2026-09-28 · ROLLBACK
              supabase/tests/moon_services.sql             11 PASS + 1 INFO · LIVE 2026-09-28 · ROLLBACK
              supabase/tests/moon_destruction_mission.sql  6/6 PASS · LIVE 2026-09-28 · ROLLBACK
              supabase/tests/fleet_ship_loss_quantity_check.sql  8 PASS + 2 INFO (nuevo, clase del defecto) · LIVE
                                                            2026-09-28 · ROLLBACK · residuo 0
LIVE          las migraciones lunares de §1 siguen aplicadas y los contratos de §7 existen con su ACL (`anon`
              denegado en get_player_moons / scan_with_phalanx / execute_jump_gate / start_moon_destruction; los
              helpers de liquidación sólo service_role). building_definitions.valid_kinds verificado LIVE:
              lunar_base / sensor_phalanx / jump_gate = {MOON} · metal_mine / solar_plant = {PLANET} ·
              almacenes / shipyard / space_dock = {PLANET,MOON}
frontend      consumidores intactos tras la migración al LGI UI Engine: src/MoonServicesPanel.tsx
              (get_player_moons + scan_with_phalanx + execute_jump_gate), src/GameplayEnginePanel.tsx (MoonsPanel),
              src/screens/fleet/fleetContracts.ts + useFleetDispatch.ts (MOON_DESTRUCTION → start_moon_destruction)
              y src/App.tsx (cuerpo activo, grupo LUNAS y disponibilidad por valid_kinds)
regressions   ninguna en los contratos certificados · npx tsc -b exit 0 · npx vite build exit 0 ·
              git diff --check limpio · residuo 0 tras los ROLLBACK
new GAP       ninguno
```

### 12.1 D6 (H7) — el intento en el que la luna sobrevive y se pierden TODOS los deathstars se descartaba en silencio · CORREGIDO (§12.4)

```text
contrato    settle_moon_destruction_for_battle(battle_id) (§6), invocado por el hook
            on_combat_battle_finished_moon_destruction (AFTER UPDATE de combat_battles cuando finished_at pasa de
            null a valor). Documentado y certificado el 2026-09-26.
síntoma     la rama «la luna sobrevive» hace `update fleet_movement_ships set quantity = quantity − v_lost`.
            fleet_movement_ships_quantity_chk exige `quantity > 0`, así que el update viola el CHECK en cuanto v_lost
            iguala las naves enviadas (se pierden TODOS los deathstars); el `delete` posterior ya no puede rescatar la
            fila porque la sentencia aborta antes.
consecuencia el bloque de la función lo descarta su propio `exception when others … raise warning` (simple aviso):
            no se escribe la fila de moon_destruction_attempts, no se envía ningún mensaje a ninguna de las dos partes
            y —lo relevante— el atacante CONSERVA los deathstars que debía perder. La batalla sí se resuelve y la
            flota vuelve; sólo desaparece el desenlace lunar.
frecuencia  determinista por tirada: con 1 deathstar y una luna de 5 000 km la pérdida del único deathstar ocurre en
            el 35 % de los intentos en los que la luna sobrevive.
alcance     sólo la rama «sobrevive» (la rama «destruida» no toca fleet_movement_ships). No afecta a la creación
            desde escombros, falange, puerta de salto ni al gate de tipos.
```

Evidencia (LIVE 2026-09-28, todo en transacciones con ROLLBACK y residuo 0):

```text
1. fixture certificada  moon_destruction_mission.sql: 1 de 4 ejecuciones falló la aserción 5 («0 failed» en las otras
                        tres). Traza de la ejecución fallida: A1…A4 y A6 PASS · A5 FAIL con `attempt=` (sin fila de
                        provenance) · batalla 0→1 · flota RETURNING.
2. guardas descartadas  en el instante del fallo: defender_planet_id = la luna correcta · sin fila previa · la luna
                        viva y kind = MOON · el deathstar seguía presente en fleet_movement_ships (1). Las CUATRO
                        salidas anticipadas de la función quedaban descartadas y aun así devolvía null → el error lo
                        tragaba su propio manejador.
3. log del servidor     WARNING en postgres_logs con contexto «PL/pgSQL function
                        settle_moon_destruction_for_battle(uuid) line 113 at RAISE», encadenado desde
                        on_combat_battle_finished_moon_destruction() y desde el UPDATE de cierre de combat_battles.
4. causa raíz probada   fleet_movement_ships_quantity_chk = CHECK (quantity > 0): el update certificado devuelve
                        «new row for relation "fleet_movement_ships" violates check constraint
                        "fleet_movement_ships_quantity_chk"», y el `delete` posterior (quantity <= 0) no llega a
                        ejecutarse.
5. repetibilidad        tres sondas instrumentadas de 6 iteraciones descartaron el desenlace en 3/6, 3/6 y 1/6 casos,
                        con las cuatro guardas verificadas en cada iteración; en las fallidas la llamada directa al
                        contrato también devolvió null.
```

Arreglo mínimo (sin cambio de firma, de ACL ni de contrato) y su verificación:

```text
arreglo     invertir el orden respetando el CHECK: eliminar primero las filas agotadas
            (`delete … where ship_id = 'deathstar' and quantity <= v_lost`) y restar después
            (`update … set quantity = quantity − v_lost`). Deja el resultado pretendido por §6 (0 supervivientes si se
            pierden todos; quantity − v_lost si quedan) sin violar la restricción.
verificado  la secuencia corregida se ejecutó LIVE sobre el mismo esquema: 1 de 1 perdido → 0 deathstars y sin error
            · 1 de 2 perdido → 1 superviviente · 3 de 3 perdidos → 0 filas.
cobertura   las fixtures certificadas no cubren el caso: la aserción 11 de moon_engine sólo ejercita el desenlace
            «destruida» con deathstars_lost = 0, y la aserción 5 de moon_destruction_mission sólo comprueba coherencia
             estructural. La corrección añade el caso «sobrevive + todos los deathstars perdidos» en un fixture NUEVO
             (supabase/tests/fleet_ship_loss_quantity_check.sql); ninguna fixture certificada fue modificada.
estado      CORREGIDO el 2026-09-28 — ver §12.4
