# GAMEPLAY GAP SWEEP — 2026-09-30 (segunda vuelta, OGameX → LGI → LIVE)

Misión de **investigación y clasificación**. **NO se implementó nada.**
`MIGRATIONS = 0` · `RPC = 0` · `CAMBIOS FUNCIONALES = 0` · `FIXTURES = 0`.
Único fichero escrito: este informe. No se tocó ningún sistema cerrado.

## 1. SYNC GATE

```text
branch          main
HEAD            3669e27e4e9d9f44c68f12244e7a4e4154127b0f  (2026-09-28)
origin/main     75bbc48e2b55dc8439ab17e52e254218b96ef8aa  (2026-09-28)
merge-base      3669e27  (= HEAD)  →  NO hay divergencia
ahead/behind    0 / 1        staged 0     deleted 0
commit remoto   75bbc48 "docs: add Marcianitos learning context"
                → toca SOLO docs/MARCIANITOS_GALAGA_CONTEXT.md (fichero nuevo, sin colisión)
modified 19 · untracked 32 · stashes 5 (intactos) · rutas 51
git diff --check  0
```

Sin pull / push / commit / merge / rebase / reset / clean / checkout / restore /
stash-pop / `supabase db push` / `migration repair`. Todo el trabajo local queda intacto.

## 2. FUENTES OGAMEX (rutas reales, `main` verificado hoy)

Descargadas y leídas literalmente (no de memoria documental):

| Fuente | Ruta | Qué se comprobó |
|---|---|---|
| `lanedirt/OGameX` | `app/GameObjects/BuildingObjects.php` | fórmulas de minas / solar / fusión / almacenes |
| idem | `app/GameObjects/StationObjects.php` | robot_factory, shipyard, research_lab, alliance_depot, missile_silo, nano_factory, terraformer, space_dock, lunar_base, sensor_phalanx, jump_gate + **todos sus `requirements`** |
| idem | `app/GameObjects/CivilShipObjects.php` | 8 naves civiles + **`solar_satellite` con `production->energy_formula`** + crawler + pathfinder |
| idem | `app/GameObjects/MilitaryShipObjects.php` | 9 naves militares (**ninguna con `production`**) |
| idem | `app/GameObjects/DefenseObjects.php` | 10 defensas (**ninguna con `production`**) |
| idem | `app/GameObjects/ResearchObjects.php` | 16 tecnologías + prerrequisitos |
| idem | `app/Services/ObjectService.php` | `getObjects()` = Buildings + Stations + Research + MilitaryShips + CivilShips + Defenses |
| idem | `app/Services/PlanetService.php` | `updateResourceProductionStatsInner`, `getObjectProduction(Index)`, `getPlanetTempMax/Min/Avg`, `getCrawlerEnergyConsumption` |

**Rutas antiguas de la documentación confirmadas 404** (`application/Settings/*`, `app/Settings/*`).
`app/GameObjects/*Objects.php` es la ruta vigente; ya corregido en el informe del 2026-09-30.

## 3. HALLAZGO PRINCIPAL — `solar_satellite` no produce energía (B + D, NO A)

Es el **único** objeto de todo el catálogo OGameX con fórmula de producción que LGI no implementa.
Verificado sobre los 6 ficheros de `*Objects.php`: sólo tienen `production` las 3 minas, la planta
solar, la fusión y **el satélite solar**.

```text
OGameX  CivilShipObjects.php
        $solarSatellite->production->energy_formula = fn (...) =>
            floor(($planetService->getPlanetTempMax() + 140) / 6) * $level;
        // TODO: solar satellite production formula should be dependent on the planet
        //       position: proximity to sun.                      ← TODO del propio OGameX

OGameX  ObjectService::getObjects() incluye CivilShipObjects
        → getGameObjectsWithProduction() incluye el satélite
        → PlanetService::updateResourceProductionStatsInner():
              if ($production->energy > 0) $energy_production_total += ...
        ⇒ EN OGameX EL SATÉLITE SÍ PRODUCE ENERGÍA (para una nave, la "level" es la cantidad)

OGameX  getPlanetTempMax() → $this->planet->temp_max, o 0 si está vacío.
        La columna la crea la migración 2017_12_17_203617 y NADA en el árbol la puebla
        (verificado: ni CreateNewUser, ni NPCPlanetService, ni PlanetListService).
        ⇒ valor efectivo de OGameX = floor((0+140)/6) = 23 energía/satélite, CONSTANTE,
          precisamente porque la parte que depende de la posición está sin hacer (su propio TODO).

LGI LIVE  ship_definitions: solar_satellite (0 / 2 000 / 500, 20 s, {PLANET,MOON}, shipyard 1)
          → CONSTRUIBLE y comprable.
LGI LIVE  procsrc ILIKE '%solar_satellite%' → UNA sola función: execute_jump_gate (lista de
          no transferibles). NINGUNA función de producción lo menciona.
LGI LIVE  calculate_planet_production: energía = planta solar + planta de fusión. Punto.
          ⇒ 2 000 cristal + 500 deuterio comprados por el jugador → 0 efecto. NAVE INERTE.

LGI LIVE  planets.temperature_min / temperature_max EXISTEN pero son un stub:
          - 700+ planetas vivos: temperature_min/max = NULL
          - resolve_colonize_arrival inserta la constante (-20, 20) para TODAS las posiciones
```

**Por qué NO es GAP A (no implementable sin inventar):**

1. El hecho de que deben producir energía está determinado (OGameX **y** clásico). La ausencia es real.
2. El **valor** NO está determinado por ninguna fuente:
   - el 23 de OGameX es un artefacto de un TODO, no una regla;
   - la fórmula clásica `floor((T_max+140)/6)` exige un modelo de temperatura por posición que LGI
     no tiene: aplicarla hoy daría 26/satélite en toda colonia (T=20 fija) y 23/satélite en los mundos
     IA (NULL→0), un número desligado de la posición y **distinto según el cuerpo**;
   - hacerlo significativo exige adoptar la tabla de temperaturas clásica **y** backfill de
     700+ planetas = decisión de reglas planetarias.
3. Además tocaría `calculate_planet_production`, núcleo del sistema **Economía CLOSED** (§5).

→ **B — PRODUCT DECISION** (adoptar o no un modelo de temperatura planetaria) con
**D — EVIDENCIA INSUFICIENTE** sobre la magnitud. **No implementado.**

## 4. CANDIDATOS EVALUADOS Y DESCARTADOS

| # | Candidato | OGameX / clásico | LGI | Veredicto |
|---|---|---|---|---|
| 1 | `shipyard → robot_factory 2` | sí | **no** (0 filas) | **B — YA DECIDIDO.** `supabase/tests/robot_factory.sql:218` lo registra literal: *"The OGameX shipyard -> robot_factory 2 gate is NOT applied: it would invalidate existing empires that already own a shipyard, so it stays a product decision."* Además `building_prerequisites` se evalúa **por planeta** y `robot_factory` es PLANET-only ⇒ la fila **prohibiría el shipyard en las lunas**, rompiendo la mecánica lunar certificada. No se reabre. |
| 2 | `space_dock → shipyard 2` | sí | no | **B.** El Space Dock es **definido y balanceado por LGI** de forma explícita y CLOSED (`README_FLEET_ENGINE.md:1362-1365`: *"Space Dock is LGI-defined and balanced"*, precio 400/200/100 frente a 200/0/50/50 de OGameX). Añadirle un prerrequisito reabre un sistema cerrado. |
| 3 | Prerrequisitos de naves | ver §2 | divergen | **B.** Las divergencias van **en las dos direcciones** ⇒ no hay fuente única: `battlecruiser` sin `laser_technology 12`; `bomber` shipyard 6 vs 8; `reaper` shipyard 10 vs 6 y sin `impulse 6`/`weapons 8`/`shielding 6`; `battleship` hyper_drive 3 vs 4; `recycler` sin `shielding 2`; `pathfinder` distinto. Adoptar un subconjunto = decisión de curva de progresión sobre Shipyard/Research CLOSED. |
| 4 | Prerrequisitos de defensas | ver §2 | divergen | **B.** `heavy_laser` shipyard 3 vs 4 y sin `energy_technology 3`; `plasma_turret` con `energy_technology 8` de más. Mismo razonamiento que #3. |
| 5 | Prerrequisitos de investigación | ver §2 | divergen | **B.** Coinciden 13 de 16; difieren `plasma` (laser 5 vs 10, falta energy 8), `weapons_technology` (LGI **exige** laser 3, OGameX no) y `graviton` (LGI **exige** energy 12, OGameX no). Research CLOSED. |
| 6 | Building prerequisites existentes | — | `fusion_plant→deut 5 + energy 3`, `sensor_phalanx→lunar 1`, `jump_gate→lunar 1 + hyper 7` | **C — YA IMPLEMENTADO**, y los 3 coinciden **verbatim** con OGameX. |
| 7 | Research building prerequisites | `research_lab = N` en 16 | 16 filas idénticas | **C — MATCH** (el mecanismo IRN/lab ya no es un gap; la documentación vieja que lo daba por abierto está desactualizada). |
| 8 | Catálogo edificios | 19 | 15 | **B / D** — faltan `alliance_depot`, `terraformer` (requieren alianzas, ausentes por decisión de alcance), `missile_silo` y `nano_factory` (decisiones de producto ya declaradas). |
| 9 | Catálogo defensas | 10 | 8 | **B** — faltan ABM(502) e IPM(503): decisión de producto declarada (rediseña el combate). |
| 10 | Catálogo naves / tecnologías | 17 / 16 | 17 / 16 | **C — MATCH** objeto a objeto, precios y tiempos. |
| 11 | `anon` con EXECUTE en 3 funciones `SECURITY DEFINER` | — | `can_start_building`, `get_universe_evolution_monitor_public`, `sync_current_planet_resources` | **C — SIN AGUJERO.** Las tres se autocierran: las dos primeras con `auth.uid()` + `PLAYER_NOT_OWNED` / `AUTHENTICATION_REQUIRED`, la tercera es un agregado público de universo por diseño. Ownership correcto. |
| 12 | Exclusiones §6 (Lifeforms, Alloys, overload, crawlers excedentes, silo/ABM/IPM, nanite, PG-09, PG-10, browser) | — | — | **No reauditadas**, sin nueva evidencia. |

## 5. CONTRAPOSITIVO (lo que la ausencia SÍ deja ver)

* El único valor numérico defendible hoy sería **23 energía/satélite**, copiando el artefacto de OGameX.
  Es un número que ninguna fuente declara como regla (el propio OGameX lo marca como pendiente) y que
  **no depende de la posición**: en el juego clásico el satélite vale entre 16 y 63 según la posición.
  Fijarlo sería inventar balance.
* Alternativa "sin coste": aceptar el 0 actual. Es lo que hay hoy y por eso el coste de no hacer nada
  es acotado (el jugador pierde 2 500 de recursos por satélite).
* La decisión de producto que desbloquea el §3 es una sola y está bien formulada:
  **¿LGI adopta temperaturas planetarias por posición (tabla clásica 240…−40) con backfill de los
  planetas existentes, o mantiene el modelo actual?**

## 6. VERIFICACIÓN

```text
LIVE (read-only)  catálogos 15/17/8/16 · building_prerequisites 3 filas · research_building 16 ·
                  research_prerequisites 16 · ship_prerequisites 45 · defense_prerequisites 18 ·
                  calculate_planet_production.prosrc (energía = solar + fusión, sin satélites) ·
                  temperature stub (NULL en todos los planetas vivos, −20/20 en colonización) ·
                  ACL de las 3 funciones SECDEF con EXECUTE para anon
git diff --check  0
MIGRATIONS        0
RPC               0
CAMBIOS DE CÓDIGO 0
```

`npx tsc -b`, `npm run build` y `npx eslint src` **no se ejecutan**: esta misión no ha modificado
ningún fichero de `src/`, `supabase/` ni `package.json`, luego no hay regresión que introducir que
verificar. El árbol de trabajo mantiene el estado que dejó la misión previa (Robot Factory, 2026-09-30).

## 7. CONCLUSIÓN

**NO TECHNICAL GAP — STOP.**

No se ha implementado nada. No queda ninguna mecánica técnica cuya fuente determine el comportamiento
sin decisión humana. El único defecto real encontrado (el satélite solar inerte) está bloqueado por una
decisión de producto previa y explícita: el modelo de temperatura planetaria.



