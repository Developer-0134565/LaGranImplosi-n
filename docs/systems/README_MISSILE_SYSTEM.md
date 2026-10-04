# MISSILE SYSTEM — SPECIFICATION AND IMPLEMENTATION

> **Estado: IMPLEMENTADO Y VERIFICADO EN LIVE (2026-10-02).**
> `docs/systems/README_MISSILE_SYSTEM.md` · referencia `lanedirt/OGameX@main`.
> Cierra el punto que quedó `OPEN` en `docs/audits/GAP_CLOSURE_2026-09-30.md` §5.
>
> ```text
> D1 (tiempos base)   silo 60 s / time_factor 2 · ABM 60 s · IPM 60 s   DECIDIDA (§9)
> D2 D3 D4 D5        cerradas y aplicadas tal cual (§9)
> ```
>
> ```text
> VERIFIED FROM OGAMEX   §1 §2 §3 §4   — extraído literalmente del código y de los tests upstream
> ADAPTED TO LGI         §7             — cada regla con su equivalente/adaptación LGI
> LGI EXISTING           §6             — la arquitectura que YA existe y se reutiliza
> PRODUCT DECISION       §9             — D1..D5, cerradas
> IMPLEMENTED            §10 §16        — migraciones, backend, worker y UI
> TESTED                 §12 §18        — fixtures ejecutadas en LIVE
> ```
>
> **Nota sobre el ledger (importante al leer el repo).** Los ficheros de migración de misiles de
> `supabase/migrations/` llevan en su cabecera `SUPERSEDED BY THE LEDGER - DO NOT RUN AS-IS`: son
> borradores locales. LIVE aplicó el bloque con OTROS nombres y versiones (p. ej. `missile_definitions_and_capacity`
> = `20260930074024`, `fix_missile_expensive_target_priority` = `20261001035817`). El código autoritativo es el
> que vive en LIVE, verificado con `pg_get_functiondef` en §18. `supabase db push` está prohibido.

---

## 1. VERIFIED FROM OGAMEX — Missile Silo

`app/GameObjects/StationObjects.php`:

```php
$missileSilo->id = 44;
$missileSilo->machine_name = 'missile_silo';
$missileSilo->requirements = [ new GameObjectRequirement('shipyard', 1) ];
$missileSilo->price = new GameObjectPrice(20000, 20000, 1000, 0, 2);
// NO asigna valid_planet_types  =>  regla del proyecto: vacío = PLANET + MOON
```

| Atributo | Valor | Evidencia |
|---|---|---|
| coste | 20 000 metal / 20 000 cristal / 1 000 deuterio / 0 energía | `GameObjectPrice(20000,20000,1000,0,2)` |
| factor de coste | 2 (×2 por nivel) | 5º argumento del `GameObjectPrice` |
| requisito | **shipyard 1** y nada más | `requirements` |
| cuerpo | **PLANET + MOON** | sin `valid_planet_types` |
| nivel máximo | ninguno declarado | — |
| **capacidad** | **10 ranuras por nivel** | `MissileSiloCapacityTest`: `planetSetObjectLevel('missile_silo', 4); // 40 slots total` |
| nivel 0 | 0 ranuras ⇒ no se construye ningún misil | `testNoSiloMeansNoMissiles`: `assertEquals(0, $maxIPM)` y `assertEquals(0, $maxABM)` |
| degradación | no se puede bajar el nivel con misiles dentro | `testCannotDowngradeSiloWithMissiles` |
| persistencia | columna `missile_silo` del cuerpo, como cualquier edificio | id + machine_name del catálogo |
| validación | cadena estándar de edificios (`GameObjectRequirement`) + gate de capacidad | — |

## 2. VERIFIED FROM OGAMEX — ABM

```php
$antiBallisticMissile->id = 502;
$antiBallisticMissile->requirements = [ GameObjectRequirement('missile_silo', 2),
                                       GameObjectRequirement('shipyard', 1) ];
$antiBallisticMissile->price = new GameObjectPrice(8000, 2000, 0, 0);
$antiBallisticMissile->properties = new GameObjectProperties($antiBallisticMissile, 8000, 1, 1, 0, 0, 0);
```

| Atributo | Valor |
|---|---|
| coste | 8 000 metal / 2 000 cristal / 0 deuterio |
| requisitos | **missile_silo 2** + **shipyard 1** |
| propiedades | integridad 8000 · escudo 1 · ataque 1 · velocidad 0 · capacidad 0 · combustible 0 |
| **ranuras** | **1 por unidad** (*40 ABM to fill the silo completely (40 * 1 = 40 slots)*) |
| **no participa en combate** | `MissilesDoNotParticipateInCombatTest`: 10 ABM sobreviven al combate, conservan su recuento y **no aparecen** en las unidades del informe de batalla |

## 3. VERIFIED FROM OGAMEX — IPM

```php
$interplanetaryMissile->id = 503;
$interplanetaryMissile->requirements = [ GameObjectRequirement('shipyard', 1),
                                        GameObjectRequirement('missile_silo', 4),
                                        GameObjectRequirement('impulse_drive', 1) ];
$interplanetaryMissile->price = new GameObjectPrice(12500, 2500, 10000, 0);
$interplanetaryMissile->properties = new GameObjectProperties($interplanetaryMissile, 15000, 1, 12000, 0, 0, 0);
```

| Atributo | Valor |
|---|---|
| coste | 12 500 metal / 2 500 cristal / 10 000 deuterio |
| requisitos | **shipyard 1** + **missile_silo 4** + **impulse_drive 1** |
| propiedades | integridad 15000 · escudo 1 · ataque 12000 · velocidad 0 · capacidad 0 · combustible 0 |
| **ranuras** | **2 por unidad** (*20 IPM to fill the silo completely (20 * 2 = 40 slots)*) |
| **alcance** | `getMissileRange()` = **(impulse_drive × 5) − 1** sistemas, fijado por `MissileMissionTest::testMissileRangeCalculation`: nivel 1 ⇒ 4, nivel 5 ⇒ 24, nivel 10 ⇒ 49 |
| **distancia** | `calculateSystemDistance()`: 0 si misma galaxia+sistema; `abs(system_origen − system_destino)` en la misma galaxia; **imposible en otra galaxia** |
| **tiempo de vuelo** | **`(30 + 60 × distancia_en_sistemas) / velocidad_universo` segundos** (docblock `MissileMission.php:37`). **No usa el pipeline de velocidad** — por eso `speed = 0` es irrelevante — ni consume combustible |
| tipo de misión | **id 10 = `MissileMission`** en `GameMissionFactory::getAllMissions()`. **NO es un `Attack`** |
| retorno | **no hay viaje de vuelta** (`processReturn`: *"Missile missions don't have a return trip"*) |
| **no participa en combate** | mismo test: 5 IPM sobreviven y no aparecen en el informe |

### 3.1 Resolución de la llegada (`processArrival`)

```text
1  flight = $mission->interplanetary_missile                       (IPM lanzados)
2  abms_objetivo = getObjectAmount('anti_ballistic_missile') del objetivo
   abms_padre    = 0; si el objetivo es LUNA, se suma el del PLANETA PADRE
3  interceptados = min(flight, abms_objetivo + abms_padre)
4  efectivos     = flight − interceptados
5  se gastan primero los ABM del PLANETA PADRE, luego los del objetivo (transacción atómica)
6  potencia = efectivos × 12000 × (1 + 0.1 × weapon_technology_del_atacante)
7  defensas ordenadas por prioridad (§4) — se SALTAN 'interplanetary_missile' y
   'anti_ballistic_missile': los misiles no son objetivo; las CÚPULAS SÍ lo son
8  por cada defensa, en ese orden:
       armadura = estructura × (1 + 0.1 × armor_technology_del_defensor) / 10
       max_destruibles = (int) floor(potencia / armadura)          <- suelo
       destruidas      = min(max_destruibles, cantidad)            <- destrucción PARCIAL
       potencia        = potencia − destruidas × armadura
9  informes: MissileAttackReport (atacante) + MissileDefenseReport (defensor)
10 la misión se marca processada = 1 incluso si hay excepción (evita bucles de reintento)
```

## 4. VERIFIED FROM OGAMEX — ALGORITMO DE PRIORIDAD (el punto que quedaba OPEN)

`app/GameMissions/MissileMission.php`, funciones `decodePriority()` (línea 489) y `sortDefensesByPriority()`.

### 4.1 Codificación (`$mission->target_priority`, entero)

| código | significado |
|---|---|
| 0 | `cheapest` |
| 1 | `expensive` |
| 2 | `rocket_launcher` |
| 3 | `light_laser` |
| 4 | `heavy_laser` |
| 5 | `gauss_cannon` |
| 6 | `ion_cannon` |
| 7 | `plasma_turret` |
| 8 | `small_shield_dome` |
| 9 | `large_shield_dome` |

`return $priorityMap[$code] ?? 'cheapest';` — **código desconocido ⇒ `cheapest`**.
Y el valor por defecto cuando la columna no existe: `(int)($mission->target_priority ?? 0)` ⇒ **`cheapest`**.

### 4.2 Ordenación

```php
'cheapest'  => usort por (metal + cristal) del precio, ASCENDENTE
'expensive' => usort por (metal + cristal), DESCENDENTE
otro        => la defensa cuyo machine_name === $priority va PRIMERO;
               si ambos son (o ninguno) el indicado, desempate por (metal + cristal) ASCENDENTE
```

**Los 10 puntos que pedía la misión, verificados uno a uno:**

1. *codificación*: entero 0–9 en `target_priority`. ✔
2. *decodificación*: `decodePriority()`, con fallback a `cheapest`. ✔
3. *ordenación*: `sortDefensesByPriority()`, 3 ramas. ✔
4. *prioridades por tipo*: sí — las 8 defensas reales + los 2 modos. ✔
5. *desempates*: **precio metal+cristal ASCENDENTE** en las tres ramas; `usort` de PHP 8 es **estable**, así que a igualdad de precio se conserva el orden del catálogo. ✔
6. *destrucción parcial*: sí — `min(max_destruibles, cantidad)`, y **la potencia sobrante se consume** (`potencia -= destruidas × armadura`). ✔
7. *redondeo*: `(int) floor(potencia / armadura)` — **suelo** al calcular cuántos caben; la resta usa la armadura completa, no un coste fraccionario. ✔
8. *potencia sobrante*: se **descarta** al acabar el bucle. ✔

## 4.3 CORREGIDO 2026-10-01 — la rama `expensive` era un no-op silencioso

La auditoría de 2026-10-01 encontró que **una de las tres ramas documentadas arriba no estaba
implementada de hecho**. El `ORDER BY` de `order_defenses_for_missile_attack` era:

```sql
ORDER BY s.is_first DESC, s.is_expensive DESC, s.sort_price ASC, s.defense_id ASC
```

`s.is_expensive DESC` sólo separa los **grupos**; nunca invierte el orden **dentro** de ellos. Con un
único grupo seleccionado, el modo 1 devolvía una salida **byte-idéntica** al modo 0.

Medido en LIVE con light_laser(2000) / rocket_launcher(2000) / heavy_laser(8000) /
small_shield_dome(20000):

```text
modo 0 (cheapest)  -> light_laser            correcto
modo 1 (expensive) -> light_laser            INCORRECTO: OGameX exige small_shield_dome
```

Es decir: `start_missile_attack(..., p_target_priority => 1)` pasaba la validación (0–9), lanzaba,
**destruía primero la defensa más barata** y reportaba éxito. Quien pidiera `expensive` recibía lo
contrario de lo pedido, sin error y sin rastro.

**Arreglo** (`20261001050000_fix_missile_expensive_target_priority.sql`), splice anclado sobre
`pg_get_functiondef()`:

```sql
ORDER BY
  s.is_first DESC,
  -- expensive => el más caro PRIMERO (OGameX `priceB <=> priceA`)
  CASE WHEN s.is_expensive = 1 THEN s.sort_price END DESC,
  -- cheapest (y el resto de un modo explícito) => el más barato PRIMERO (D4)
  s.sort_price ASC,
  -- D4: desempate técnico estable, nunca el orden físico de la tabla
  s.defense_id ASC;
```

* **modo 0** (el comportamiento de producto D3, y lo que la UI envía siempre): el `CASE` es NULL en
  todas las filas ⇒ el orden es **idéntico byte a byte**.
* **modo 1**: ahora es realmente descendente, como upstream.
* **modos 2–9**: `is_first DESC` sigue mandando; dentro de cada grupo se mantiene el ASC, que es
  exactamente el «el resto por precio ascendente» de upstream.
* **D4 intacto**: el desempate final sigue siendo `defense_id ASC`, y un empate absoluto de precio
  sigue resolviéndose igual (verificado con light_laser/rocket_launcher, ambos 2000).

Verificado end-to-end: 1 IPM contra un cuerpo con 500 `small_shield_dome` + 50 `light_laser` destruye
`500 → 440` en modo `expensive` sin tocar el láser, y `50 → 0` en modo `cheapest`.

**No se tocó**: la exclusión de ABM/IPM como objetivo, `calculate_missile_defense_armor`,
`calculate_missile_attack_power`, la aritmética de intercepción, el bucle de daño, ni la firma,
volatilidad, `SECURITY` o `search_path`. El helper sigue **cerrado a `authenticated` y `anon`**.

Certificado por `supabase/tests/missile_target_priority_regression.sql` (18 aserciones).
8. *potencia sobrante*: se **descarta** al acabar el bucle. ✔
9. *defensa con 0 unidades*: `if ($defenseCount <= 0) continue;` — se salta sin consumir potencia. ✔
10. *¿el orden depende de tecnología, cantidad u otro estado?*: **NO**. Depende **sólo** del código elegido por el atacante y del precio del catálogo. La tecnología entra únicamente en la potencia (weapon) y en la armadura (armor), nunca en el orden. ✔

**El coste de comparación es `metal + cristal`, deuterio EXCLUIDO** (comentario explícito en el
código). Relevante porque `defense_definitions` de LGI guarda `metal_cost`, `crystal_cost` y
`deuterium_cost` por separado: la comparación LGI debe ser `metal_cost + crystal_cost`.

### 4.3 Validación del disparo (`isMissionPossible`)

```text
 parent::isMissionPossible (coordenadas válidas, tipo de objetivo)
+ el objetivo debe ser PLANET o MOON  (nunca debris field / expedición)
+ el objetivo debe existir
+ una LUNA destruida NO es objetivo; un PLANETA destruido SÍ lo es (igual que un ataque)
+ no se puede atacar el propio cuerpo
+ distancia de sistemas <= getMissileRange()  (= impulse_drive*5 − 1)
+ debe haber al menos 1 IPM en el planeta atacante
```

## 5. VERIFIED — permisos de cuerpo de ABM/IPM

`DefenseObjects.php` **no asigna `valid_planet_types`** a ninguno de los dos ⇒ con la regla del proyecto
(vacío = ambos tipos) **ABM e IPM son legales en PLANET y MOON**, igual que las 8 defensas actuales.
No hay ningún `check_defense_requirements` por tipo que los aparte.

## 6. LGI EXISTING BEHAVIOUR — la arquitectura que ya hay (verificada en LIVE)

| OGameX | L.G.I. | Estado |
|---|---|---|
| entidad del silo | `planet_buildings` con `building_id='missile_silo'` | falta la fila |
| catálogo de edificios | `building_definitions` (16 filas) + `building_prerequisites` + `building_research_prerequisites` | falta 1 fila + 1 prerrequisito |
| catálogo de defensas | `defense_definitions` (8 filas: `id, name, metal_cost, crystal_cost, deuterium_cost, base_build_time, attack, shield, hull, description`) | faltan 2 filas |
| defences en un cuerpo | `planet_defenses (planet_id, defense_id, quantity)` | tabla existe, 0 filas en LIVE |
| construcción de defensa | `start_defense(player, planet, defense, qty)` → `can_build_defense` / `check_defense_requirements` → `defense_queue` → `process_defense_queue(_until)` | existe, **sin gate de capacidad** |
| tipo de misión | `fleet_movements.mission_type` con CHECK de 11 valores: `ATTACK, TRANSPORT, DEPLOY, ESPIONAGE, COLONIZE, RECYCLE, EXPEDITION, ACS_HOLD, HOLDING, DEFEND, MOON_DESTRUCTION` | **falta `MISSILE_ATTACK`** |
| precedence del ataque a la llegada | `process_fleet_movements` (worker 1 s): bucle `elsif` por `mission_type`, `for update skip locked`, marca `ARRIVED` | existe; falta **una rama** |
| precedente de tipo no-combate | **`MOON_DESTRUCTION`**: tipo propio, `start_moon_destruction(player, origin, destination, ships jsonb)`, liquidado por `settle_moon_destruction_for_battle` disparado desde `on_combat_battle_finished_moon_destruction` | **es el molde exacto** |
| viaje / tiempo | `calculate_fleet_travel_time` + `calculate_player_ship_speed` + combustible | **el IPM NO debe usarlos** (§3) |
| combate (ABM/IPM fuera) | `get_combat_unit_snapshot()` e `initialize_combat_unit_state()` seleccionan **todas** las filas de `planet_defenses` con cantidad > 0, **sin filtro** | ⚠️ **exclusión OBLIGATORIA** (§8) |
| armadura/ataque de defensa | `get_combat_defense_attack/shield/hull(player, defense)` | reutilizable para la fórmula de armadura |
| tecnología | `get_player_research_level(player, id)` → `weapon_technology`, `armour_technology` | existe |
| informes | `create_player_message` (productores ya registrados en el motor de mensajes) | falta el productor de IPM |
| reaparición tras combate | `repair_defenses_after_combat` | **no debe tocar ABM/IPM** (mismo requisito) |
| pruebas | `supabase/tests/*.sql` transaccionales con ROLLBACK | falta la fixture |

**Hallazgo arquitectónico decisivo:** el precedente `MOON_DESTRUCTION` demuestra que LGI ya sabe Integrate
una misión de flota que **no** es `ATTACK` y que **no** entra al motor de rondas. El IPM debe seguir ese
mismo camino, no el de `ATTACK`.

## 7. ADAPTED TO LGI — regla por regla

| Regla OGameX | Adaptación LGI propuesta | Nota |
|---|---|---|
| precio del silo 20000/20000/1000, factor 2 | fila en `building_definitions` con `base_*` y `cost_factor=2` | falta `base_build_time_seconds`: **§9 D1** |
| silo `shipyard 1` | `building_prerequisites ('missile_silo','shipyard',1)` | mecanismo existente |
| silo sin `valid_planet_types` | `valid_kinds = '{PLANET,MOON}'` | convención del proyecto |
| ABM `missile_silo 2` + `shipyard 1` | `defense_prerequisites` (ya soporta `prerequisite_type='building'`) | existe |
| IPM `missile_silo 4` + `shipyard 1` + `impulse_drive 1` | `defense_prerequisites` (ya soporta `prerequisite_type='research'`) | existe |
| propiedades ABM/IPM | `defense_definitions`: ABM `attack 1, shield 1, hull 800`; IPM `attack 12000, shield 1, hull 1500` | casco = integridad/10, **convención LGI ya usada en las 8 defensas** |
| **10 ranuras por nivel de silo** | helper `calculate_missile_silo_slots(planet) = 10 × nivel` | nuevo, una sola autoridad |
| **ABM 1 ranura / IPM 2 ranuras** | coste de ranura por defensa, guardado junto al resto de datos de la defensa | evita un segundo sitio donde definir la ranura |
| capacidad (incluye lo encolado) | el gate va en `can_build_defense` **y** en `start_defense`, sumando lo que ya está en `defense_queue` con estado activo | OGameX cuenta también lo encolado |
| no degradar el silo con misiles dentro | gate en la demolición (`start_demolition` / `inspect_demolition`) | **§9 D2** (LGI no tiene "downgrade" de silo explícito) |
| interceptación 1:1, padre primero | `resolve_missile_attack_arrival` | una transacción |
| potencia `n × 12000 × (1+0.1·weapon)` | literal | — |
| armadura `estructura × (1+0.1·armour) / 10` | `get_combat_defense_hull(player, defense)` (ya devuelve el casco LGI) | la estructura upstream es el casco LGI × 10 ⇒ `/10` deshace la convención |
| prioridad 0–9 | columna `fleet_movements.target_priority integer`, por defecto **0** | §9 D3 |
| orden y desempates | `order by` con `metal_cost + crystal_cost`; `usort` estable ⇒ en SQL hay que fijar un **segundo criterio determinista** | **§9 D4** |
| destrucción parcial | `least(floor(potencia/armadura), cantidad)` y `potencia -= destruidas × armadura` | — |
| potencia sobrante se descarta | fin del bucle | — |
| **`speed = 0` irrelevante** | el IPM no pasa por `calculate_player_ship_speed`; su tiempo es `(30 + 60·distancia)/velocidad_universo` | por eso `fuel_consumption` es irrelevante |
| **no volver** | el IPM no crea movimiento de retorno: `status = 'COMPLETED'` directo | `fleet_movements.status` ya admite `COMPLETED` |
| **no entrar en combate** | excluir ABM/IPM de `get_combat_unit_snapshot`, `initialize_combat_unit_state`, `repair_defenses_after_combat` y del informe | **obligatorio**, ver §8 |

## 8. ADAPTED — cómo encaja el IPM en el settlement de L.G.I.

Flujo exigido y encaje verificado contra el worker real (`process_fleet_movements` marca `ARRIVED` y
despacha por `elsif mission_type`):

```text
start_missile_attack(player, origin, destination, qty, target_priority)
   │  auth.uid() -> players.user_id -> players.id ; planeta propio y no destruido ;
   │  qty >= 1 y <= IPM en el cuerpo (con SELECT ... FOR UPDATE) ;
   │  el objetivo debe ser PLANET/MOON, existir, no ser propio, misma galaxia,
   │  |sistema_origen - sistema_destino| <= (impulse_drive*5 - 1)
   └─► insert fleet_movements(mission_type='MISSILE_ATTACK', status='OUTBOUND',
        started_at=now(), arrives_at=now() + (30 + 60*distancia)/velocidad_universo)
   └─► insert fleet_movement_ships(ship_id='interplanetary_missile', quantity=qty)
   │
   ▼ worker de 1 s
process_fleet_movements -> status='ARRIVED'
   │
   └─► rama MISSILE_ATTACK -> resolve_missile_attack_arrival(movement_id)   [UNA transacción]
         1  interceptados = least(ipm, abms_objetivo + abms_padre)   ; padre primero
         2  efectivos     = ipm - interceptados
         3  potencia       = efectivos * 12000 * (1 + 0.1*weapon_atacante)
         4  defensas ordenadas por prioridad (§4), saltando ABM e IPM
         5  por cada una: armadura, floor, min(cantidad), resta de potencia,
            update planet_defenses SET quantity = quantity - destruidas
         6  create_player_message x2 (atacante / defensor)
         7  status='COMPLETED'   (sin viaje de vuelta)
```

**La secuencia pedida cabe íntegra en la arquitectura actual** y no necesita un segundo motor de combate.
Puntos donde toca superficies **cerradas**, y que por eso quedan para una misión dedicada:

| Superficie cerrada | Cambio necesario |
|---|---|
| `fleet_movements_mission_type_check` | añadir `'MISSILE_ATTACK'` a los 11 valores |
| `process_fleet_movements` | una rama `elsif` más |
| `can_build_defense` / `start_defense` | gate de ranuras del silo (capacidad + encolado) |
| `get_combat_unit_snapshot`, `initialize_combat_unit_state`, `repair_defenses_after_combat` | **excluir** ABM/IPM |
| `start_demolition` / `inspect_demolition` | gate de "no degradar el silo con misiles dentro" |

**Sobre el consumo de IPM**: la evidencia upstream **no** vuelve a descontar del inventario del atacante
los IPM lanzados — `removeUnits` sólo se llama sobre los ABM interceptados y las defensas destruidas.
Queda registrado como comportamiento **verificado**, no como supuesto.

## 9. PRODUCT DECISION — CERRADAS

Las cinco decisiones quedaron cerradas por el dueno y se aplicaron tal cual.

| # | Decisión | Valor |
|---|---|---|
| **D1** | Tiempos base | Silo `60 s` / `time_factor 2` · ABM `60 s` · IPM `60 s` |
| **D2** | Demolición del silo | **bloqueada** si `used_missile_slots > resulting_capacity`; no se destruye, recorta ni mueve nada |
| **D3** | Prioridad | `cheapest` fijo, sin selector de UI |
| **D4** | Desempate | `metal + crystal ASC` + clave técnica estable (`defense_id ASC`) |
| **D5** | Ataque / casco | convención LGI existente, sin fórmula paralela |

## 10. IMPLEMENTED

Migraciones aplicadas, en orden:

| Migración | Contenido |
|---|---|
| `20260930220000` | catálogo del silo, ABM e IPM, `slots_per_unit`, `target_priority`, helpers de capacidad |
| `20260930221000` | `MISSILE_ATTACK` en el `CHECK`, `target_priority`, alcance, distancia, vuelo, D5, `is_missile_defense` |
| `20260930211000` | orden de destrucción (D3/D4) |
| `20260930212000` | `start_missile_attack` |
| `20260930213000` | `resolve_missile_attack_arrival` |
| `20260930214000` | gates de ranuras en `start_defense` y `can_build_defense` |
| `20260930215000` | helpers de demolición (D2) |
| `20260930216000` | guard D2 dentro de `start_demolition` |
| `20260930217000` / `18000` / `19000` | exclusión de ABM/IPM de `get_combat_unit_snapshot`, `initialize_combat_unit_state`, `repair_defenses_after_combat` |
| `20260930220000` | `fleet_movements.missile_count` (§11.1) |
| `20260930221000` | la liquidación lee `missile_count` |
| `20260930222000` | `format()` sin `%d` (§11.2) |
| `20260930223000` | intercepción con cero ABM (§11.3) |
| `20260930224000` | bloqueo de ABM antes del agregado (§11.3) |
| `20260930225000` | orden del guard D2 (§11.4) |
| `20260930230000` | rama `MISSILE_ATTACK` en el worker existente |

### 10.1 Superficies cerradas tocadas

| Superficie | Cambio | Riesgo |
|---|---|---|
| `fleet_movements_mission_type_check` | + `'MISSILE_ATTACK'` | ninguno, es aditivo |
| `fleet_movements` | + `target_priority`, + `missile_count` | columnas nuevas con default |
| `process_fleet_movements` | + una rama `elsif` | reescritura integra; el resto del cuerpo es idéntico |
| `can_build_defense`, `start_defense` | + una comprobación de ranuras | la lógica previa se conserva literal |
| `start_demolition` | + el guard D2, antes del cobro | el resto se conserva literal |
| `get_combat_unit_snapshot` | + `AND NOT is_missile_defense(...)` | una línea de filtro |
| `initialize_combat_unit_state` | + el mismo filtro | una línea de filtro |
| `repair_defenses_after_combat` | + el mismo filtro | una línea de filtro |

`inspect_demolition` **no** se tocó: aplicar el guard en `start_demolition` evita cambiar su
firma `(OUT)`, que rompería a cualquier llamador que la consuma por posición.

## 11. BUGS ENCONTRADOS POR LA FIXTURE

Los cuatro los encontró la fixture, no la theory. Todos están corregidos y verificados.

### 11.1 El IPM no es una nave

`fleet_movement_ships.ship_id` tiene `FOREIGN KEY (ship_id) REFERENCES ship_definitions(id)`, y el IPM
es una **defensa**. La primera versión lo guardaba ahí y fallaba con
`violates foreign key constraint`.

Además de romper, habría contaminado el informe de flota y cualquier lógica que leyera esa tabla.

**Corrección:** columna dedicada `fleet_movements.missile_count`, que es donde vive el resto del estado
propio de la misión (`mission_type`, `target_priority`, `holding_until`, `fuel_consumed`).

### 11.2 `format()` no tiene `%d`

Los mensajes usaban `%d` para enteros. En Postgres los especificadores son `%s`, `%I`, `%L` y `%%`;
`%d` da `unrecognized format() type specifier`. Corregido a `%s`.

### 11.3 Con cero ABM, todos los IPM salían "interceptados"

El conteo usaba un `SELECT` escalar sin agregado:

```sql
SELECT COALESCE(pd.quantity, 0) INTO v_abm_target
  FROM public.planet_defenses pd
 WHERE ... AND pd.defense_id = 'anti_ballistic_missile';
```

Si no hay filas, PL/pgSQL asigna **NULL** a la variable: el `COALESCE` de la columna nunca llega a
evaluarse porque no hay fila que lo exprese. Entonces
`LEAST(v_ipm, v_abm_target + v_abm_parent)` se convierte en `LEAST(n, NULL)`, y **en Postgres
`LEAST`/`GREATEST` ignoran los argumentos `NULL`**, así que devuelve `n`.

Resultado: un objetivo sin un solo ABM interceptaba la salva entera y **ninguna defensa recibía daño**.

**Corrección:** contar con `SUM`, que siempre devuelve una fila, y bloquear las filas con un `PERFORM`
previo, porque `FOR UPDATE` no se admite junto a un agregado.

### 11.4 El guard D2 era inalcanzable en la práctica

Estaba placed después de `inspect_demolition`, pero esa función solo *calcula* el coste: no comprueba
recursos. El `INSUFFICIENT_RESOURCES` se lanzaba después, y como demoler un silo de nivel alto cuesta
de sobra, el jugador casi nunca llegaba al guard de missiles: veía `INSUFFICIENT_RESOURCES` en lugar de
la causa real.

**Corrección:** el guard se evalúa antes de cualquier gestión de recursos y antes de encolar nada.

## 12. TESTED

`supabase/tests/missile_system.sql` — fixture transaccional, termina siempre en `ROLLBACK`.
Cubre silo, ABM, IPM, capacidad, alcance, vuelo, intercepción, prioridad, exclusión de combate,
idempotencia, seguridad, demolición, mensajes e integración del worker.

Tres invariantes que descubren las invariantes del propio motor al crear cuerpos de prueba y que el
fixture respeta:

* una luna exige `parent_planet_id` **y** compartir `galaxy/system/position` con su planeta, y
* además `moon_diameter_km > 0`.

**Limitación declarada:** harness de una sola sesión. La concurrencia real (dos lanzamientos o dos
llegadas simultáneas) no se ejecuta; la atomicidad se apoya en `FOR UPDATE` y en el hecho de que
`process_fleet_movements` ya toma un advisory lock global.

## 13. BLOCKED

* **Certificación en navegador — `BLOCKED — ENVIRONMENT`.** Faltan `DEV_EMAIL` y `DEV_PASSWORD`
  válidos. No se simuló login ni se usó `service_role` como jugador.

> **Estado vigente: ver §18.** El bloqueo de navegador de esta sección se **resolvió** en la segunda
> vuelta del mismo día (§16.7, `PASS` 11/11). Lo que **no** se ha repetido es una re-certificación en
> la misión de cierre 2026-10-02, que se registra honestamente como `NOT RUN` (§18.10). Esta sección
> se conserva como registro histórico.

## 14. NOT IMPLEMENTED

* Insignias de insignia y acción de "atacar con IPM" en la pantalla de objetivo.
* El panel no ofrece selector de prioridad **por decisión D3**, no por carencia: el componente no
  contiene ningún `<select>` y manda siempre `p_target_priority: 0`. El backend sí acepta 0-9 y las
  nueve ramas están certificadas (§4.3, `missile_target_priority_regression.sql`).
* Integrar el panel como destino desde el mapa de la galaxia: hoy el destino se introduce por
  coordenadas, igual que el panel de soporte.

## 15. NOTAS DE BALANCE

La única divergencia deliberada frente a OGameX es el **tiempo de construcción** (D1). LGI es una
economía de `base_build_time` en segundos; la fórmula de OGameX `(metal+crystal)/2500` en horas daría
14 400 s para el ABM y 21 600 s para el IPM, entre 30 y 100 veces más lento que cualquier otra defensa
del catálogo y rompe el equilibrio del hangar ya certificado.
## 16. IMPLEMENTED — UI (mision 2026-09-30, segunda vuelta)

El backend certified (seccion 10-12) **no se toco**. Solo se anadio la capa de presentacion.

### 16.1 Superficies UI

| Archivo | Cambio |
|---|---|
| `src/MissileControlPanel.tsx` | **NUEVO**. Panel de silo, produccion ABM/IPM, lanzamiento IPM y movimientos en vuelo. |
| `src/App.tsx` | La vista `defense` pasa a devolver `<>{renderDefinitionMenu('defense')}<MissileControlPanel .../></>`, con el mismo envoltorio que ya usan `buildings` + `BuildingDemolitionPanel`. Ademas `defense_definitions` lee `slots_per_unit`. |
| `src/lib/database.types.ts` | `slots_per_unit` y `target_priority` en `defense_definitions`; `missile_count` y `target_priority` en `fleet_movements`; alta de `start_missile_attack`. |

El panel **no introduce arquitectura paralela**: sigue el molde de `BuildingDemolitionPanel` (lectura por RPC, mutacion por RPC, texto del servidor tal cual, `onChanged` para refrescar).

### 16.2 Lo que la UI NO hace, a proposito

* **No hay selector de prioridad.** El componente no contiene ningun `<select>`; el lanzamiento manda siempre `p_target_priority: 0` (D3). D4 sigue siendo solo backend.
* **No escribe datos.** Cero `insert`/`update`/`upsert`. Toda mutacion pasa por `start_defense` o `start_missile_attack`.
* **No trata el IPM como nave.** Nunca lee `fleet_movement_ships`; el movimiento se muestra desde `fleet_movements.missile_count` (la correccion 11.1).
* **No calcula autoridad.** La capacidad mostrada es informativa; el gate real esta en el servidor.
* **No introduce heuristicas de ownership.** `playerId` viene de la identidad resuelta, igual que el resto de paneles, y el servidor vuelve a validar `user_id = auth.uid()`.

### 16.3 El unico hueco de backend que esta UI si necesita

`start_missile_attack` se creo **sin GRANT a `authenticated`**:

```sql
select has_function_privilege('authenticated', oid, 'EXECUTE')
  from pg_proc where proname = 'start_missile_attack';
-- false  =>  el panel no podia lanzar nada
```

Es una carencia real y estrictamente necesaria, demostrada antes de tocar codigo. Corregida con `20260930231000`: **un unico GRANT** sobre el contrato de ACCION ya existente. No se abre ninguna funcion interna: los helpers de lectura (`calculate_missile_silo_slots`, `calculate_used_missile_slots`, `calculate_missile_range_systems`, `can_fit_missile_slots`, ...) **siguen cerrados al cliente**, porque darlos saltaria el RLS owner-scoped de `planet_buildings` y expondría el nivel de silo de otro imperio. `20260930231100` solo corrige un texto de `COMMENT`.

La produccion **no necesito** nada nuevo: `start_defense` y `can_build_defense` ya tenian `EXECUTE` para `authenticated`, y `ui_defense_definitions` / `ui_building_definitions` devuelven `SETOF` de las tablas, por lo que exponen `missile_silo` y las columnas nuevas automaticamente.

### 16.4 Flujos

```text
PRODUCCION   panel -> can_build_defense(abm|ipm)  [lectura, motivo textual del servidor]
                    -> start_defense(...)          [accion]
                    -> error de capacidad / recursos / requisitos => texto del servidor, sin validar de nuevo

LANZAMIENTO  panel -> planets(universe_id + galaxy/system/position)   [mismo universo, sin heuristicas]
                    -> muestra nombre, DISTANCIA y ALCANCE MAXIMO
                    -> start_missile_attack(player, origin, destino, qty, 0)
                    -> error (fuera de rango, IPM insuficiente, objetivo propio, ...) => texto del servidor

RESULTADO    fleet_movements(MISSILE_ATTACK) en la lista de movimientos ya existente
             (FleetCommandPanel lista los movimientos del jugador) + el informe por
             el sistema de mensajes ya existente
```

### 16.5 TESTED (UI)

`supabase/tests/missile_ui_surface.sql` — 5 PASS, transaccional, `ROLLBACK`. No duplica los 67 casos del backend: certifica la **postura de seguridad** sobre la que se apoya la capa UI.

| # | Asercion | Resultado |
|---|---|---|
| 1 | `authenticated` conserva EXECUTE en los 8 RPC que la UI llama (incluido `start_missile_attack`) | PASS 8/8 |
| 2 | `anon` NO alcanza `start_missile_attack` | PASS 0 |
| 3 | Los 12 helpers de solo lectura siguen cerrados (no se salta el RLS) | PASS 0 expuestos |
| 4 | El cliente no puede INSERT en `planet_defenses`/`planet_buildings` ni INSERT/UPDATE en `fleet_movements` | PASS |
| 5 | `start_missile_attack` conserva `user_id = auth.uid()` y `FOR UPDATE` | PASS |

Verificaciones estaticas del componente:

| Invariante | Resultado |
|---|---|
| `<select>` en el DOM (selector de prioridad) | **ausente** |
| `p_target_priority` siempre `0` | unica ocurrencia |
| `insert` / `update` / `upsert` | ninguno |
| RPCs llamadas | `can_build_defense`, `start_defense`, `start_missile_attack` |
| lectura de `fleet_movement_ships` | ninguna (solo aparece en un comentario) |

`npm run cert:contracts` **PASS**: el inventario mecanico ya deriva `start_missile_attack  src/MissileControlPanel.tsx` y confirma que ningun operando de comparacion se filtra.

### 16.6 BROWSER — primer intento

**`BLOCKED — ENVIRONMENT`.** Faltan `DEV_EMAIL` y `DEV_PASSWORD` validos. **No** se simulo login ni se uso `service_role` como jugador.

> **SUPERSEDED por §16.7** (mismo dia, segunda vuelta: se apportaron credenciales de runtime y el
> arnes `scripts/missile-browser-certify.mjs` ejecuto **PASS 11/11**). Este apartado se conserva como
> registro historico del estado *anterior* de la certificacion, **no** como el estado actual.
> El estado vigente esta en §18.

Lo que **no** pudo certificarse en navegador *en ese primer intento*:

* que el silo se vea y responda en la vista de defensas;
* que `PRODUCIR 1` encole de verdad y el error de capacidad llegue Literally;
* que `BUSCAR OBJETIVO` resuelva coordenadas y `LANZAR IPM` cree el movimiento;
* que la lista de movimientos muestre la fila `MISSILE_ATTACK` y el informe llegue.

Lo que **si** esta certificado sin navegador: TypeScript, build, ESLint, `cert:contracts`, la fixture de permisos 5/5, y la invariantes estaticas del componente.

## 17. NOT IMPLEMENTED (UI)

* Selector de prioridad: **no se implementara**, D3 lo prohibe. No es un pendiente.
* Integrar el panel en la vista de GALAXIA como destino desde el mapa: hoy el destino se
  introduce por coordenadas, igual que el panel de soporte.
* Filtro por `MISSILE_ATTACK` en el selector de mision de `FleetCommandPanel`: el panel ya
  lista los movimientos del jugador, pero el desplegable de filtro no ofrece la opcion.
### 16.7 BROWSER CERTIFICATION - `PASS` 11/11 (2026-09-30)

`scripts/missile-browser-certify.mjs`. Edge headless + CDP nativo, **cero dependencias nuevas**.
Credenciales **solo de runtime** (`process.env`), nunca impresas, nunca en el repo.

| # | Comprobacion | Evidencia observada |
|---|---|---|
| 1 | Login real DEV por la UI, sin bypass | sesion establecida; el formulario desaparece |
| 2 | Vista de defensas navegada | vista abierta |
| 3 | El panel se renderiza | `SILO DE MISILES` presente |
| 4 | ABM e IPM en el catalogo | `ABM=true IPM=true` |
| 5 | Capacidad coherente | `nivel 4, 6/40 ranuras` |
| 6 | **Sin selector de prioridad (D3)** | `selects_en_panel=0`, sin `cheapest`/`expensive`/`prioridad` |
| 7 | **Produccion real** | `Misil antibalistico: produccion en cola.` y `Misil interplanetario: produccion en cola.` |
| 8 | Campos de objetivo por coordenadas | presentes, `alcance=49` |
| 9 | Resolver objetivo ajeno | `destino=[1:1:3]` = `AI World G1:S1:P3` |
| 10 | **Lanzamiento real** | `1 IPM en vuelo hacia AI World G1:S1:P3` |
| 11 | Movimiento visible en el panel | seccion `MISILES EN VUELO` presente |

Comprobado ademas en base de datos tras el lanzamiento:

| Hecho | Valor |
|---|---|
| tipo de mision | `MISSILE_ATTACK` |
| `target_priority` | `0` (cheapest, D3) |
| IPM en `fleet_movement_ships` | **0 filas** — el IPM no es una nave |
| `missile_count` | `1` |
| tiempo de vuelo | `30 s` = `(30 + 60 x 0) / 1` a distancia 0 |
| consumo de IPM | `1 -> 0` (exactamente una vez) |
| estado final | `COMPLETED`, **sin viaje de vuelta** |
| informes | 1 atacante + 1 defensor, por `create_player_message` |

Tambien se verifico el camino de rechazo: apuntando al propio hogar, la UI muestra
`No puedes lanzar contra tu propio cuerpo.` y no se crea movimiento.

**Cuatro correcciones al arnes** (no al producto), las cuatro por el mismo motivo: dentro de un
*template literal* un `\s` se consume como escape y el JS inyectado queda malformado, produciendo
`SyntaxError` o regex rotos que dan FAIL falsos. Se reescribieron esos helpers con parseo textual
y sin regex.

#### Estado del jugador DEV tras la certificacion

Para poder ejercitar el camino feliz hubo que dar a la cuenta DEV (`DevPlayer`) lo que el panel
necesita: `missile_silo 4` (40 ranuras), `shipyard 4`, `impulse_drive 10` (alcance 49) y recursos.
**Nada de eso forma parte del producto**: se elimino todo al terminar y se verifico residuo 0.

| Concepto | Tras limpiar |
|---|---|
| movimientos `MISSILE_ATTACK` | 0 |
| informes de misil | 0 |
| ABM/IPM en stock | 0 |
| cola de defensas de misiles | 0 |
| `missile_silo` del DEV | 0 (eliminado) |
| `impulse_drive` del DEV | 0 (eliminado) |
| `shipyard` del DEV | `1` (restaurado) |

Limitacion honesta: el desarrollo de la UI se certifico en la sesion actual de la rama `main`
local, servida como `dist/client`. La llegada y el settlement se verificaron por el worker real y
por `player_messages`, no visualmente en pantalla, porque el panel solo lista los movimientos y
el resultado se lee en la bandeja de mensajes.
---

## 18. VERIFICACION END-TO-END Y ESTADO DE CIERRE (mision 2026-10-02)

> **ESTADO CANONICO: `CLOSED — BACKEND / LIVE VERIFIED`.**
> Esta seccion es la representacion unica y vigente del estado del Missile System.
> Si alguna otra seccion de este documento (o de otro documento del repo) discrepa, **manda §18**.

```text
Backend implementation       CLOSED
D1                           CLOSED
LIVE verification            CLOSED
Fixtures                     CLOSED / VERIFIED
Static verification          CLOSED
Browser re-certification     NOT RUN (no es requisito de cierre del backend)
Migration ledger drift       DOCUMENTED (fuera del alcance funcional)
```

Esta seccion es la que cierra el ciclo. A diferencia de §12 y §16, aqui las fixtures se
**ejecutaron de verdad contra LIVE** (no se simularon y no se marcaron PASS sin correr).

### 18.1 Que se corrigio ANTES de poder certificar

> **DOCUMENTATION / TEST FIXTURE DEFECT — NOT a product defect.**
> Los fallos de abajo estan en las **fixtures**, no en el Missile System. El producto no cambio de
> comportamiento en ningun momento: los defectos impedian que las pruebas **ejercitaran** el codigo.

Las tres fixtures existian pero **no eran ejecutables**. Los fallos eran de las fixtures, no del
producto: por eso `missile_target_priority_regression.sql` nunca pudo haber producido el "PASS"
que el documento afirmaba.

| # | Fichero | Defecto real | Correccion |
|---|---|---|---|
| F1 | `missile_target_priority_regression.sql` | `INSERT` sin terminador (linea 75) y `for i in 1..5 loop` **sin `end loop`**: error de sintaxis, el fichero no compilaba | `ON CONFLICT` + cuerpo del bucle D4 reescrito (5 lecturas iguales) |
| F2 | `missile_system.sql` | `player_research` y `planet_buildings` sin `ON CONFLICT` → `23505 duplicate key` en cuanto el jugador ya tenia esa investigacion | `ON CONFLICT ... DO UPDATE` |
| F3 | `missile_system.sql` | `check_defense_requirements(...)` usado como booleano, pero devuelve `TABLE(...)` → `42804 argument of AND must be type boolean` | `select r.allowed into v_res ...` |
| F4 | `missile_system.sql` | caso 46 recogia en `v_res` (record) y comparaba contra `text[]` → `42883 record = text[]` | recoger en `v_ids` |
| F5 | `missile_system.sql` | caso 27 afirmaba origen "limpio", pero el caso 23 ya habia insertado 10 IPM | la aportacion del ABM se aisla por diferencia |
| F6 | `missile_system.sql` | caso 30c usaba un cuerpo **sin `shipyard`**, asi que `start_defense` fallaba por el prerrequisito y **nunca llegaba** a la rechazo por capacidad | se anade `shipyard 1` a ese cuerpo |

F5 y F6 son los mas relevantes: ambos hacian que la asercion pasara **sin ejercer la ruta que
debia certificar** (capacidad / slots). Un fixture verde sobre esa base no certifica nada.

### 18.2 Casos nuevos anadidos por la mision

La matriz exigida por la mision tenia huecos reales en las fixtures:

| Caso | Que prueba | Resultado |
|---|---|---|
| `I2b` | `process_fleet_movements()` invocado **3 veces** sobre el mismo movimiento vencido: una sola liquidacion y exactamente un informe por lado | PASS |
| `I2c` | esas 3 vueltas **no duplican la destruccion** ni dejan cantidades negativas | PASS |
| `T1` | **objetivo sin nada elegible** (solo misiles): 0 destruidas, stock del defensor intacto, mision `COMPLETED` | PASS |
| `S6b` | el cliente no puede **falsear `missile_count`**: pedir mas IPM de los que hay se rechaza y no consume ni crea movimiento | PASS |
| `S5b` | el lanzamiento con origen ajeno **no deja rastro** (ningun movimiento creado) | PASS |
| `M5` | el informe del atacante **no** se direcciona a otra identidad | PASS |

### 18.3 Resultados ejecutados en LIVE

Todas transaccionales, todas terminan en `ROLLBACK`. Residuo verificado = 0.

| Fixture | Resultado |
|---|---|
| `missile_ui_surface.sql` | **5 PASS / 5** |
| `missile_target_priority_regression.sql` | **13 PASS / 13** (tras F1) |
| `missile_system.sql` — silo, ABM, IPM, capacidad (1..30d) | **31 PASS / 0 FAIL** (tras F2, F3, F5, F6) |
| `missile_system.sql` — rango, vuelo, lanzamiento, intercepcion, prioridad (31..50e) | **26 PASS / 0 FAIL** (tras F4) |
| `missile_system.sql` — combate, idempotencia, seguridad, demolicion, informes, worker | **PASS / 0 FAIL**, incluidos I2b/I2c/T1/S6b/S5b/M5 |

Comprobaciones de contrato leidas directamente del catalogo de LIVE:

```text
missile_silo              20000/20000/1000  60 s  time_factor 2  PLANET+MOON
anti_ballistic_missile     8000/2000/0       60 s  hull 800   1 ranura
interplanetary_missile    12500/2500/10000  60 s  hull 1500  atk 12000  2 ranuras
vuelo                      (30 + 60*distancia_sistemas) / velocidad_universo
alcance                    (impulse_drive * 5) - 1
```

### 18.4 Estado final

* LIVE: el bloque esta aplicado con nombres/versiones propios del ledger (ver la nota de la cabecera).
* ACL: `start_missile_attack` ejecutable por `authenticated`, **no** por `anon`; los 12 helpers de
  solo lectura siguen **cerrados** al cliente para no saltarse el RLS owner-scoped.
* Sin movimiento paralelo: el misil viaja por `process_fleet_movements`, el worker existente.
* **Navegador: no re-certificado en esta mision.** El PASS 11/11 de §16.7 es de 2026-09-30 y no se
  ha repetido aqui; no se declara browser PASS.

### 18.5 D1 — decision canonica

```text
D1 — DECIDED

LGI missile build times:

Silo:
  base_build_time_seconds = 60
  time_factor             = 2

Anti-Ballistic Missile:
  base_build_time_seconds = 60

Interplanetary Missile:
  base_build_time_seconds = 60
```

* Documentada en §9 y en la cabecera de las migraciones del bloque.
* **Contrastada directamente contra el catalogo de LIVE** (consulta de `building_definitions` y
  `defense_definitions`), no solo contra la documentacion.
* **No debe reabrirse** como product decision salvo nueva decision humana explicita.

**Justificacion (la que ya existia, sin cambios).** LGI usa `base_build_time` **en segundos** como
convencion economica para toda la economia temporal (edificios, naves, defensas). Sustituirlo
automaticamente por la formula de OGameX `(metal + crystal) / 2500` horas produciria tiempos de
construccion **30x-100x mas largos** que los de cualquier otra defensa y que el balance y la
arquitectura temporal actuales de LGI no soportan. OGameX es referencia de estudio, no autoridad de
balance sobre LGI.

### 18.6 Implementacion ya existente (esta mision NO anadio codigo de producto)

```text
Launch:     start_missile_attack
Arrival:    resolve_missile_attack_arrival
Movement:   process_fleet_movements   (el worker existente; no hay segundo motor)
Frontend:   src/MissileControlPanel.tsx
```

Garantias ya verificadas (resumen; **no** es una auditoria de seguridad nueva):

```text
auth.uid() -> players.user_id -> ownership -> FOR UPDATE locking
```

ademas de: validacion de alcance `(impulse_drive*5)-1`; validacion de distancia; validacion de
stock de IPM; validacion de prioridad 0-9; validacion autoritativa de objetivo/propietario;
resolucion **idempotente**; destruccion a traves del motor de `planet_defenses` **existente**
(sin motor paralelo); creacion de informes via `create_player_message` con **dedupe por mision**.

### 18.7 Prioridad de destruccion

```text
cheapest
  -> metal + crystal ASC
  -> defense_id ASC   (desempate determinista, D4)
```

Ya esta **determinada y certificada**; no requiere nueva decision de producto. La rama
`expensive` (modo 1) esta implementada y verificada en §4.3: antes era un no-op silencioso.

### 18.8 Verificacion estatica

```text
TypeScript            PASS
Build                 PASS
Lint                  0 errors / 7 pre-existing warnings
Contract certification PASS — 74 RPC names
git diff --check      PASS
```

Los 7 warnings de lint son **preexistentes** y ajenos a este sistema; no son blocker ni se
convertiron en deuda nueva.

### 18.9 Verificacion LIVE

```text
Migration status:  APPLIED
RPCs:              PRESENT / SECURITY DEFINER / ACL VERIFIED
Runtime:           END-TO-END VERIFIED, incluido el worker real ejecutado x3
Residue:           0 tras la verificacion
```

**Migration ledger drift: `OPEN / DOCUMENTED`.** LIVE aplico el bloque con nombres y versiones
distintos de los ficheros del repo. **No** se repara con `supabase db push` (prohibido en este
proyecto): la unica remediacion permitida seria renombrar un fichero del repo para que coincida
con una fila del ledger. Queda **fuera del cierre funcional** del Missile System.

### 18.10 Browser certification

```text
Browser certification (esta mision):  NOT RUN
Reason:                              no DEV credentials disponibles en el entorno
```

La certificacion historica `PASS 11/11` (§16.7, 2026-09-30) se conserva como **historica**. No se
presenta como una ejecucion de esta mision ni como una nueva afirmacion de certificacion.

```text
Backend:                    CLOSED
Browser re-certification:   NOT RUN
```

La ausencia de browser certification **no** se convierte en una afirmacion de que el sistema
completo fue certificado por navegador, ni en un blocker del backend: el backend esta verificado
por otra via (contratos, fixtures LIVE y worker real).

### 18.11 Regla de no reapertura

```text
The Missile System is CLOSED for backend implementation.

Do not reopen:
- D1
- missile launch
- missile travel
- missile arrival
- destruction priority
- report generation
- ownership/security

unless new evidence demonstrates an actual regression.
```

Una futura certificacion en navegador puede completar la evidencia de UI, pero **no** debe
provocar una nueva implementacion del backend.