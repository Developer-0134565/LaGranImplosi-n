# GAP CLOSURE 2026-09-30 — NANITE FACTORY, CRAWLER BALANCE, MISSILE SPEC, AUDITS

Misión de cierre de gaps ya decididos (Q1–Q15) con **auditoría previa obligatoria (FASE A)**.
`MIGRATIONS = 2` · `TESTS = 1 nuevo` · `UI = 0` · `RESIDUO = 0` · sin commit ni push.

## 1. SYNC GATE
```text
branch main · HEAD 3669e27 · origin/main 75bbc48 · merge-base 3669e27 (= HEAD) → SIN DIVERGENCIA
ahead/behind 0/1 (el commit remoto 75bbc48 es SOLO docs/MARCIANITOS_GALAGA_CONTEXT.md, sin colisión)
staged 0 · unstaged 20 · untracked 60 · deleted 0 · stashes 5 (intactos)
```
Sin pull / push / commit / merge / rebase / reset / clean / checkout / restore / stash-pop /
`db push` / `migration repair`. Todo el trabajo local preservado.

> **NOTA DE ALCANCE TEMPORAL.** Este documento es el registro de la sesión del **2026-09-30**. Las
> tablas de abajo describen el estado **en ese momento** y las celdas marcadas `ausente` /
> `especificado` relativas al Missile System **quedaron superadas el 2026-10-02**: el bloque de
> misiles está implementado y verificado en LIVE (`CLOSED — BACKEND / LIVE VERIFIED`). Ver
> `docs/systems/README_MISSILE_SYSTEM.md` §18. No se reescribe el histórico; se marca.

## 2. FASE A — AUDITORÍA (previo obligatorio)

| Objeto | OGameX (`main`, hoy) | LGI antes | Acción |
|---|---|---|---|
| `missile_silo` | id 44 · `GameObjectPrice(20000, 20000, 1000, 0, 2)` · req `shipyard 1` · sin `valid_planet_types` | **ausente** | especificado (§5) |
| `anti_ballistic_missile` | id 502 · `GameObjectPrice(8000, 2000, 0, 0)` · req `missile_silo 2` + `shipyard 1` · `Properties(SI 8000, escudo 1, ataque 1)` · **ranura 1** | **ausente** | especificado |
| `interplanetary_missile` | id 503 · `GameObjectPrice(12500, 2500, 10000, 0)` · req `shipyard 1` + `missile_silo 4` + `impulse_drive 1` · `Properties(SI 15000, escudo 1, ataque 12000)` · **ranura 2** | **ausente** | especificado |
| Capacidad del silo | `MissileSiloCapacityTest`: nivel 4 ⇒ 40 ranuras; **ABM 1, IPM 2**; silo 0 ⇒ 0; no se degrada con misiles dentro | — | especificado |
| Intercepción | `intercepted = min(ipm, abm_objetivo + abm_planeta_padre)`, **el padre primero** en lunas | — | especificado |
| Daño del IPM | poder = `n × 12000 × (1 + 0.1 × weapon_tech_atacante)`; armadura = `estructura × (1 + 0.1 × armor_tech_defensor) / 10`; `max = floor(poder / armadura)`; **los misiles no son objetivo** (la cúpula sí) | — | especificado |
| `nano_factory` | id 15 · `GameObjectPrice(1000000, 500000, 100000, 0, 2)` · req `computer_technology 10` + `robot_factory 10` · **PLANET only** | **ausente** | **IMPLEMENTADO** |
| Tiempos con nanite | edificios `…·(1+robot)·2^N`; `getUnitConstructionTime` (naves **y** defensas) `…·2^N`; `getTechnologyResearchTime` **sin nanite** | — | **IMPLEMENTADO** (respeta la distinción de tipos) |
| Tiempos base de unidades | `(metal + cristal) / (2500 · (1 + hangar) · velocidad · 2^N)` h | `base_build_time_seconds` por nave | **AUDITADO** (§6) |
| `shipyard → robot_factory 2` | existe en `StationObjects` | ausente | **NO aplicado** (§4) |
| `space_dock → shipyard 2` | existe en `StationObjects` | ausente | **AUDITADO, no aplicado** (§4) |
| `fuel` del satélite | `Properties(..., fuel 1)` | 0 | **AUDITADO**: sin efecto (§6) |

## 3. IMPLEMENTADO

### 3.1 Nanite Factory — `20260930210000_nanite_factory.sql`
Definición OGameX verbatim (1 000 000 / 500 000 / 100 000, factor de coste 2, `{PLANET}`) y los dos
prerrequisitos (`robot_factory 10` como edificio, `computer_technology 10` como investigación).
Regla única **`calculate_nanite_factory_build_speed(planet) = 2^nivel`**, plegada en la MISMA tasa
efectiva que ya usa el Robot Factory:

```text
edificios     calculate_building_time(b, nivel, universo, planeta) = base / (robot × 2^nanite) / velocidad
naves         calculate_ship_build_time    = base / hangar / (velocidad × robot × 2^nanite)
defensas      calculate_defense_build_time = base / hangar / (velocidad × robot × 2^nanite)
INVESTIGACIÓN calculate_research_time      → SIN cambios (byte-idéntica)
```
La divergencia documentada de LGI (upstream NO aplica `1+robot` a las unidades) se **preserva**: el
divisor `2^nivel` se compone con ella en lugar de revertirla, porque revertir reabriría una decisión
cerrada del Robot Factory.

### 3.2 Crawler energy balance (Q13) — `20260930211000_crawler_energy_balance.sql`
**El bug:** `calculate_planet_production` sumaba `crawlers_efectivos × 50` a su consumo, pero
`calculate_planet_energy_balance` —el contrato que la UI lee para "ENERGÍA PROD/CONS"— sumaba **solo**
`building_energy_definitions`. Un planeta con 40 crawlers reportaba el mismo consumo que uno sin ellos
mientras su producción estaba estrangulada por 2 000 energía/h.
**El arreglo:** helper único `calculate_crawler_energy_consumption(planet)` usado por **ambos** llamadores.
La producción conserva exactamente su valor anterior; solo el balance deja de contradecirla.
**Q1 intacta:** siguen consumiendo únicamente los crawlers efectivos (tope `(minas) × 8`).

## 4. AUDITADO SIN CAMBIAR (con motivo)

* **Q7 `shipyard → robot_factory 2`:** `building_prerequisites` se evalúa **por cuerpo** y
  `robot_factory` es PLANET-only mientras `shipyard` es legal en lunas ⇒ aplicar la fila **prohibiría el
  hangar lunar** y rompería la mecánica lunar certificada; además invalidaría empires existentes. Ya
  estaba registrado como decisión de producto en `tests/robot_factory.sql:218`. **No aplicado.**
* **Q8 recálculo de colas:** LGI guarda `finishes_at` absoluto al encolar y sus workers comparan
  `now() >= finishes_at`; el clásico acorta el tiempo *restante* de un trabajo ya en cola. Es una
  divergencia ya documentada. Un recálculo masivo exigiría modelo temporal, política de idempotencia y
  de concurrencia nuevos ⇒ **INFO / RESEARCH REQUIRED**, no un `UPDATE` a ciegas.
* **Q12 `space_dock → shipyard 2`:** el Space Dock es **definido y balanceado por LGI** de forma explícita
  y CLOSED (`README_FLEET_ENGINE.md`), con precio, tope 10 y tasa de reparación propios. Imponer la fila
  clásica sería perseguir paridad textual sobre una mecánica LGI. **No aplicado.**

## 5. MISSILE SILO + ABM + IPM — ~~ESPECIFICADO, NO IMPLEMENTADO EN ESTA SESIÓN~~ → **CERRADO**

> **SUPERADO (2026-10-02).** Este bloque **sí** está implementado y verificado en LIVE:
> `CLOSED — BACKEND / LIVE VERIFIED`. Estado canónico y detalle durable en
> `docs/systems/README_MISSILE_SYSTEM.md` §18. Se conserva el texto original como registro
> histórico de la sesión del 2026-09-30.

Todo el comportamiento está extraído y verificado desde `app/GameMissions/MissileMission.php` y
`tests/Feature/MissileSiloCapacityTest.php` (§2). **No se ha implementado nada de este bloque.** El
motivo es explícito, no una omisión:

* requiere un **nuevo tipo de misión de flota** (`fleet_movements.mission_type`), despachador, tiempo de
  vuelo, resolución de llegada y dos informes nuevos — es decir, modificar el **Fleet** y el **settlement
  de combate**, ambos CLOSED;
* §15 detiene la misión cuando *«el cambio exige tocar un sistema CLOSED»*;
* la evidencia permite determinar el daño (`poder = n × 12000 × (1+0.1·weapon)` contra
  `armadura = estructura × (1+0.1·armor)/10`) pero **no** el **orden de prioridad de defensas por misión**
  (`decodePriority` / `sortDefensesByPriority`): sin él el reparto sería inventado, y el propio OGameX lo
  deja configurable.

Es preferible dejar el bloque **especificado y verificable** que insertar medio bloque en Fleet/Combat con
una regla de prioridad inventada. Queda como GAP documentado para una misión dedicada.

## 6. Q9 TIEMPOS BASE DE NAVES y Q10 FUEL DEL SATÉLITE

* **Q9 — auditado, no convertido.** OGameX deriva el tiempo de `(metal + cristal) / 2500`; LGI usa
  `base_build_time_seconds` por objeto. Adoptar la fórmula upstream cambiaría los tiempos de las 17 naves
  en un factor de ~70 y rompería el equilibrio certificado del Shipyard. Se mantiene **una sola fuente**
  (`base_build_time_seconds`) y la divergencia queda documentada; el nanite se integra sobre ella.
  Para el satélite: OGameX **no** tiene tiempo propio (usa la fórmula compartida), así que sus 20 s son
  la convención de LGI; documentado, no convertido.
* **Q10 — auditado: `fuel` 0 vs 1 upstream no tiene efecto.** Con `speed = 0`,
  `calculate_fleet_travel_time` lanza `Ship speed must be greater than zero` **antes** de calcular
  combustible (certificado por `tests/solar_satellite.sql` prueba 16). Se mantiene 0 y la divergencia
  queda **deliberada y documentada**. El satélite **no** se ha convertido en nave de flota.

## 7. Q11 AUDITORÍA GLOBAL DE PRERREQUISITOS (resultado)

| Objeto | Estado | Nota |
|---|---|---|
| `robot_factory` | sin prerrequisitos (OGameX) | correcto |
| `nano_factory` | `robot_factory 10` + `computer_technology 10` | **añadido** (OGameX) |
| `shipyard` | ninguno | la fila de OGameX rompe lunas → no aplicada (§4) |
| `space_dock` | ninguno | mecánica LGI → no aplicada (§4) |
| `solar_satellite` | `shipyard 1` | correcto |
| Research → laboratorio | 16 filas idénticas a OGameX | correcto |
| ABM / IPM | ausentes *(estado 2026-09-30; implementado y verificado en LIVE el 2026-10-02)* | ver §5 |

Bypass detectado y cerrado: un `BEFORE INSERT` en `building_queue` ya rechaza por tipo de cuerpo
(`BUILDING_NOT_AVAILABLE_FOR_KIND`) y la nueva fábrica lo respeta (prueba 7 de la fixture). No se
introdujeron rutas de escritura nuevas.

## 8. Q14 MIGRATION LEDGER — SOLO DIAGNÓSTICO

| Fichero del repo | Versión aplicada en LIVE |
|---|---|
| `20260930090000_robot_factory.sql` | `20260930025831` |
| `20260930160000_planet_temperature_system.sql` | `20260930041846` |
| `20260930161000_planet_temperature_missing_planet_hardening.sql` | `20260930041918` |
| `20260930200000_solar_satellite_combat_profile.sql` | `20260930051714` |
| `20260930210000_nanite_factory.sql` | aplicado (versión de ledger propia del tool) |
| `20260930211000_crawler_energy_balance.sql` | aplicado (versión de ledger propia del tool) |

**No reparado** (Q14 y §15 lo prohíben). Comprobado que **no produce doble aplicación**: cada
`apply_migration` corrió dentro de una transacción y su bloque de post-condiciones aborta si el estado no
es el esperado; el estado final de LIVE es correcto y verificado por fixtures. Riesgo pendiente: un
`db push` futuro intentará reaplicar los ficheros locales. Decisión humana.

## 9. TESTS

| Fixture | Resultado |
|---|---|
| `nanite_and_crawler_balance.sql` (nueva) | **13 PASS / 0 FAIL** (ROLLBACK) |
| `fusion_and_crawler` (economía) | 10/10 PASS; re-verificado tras el cambio: fusión +220 energía, combustible exacto, ratios de crawler 1.019277 y 1.047550 idénticos a los certificados |
| Catálogo | edificios 16 (15 + nano_factory) · naves 17 · defensas 8 |
| `npx tsc -b` | exit 0 |
| `npx eslint src` | exit 0 (0 errores, 5 warnings preexistentes) |
| `npm run cert:contracts` | exit 0 PASS |
| `git diff --check` | 0 |

Detalle de la fixture nueva: definición verbatim · rechazo sin prerrequisitos · helper `2^nivel`
(1 sin fábrica, 8 en nivel 3) · tiempo de edificio dividido por 2 exacto al subir un nivel · **nave y
defensa** divididos por 2 · **investigación IDÉNTICA con nanite 4 y 8** · no encolable en luna ·
crawler 0/40/1000 con el tope de 240 efectivos (Q1) · el balance ahora reporta el consumo ·
producción intacta · ACL de los dos helpers · una sola autoridad en todas partes.

## 10. SEGURIDAD

* `calculate_nanite_factory_build_speed`: `SECURITY INVOKER`, `search_path` fijo, `EXECUTE` para
  `authenticated` + `service_role` (misma postura que el helper del Robot Factory). Sin escritura.
* `calculate_crawler_energy_consumption`: `SECURITY INVOKER`, `search_path` fijo, **`EXECUTE` sólo
  `service_role`** (como `calculate_planet_production`). Sin escritura.
* No se añadió ningún RPC de escritura, ni `player_id`/`planet_id` confiados desde cliente, ni acceso a
  `service_role` desde el cliente. Verificado en las pruebas 11 y 12.

## 11. RESIDUO
```text
planetas de prueba 0 · naves 2 (históricas) · 692 jugadores · 692 planetas
```

## 12. PENDIENTE
1. ~~**Missile Silo + ABM + IPM** — bloque especificado (§5), requiere misión dedicada.~~
   **CERRADO 2026-10-02** (`MISSILE_ATTACK` implementado y verificado en LIVE; ver README §18).
2. ~~**Prioridad de destrucción de defensas del IPM** — `decodePriority` / `sortDefensesByPriority` no
   extraídos; sin ellos el reparto sería inventado.~~ **CERRADO**: prioridad extraída de OGameX e
   implementada (`cheapest` → metal+crystal ASC → defense_id ASC).
3. **Q8** recálculo de colas al cambiar Robot/Nanite — requiere modelo temporal definido.
4. **Q7 / Q12** siguen siendo decisiones de producto.
5. **Q9** conversión de tiempos base a `(metal + cristal)/2500` — decisión de balance.
6. **Ledger** de migraciones — reconciliación humana.


