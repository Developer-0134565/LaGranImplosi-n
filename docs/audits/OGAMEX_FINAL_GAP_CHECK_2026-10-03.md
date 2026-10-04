# OGameX FINAL GAP CHECK — 2026-10-03

> **Resultado: `REAL GAPS = 0`.** Misión de diagnóstico: **no se modificó una sola línea de código**
> (ni SQL, ni RPC, ni TS/TSX, ni CSS, ni fixtures). Todos los probes corridos dentro de
> `BEGIN … ROLLBACK`; **residuo = 0** verificado.
>
> `REAL GAPS = 0` es un **PASS**, no un fracaso. El objetivo era demostrar qué falta de verdad.

```text
REAL GAPS FOUND            0
IMPLEMENTED (esta misión)  0  — nada estaba ausente de forma objetiva
NO GAP (verificado)        16 áreas del matrice
PRODUCT DECISION REQUIRED  3 (documentadas, NO implementadas)
ENVIRONMENT BLOCKED        1 (certificación browser de flotas)
```

## 1. Método

```text
sync gate      main, behind 2, sin divergencia, 22 modificados / 98 untracked / 5 stashes, preservados
superficie UI  scripts/contract-inventory.mjs -> 93 nombres RPC/tabla realmente invocados
contraste      cada uno contra pg_proc + has_function_privilege('authenticated', …) en LIVE
inverso        todos los `start_*`/`recall_*`/`trade_*`/`set_*` autenticados vs. sus consumidores en src/**
circuito       certification extremo a extremo real (no "el RPC existe")
```

Comparación OGameX: `docs/reference/README_OGAMEX_LGI_MAP.md` (2026-09-25) **más** el cuerpo real de
las funciones de LIVE. No se copió código PHP/Laravel.

## 2. El mapa de referencia está OBSOLETO en puntos concretos

Antes de buscar gaps nuevos se contrastó el mapa existente con LIVE. **El mapa de 2026-09-25 ya no
describe el sistema**; listar sus filas como verdad habría producido falsos gaps:

| Fila del mapa (2026-09-25) | Estado real en LIVE (2026-10-03) |
|---|---|
| `MissileMission` — **MISSING** (sin silo, ni ABM/IPM) | **IMPLEMENTADO y verificado** (`start_missile_attack`, `resolve_missile_attack_arrival`, silo+ABM+IPM) |
| `MoonDestructionMission` — **MISSING** (no existe el tipo luna) | **IMPLEMENTADO** (`start_moon_destruction`, lunas existentes) |
| `getObjectDowngradePrice` + `addDowngrade` — **MISSING** | **IMPLEMENTADO** (`calculate_building_demolition_cost` con Ion 4 %/nivel, `start_demolition`) |
| `dispatchRecallFleet` — **MISSING**, "ningún RPC recall_*" | **IMPLEMENTADO** (`recall_fleet`, `authenticated` + `SECURITY DEFINER`, consumido por la UI) |
| `CleanupWreckFields` / `DeleteOldMessages` — **MISSING** | **IMPLEMENTADO**: `run_wreck_field_worker` y `run_message_retention_worker` están en `cron.job` |
| Crawler overload — sin fuente | **IMPLEMENTADO 2026-10-03** (0–150 %) |

**Ninguno de estos es un gap hoy.** Registrado para que nadie los reabra por leer el mapa viejo.

## 3. Matriz de gameplay

| Área | OGameX | LGI | Estado | Evidencia LIVE |
|---|---|---|---|---|
| Buildings | `BuildingObjects` + cola | `start_building` + `building_queue` + `can_start_building` | CLOSED | cola vencida liquida con `floor`; guard de energía integrado |
| Research | cola de investigación | `start_research` + `research_queue` | CLOSED | vencida `RESEARCHING→COMPLETED`, nivel +1, reproceso no duplica |
| Production | `updateResources` | `calculate_planet_production` | CLOSED | energía/almacén/plasma verificados en fixtures previas |
| Queues | `time_end<=now` ⇒ COMPLETE | los 4 procesadores | CLOSED | `finishes_at <=` + `COMPLETED`; **ninguno** menciona `cancel` |
| Fleet | `GameMission::start` | `start_fleet`, `start_fleet_mixed` | CLOSED | circuito TRANSPORT ejecutado de extremo a extremo (§4) |
| Missions | catálogo de misiones | ATTACK/TRANSPORT/DEPLOY/ESPIONAGE/COLONIZE/RECYCLE/EXPEDITION/ACS_HOLD/MISSILE_ATTACK/MOON_DESTRUCTION | CLOSED | CHECK de `mission_type` acepta todos |
| Combat | `resolve_combat` | `resolve_attack_arrival` + 11 tablas `combat_*` | CLOSED | ya certificado (H3, cerrado) |
| Espionage | `PhalanxService` | `scan_with_phalanx` | CLOSED | devuelve flotas `OUTBOUND/RETURNING` hacia el sistema (§5) |
| Expeditions | expedición + mercader | `get_player_expedition_merchant`, `trade_with_expedition_merchant` | CLOSED | contratos presentes y consumidos |
| Planets | `PlanetService` | `planets` + RLS owner-scoped | CLOSED | 0 fugas cross-owner |
| Moons | `MoonService` | `get_player_moons`, `scan_with_phalanx`, `execute_jump_gate` | CLOSED | triggers `MOON_*` verificados en vivo |
| Colonization | `ColonizeMission` | `start_colonize_fleet` | CLOSED | contrato presente y consumido |
| Recycling/debris | limpieza de restos | `collect_debris`, `get_recyclable_debris_status` | CLOSED | `collect_debris` es interno (no cliente) por diseño |
| Transport | `TransportMission` | `start_fleet_mixed` TRANSPORT | CLOSED | **certificado extremo a extremo** (§4) |
| Reports | informes | `create_player_message` + `get_player_*_reports` | CLOSED | dedupe por misión |
| Workers | `Schedule::command` | 6 jobs en `cron.job` | CLOSED | verificado abajo |

### Workers realmente activos en LIVE

```text
run_fleet_worker             1 s        run_ranking_worker        */5 min
process_universe_heartbeat   1 min      run_ai_policy_worker      */5 min
run_message_retention_worker 04:00      run_wreck_field_worker    */10 min
```

No hay workers muertos: los 6 están `active = true`.

## 4. Certificación extremo a extremo (§7, no "el RPC existe")

Dos circuitos completos ejecutados de verdad, con `auth.uid()` real y la sesión del jugador:

```text
TRANSPORT
  contrato      start_fleet_mixed · authenticated · SECURITY DEFINER
  ownership     sesión real; cuerpo ajeno y sesión falsificada RECHAZADOS
  despacho      fleet creado -> TRANSPORT / OUTBOUND
  worker        process_fleet_movements() -> COMPLETED
  persistido    destino +1000 metal; origen descontó la carga (deuterio 20000000 -> 19999998)
  visible       mensajes de informe generados
  idempotencia  2º tick del worker -> destino sigue en 1000 (NO duplica)

FALANGE (moon)
  contrato      scan_with_phalanx(player, moon, galaxy, system) · authenticated · SECURITY DEFINER
  ownership     luna ajena RECHAZADA; sesión falsificada RECHAZADA
  authoritative calcula el rango desde el nivel del sensor y cobra 5000 de deuterio en servidor
  persistido    deuterio 20000 -> 15000 tras un escaneo
```

## 5. Dos hipótesis descartadas por medición (NO eran gaps)

### 5.1 "El mapa dice que no hay purga de colas" → NO GAP

Los cuatro procesadores **no** borran filas terminales, y las filas `COMPLETED` más antiguas de LIVE
son del **2026-09-18** (15 días). Parecía un hueco de higiene. Se probó si **bloqueaba** el juego:

```text
sembradas 5 filas COMPLETED de hace 20 días + holgura energética
can_start_building -> allowed = true, reason = OK
start_building     -> LANZADO OK, nueva fila BUILDING
```

El backlog **no bloquea nada**: el motor filtra por estado. Volumen real: **9 filas** en las cuatro
colas. El mapa ya lo clasificaba como "higiene", y con 9 filas no es un gap objetivo según §4
(sin impacto de juego, sin crecimiento observable). **NO GAP.**

### 5.2 "`scan_with_phalanx` no genera informe" → NO GAP

La función **no** escribe en `espionage_reports` ni llama a `create_player_message`, y el escaneo
no dejó informe (0). Por §4 ("acción cuyo resultado no llega al jugador") parecía un circuito roto.
Leyendo el cuerpo completo:

```sql
return query
  select fm.id, fm.player_id, pl.username, fm.mission_type, fm.status, …
    from fleet_movements fm join players pl on pl.id = fm.player_id
   where fm.status in ('OUTBOUND','RETURNING')
     and fm.destination_galaxy = p_galaxy and fm.destination_system = p_system
```

Devuelve **flotas ajenas en tránsito hacia el sistema escaneado**, que es exactamente la semántica
de la falange en OGameX (detección de flotas, no censo de planetas). La UI lo consume como
"flota(s) en tránsito", que es el texto correcto. **NO GAP.**

## 6. Comparación OGameX → divergencias intencionales

| Comportamiento OGameX | LGI | Clasificación |
|---|---|---|
| Overload por clase (*Collector* 150 %) | 0–150 % para todos | **DIVERGENCIA INTENCIONAL** — LGI no tiene clases ni Lifeforms; no se inventó un *Collector* |
| Cola vencida ⇒ COMPLETE | idéntico | MATCH |
| Demolición = coste del nivel retirado − 4 %/nivel Ion | idéntico | MATCH |
| Detección de flotas por falange | idéntico | MATCH |
| Resolución de eventos por *polling* del jugador | `pg_cron` 1 s global | **ADAPTACIÓN** (deliberada, ya documentada) |
| Mantenimiento programado de restos/mensajes | 2 workers `cron.job` | MATCH |
| `Lifeforms`, `CharacterClassService` | catálogo dormido, 0 datos de jugador | **FUERA DE ALCANCE** por misión (§2, §4) |

**No se implementó ninguna diferencia por el solo hecho de que OGameX la tenga.**

## 7. Product decisions (NO implementadas)

```text
DECISION REQUIRED — purga de filas terminales de las 4 colas
  Question:   ¿Debe LGI purgar filas COMPLETED, y con qué retención?
  Evidence:   no hay purga; 9 filas en LIVE; las más antiguas de 2026-09-18; NO bloquea el juego
              (probado); el mapa 2026-09-25 ya lo marca como "higiene".
  Interpret.: (a) no purgar (escala lento); (b) purgar con retención N días.
  Stopped:   la retención es un número que NADIE ha decidido, y borrar historial es destructivo.

DECISION REQUIRED — economía premium / Dark Matter
  Question:   ¿LGI monetiza Dark Matter más allá de los ingresos de expedición?
  Evidence:   `players.dark_matter` existe y sólo se credita por expedición. Marcado
              PARTIAL / PRODUCT DECISION desde 2026-09-25. Sin consumidor en `src/**`.
  Stopped:   modelo de negocio, no fallo técnico.

DECISION REQUIRED — adopción del tope global de flotas
  Question:   ¿LGI adopta el tope estilo OGameX `1 + computer_technology` (+2 General)?
  Evidence:   la derivación EXISTE (`calculate_player_max_fleet_slots`, `get_player_fleet_slots`,
              certificado), pero el tope NO se aplica. Marcado PARTIAL / PRODUCT DECISION.
  Interpret.: adoptarlo o no cambia el balance de forma global.
  Stopped:   el motor ya está; falta la decisión de si se aplica.
```

## 8. Estado por área (vocabulario permitido)

```text
Buildings / Research / Production / Queues / Fleet / Missions / Combat
Espionage / Expeditions / Planets / Moons / Colonization / Recycling
Transport / Reports / Workers                     CLOSED  (16 áreas verificadas)

Lifeforms                    OUT OF SCOPE (dormido, por instrucción de la misión)
Queue terminal purge         PRODUCT DECISION REQUIRED
Dark Matter premium          PRODUCT DECISION REQUIRED
Fleet slot cap adoption      PRODUCT DECISION REQUIRED
Fleet browser certification  CERTIFICATION BLOCKED (ENVIRONMENT)
```

## 9. Lo que esta misión NO hace

* No reabre ningún sistema CLOSED.
* No "inventa trabajo": los 3 candidatos que sobrevivieron al análisis se clasificaron como
  decisiones de producto, con la evidencia que la decisión necesita.
* No declara browser PASS: la certificación de flotas sigue `ENVIRONMENT BLOCKED`.

