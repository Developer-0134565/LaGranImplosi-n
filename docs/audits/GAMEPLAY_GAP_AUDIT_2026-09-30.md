# GAMEPLAY GAP AUDIT — 2026-09-30 (LA GRAN IMPLOSIÓN)

Misión de **investigación, verificación y documentación**. **NO se implementó nada.**
`MIGRATIONS = 0`. Sin cambios funcionales, sin RPC, sin economía, sin UI.

## 1. SYNC GATE

```text
branch          main
HEAD            3669e27e4e9d9f44c68f12244e7a4e4154127b0f
origin/main     75bbc48e2b55dc8439ab17e52e254218b96ef8aa
merge-base      3669e27 (= HEAD)
ahead/behind    0 / 1        staged 0     deleted 0
modified        21           untracked 31
stashes         5 (intactos)
git diff --check  0
```

Sin pull/push/commit/merge/rebase/reset/clean/checkout/restore/stash/db push/migration repair.

## 2. FUENTES OGAMEX CONSULTADAS (rutas reales, `main` @ 2649076)

| Fuente | Ruta real | Qué se verificó |
|---|---|---|
| `lanedirt/OGameX` | `app/GameObjects/BuildingObjects.php` | minas, planta solar, **reactor de fusión**, 3 almacenes |
| idem | `app/GameObjects/StationObjects.php` | robot_factory, shipyard, research_lab, alliance_depot, space_dock, lunar_base, sensor_phalanx, jump_gate |
| idem | `app/GameObjects/DefenseObjects.php` | 8 defensas **+ anti_ballistic_missile(502) + interplanetary_missile(503)** |
| idem | `app/GameObjects/CivilShipObjects.php` | **crawler(217)** y su definición completa |
| idem | `app/GameObjects/ResearchObjects.php` | energy/laser/ion/hyperspace/graviton/weapons/shielding/armour |
| clásico documentado | `sidian.app/s/ogame-wiki` (act. 16-05-2026) | crawler, IPM, catálogo completo |
| PTS (no normativo) | foro oficial "CRAWLER LIMIT" | overload (fuente contested 2023-2025) |

**NOT FOUND IN CURRENT OGAMEX:** `application/Settings/BuildingObjects.php` y `app/Settings/*` (404).
La ruta correcta es `app/GameObjects/*Objects.php`. El repo se reestructuró.

## 3. CRAWLER OVERLOAD — respuesta a A

**El crawler base de LGI es correcto y coincide con OGameX y con el clásico:**

```text
OGameX crawler(217)   2000/2000/1000 · shipyard 4 · combustion 4 · armor 4 · laser 4 · PLANET only
OGameX NO define      ninguna fórmula de producción, tope ni overload en el objeto
Clásico               tope = (metal+crystal+deut)×8 · +0.0002 por unidad y nivel de mina · 50 energía por crawler ACTIVO
LGI                   idéntico (fixture fusion_and_crawler 10/10 PASS)
```

**¿Existe gap de overload?** — **NO como mecánica faltante; SÍ como divergencia documentada.**

1. **Divergencia real y verificable (la única de este bloque).** El wiki oficial dice, literal:
   *"Crawlers beyond the active cap exist but produce nothing **and still consume energy**."*
   En LGI el consumo se calcula sobre las crawlers **efectivas**, no sobre las poseídas:

   ```sql
   v_crawler_effective := least(v_crawler_count, (minas)×8);
   v_energy_consumption := v_energy_consumption + (v_crawler_effective * 50);   -- efectivas, no total
   ```

   ⇒ En LGI **las crawlers por encima del tope no consumen energía**; en el clásico **sí**.
   Toca la economía certificada ⇒ **decisión de producto**, no gap técnico.
   Dependencia: `calculate_planet_production` (núcleo certificado).

2. **"Overload" como porcentaje ajustable: EVIDENCE INCOMPLETE.** Sólo aparece en el foro PTS
   (techo global del 50 % de producción, sin resolver desde 2023). **No está** en el wiki oficial
   vigente ni en el código actual de OGameX. No se puede implementar sin inventar.

3. **Collector class** (`tope ×1.5`) e **Ion Crystal Modules** (Rock'tal, `crawler_efficiency_percent`)
   son de *clase de jugador* y *lifeforms* → ambos fuera del scope de LGI.

## 4. LIFEFORMS — respuesta a E

`EXCLUDED BY PRODUCT DECISION`. No es gap. **Observación de honestidad:** LGI *sí* tiene datos
sembrados (`lifeform_definitions` 4, `lifeform_research_definitions` 72, migración `20260912112952`)
y `calculate_planet_production` ya lee efectos de lifeform; el subsistema está excluido de alcance,
no ausente. Lifeforms tampoco desbloquean ningún otro gap de esta auditoría.

## 5. ALLOYS — respuesta a B

```text
[ ] OGameX confirmado
[ ] OGameX no confirmado
[x] clásico confirmado como AUSENTE
[x] pertenece a otra variante / no corresponde al scope actual
```

**Alloys NO es una mecánica de OGame.** La navegación completa del wiki OGame (Resources, Buildings,
Facilities, Moon, Classes, Defence, Research, Lifeforms, Combat Mechanics…) **no contiene "Alloys"**
en ninguna sección; los recursos canónicos son metal, cristal, deuterio y energía. La búsqueda web de
"alloys" devuelve únicamente juegos ajenos (tgstation, Elite Dangerous, Kittens Game, Xenonauts,
idle-planet-miner). En LGI: `0` columnas y `0` funciones con "alloy"; la única mención del repo es
una línea de `PROJECT_CONTEXT_PROMPT.md` que lo listaba como decisión de producto.

**Conclusión: "LGI necesita Alloys" NO se sostiene con evidencia.** Se retira de la lista de
candidatos. No es gap.

## 6. MISSILE SILO / MISSILE DEFENSE — respuesta a C

**Estado en LGI: los tres componentes NO EXISTEN** (`0` definiciones, `0` RPC, `0` columnas).

| Componente | OGameX (verificado) | Clásico (verificado) | LGI |
|---|---|---|---|
| Anti-Ballistic Missile (502) | prereq `missile_silo 2` + `shipyard 1`; 8000/2000/0 | contramisiles; única contramedida del IPM | **NO EXISTE** |
| Interplanetary Missile (503) | prereq `shipyard 1` + `missile_silo 4` + `impulse_drive 1`; 12500/2500/10000 | 12500/2500/10000; almacenaje 2 IPM/nivel de silo; rango = `impulse_drive × 5` sistemas; sólo misma galaxia; cada IPM daña UNA defensa al azar, ignora escudos | **NO EXISTE** |
| Missile Silo | requerido por ABM e IPM; **su definición propia NO fue verificable** (porción central de `StationObjects.php` truncada en la descarga) | capacidad 2 IPM/nivel | **NO EXISTE** |

Contexto relevante: LGI **sí tiene `bomber`**, que es la plataforma lanzadora clásica del IPM.

**Clasificación: MISSING — REAL GAP, bloqueado por decisión de producto** (así lo clasifica ya el
mapa OGameX). Depende de decidir si LGI quiere una mecánica de interceptación destructiva con
targeting a ciegas: eso redefine el combate, que está CLOSED.

## 7. OTROS SISTEMAS — respuesta a D

| Mecánica | LGI | OGameX / clásico | Estado |
|---|---|---|---|
| Research (16) | 16 | 16 idénticos (incluye IRN y Graviton; esta variante **no** tiene Artillery/Missile/Propulsion) | **MATCH, no gap** |
| Naves (17) | 17 | 16 clásicas + crawler/pathfinder/reaper | **completo, no gap** |
| Defensas (8) | 8 | 8相同 | completo |
| Minerales / energía / settlement | implementados y certificados | — | **CLOSED** |
| Fleet (7 misiones) / Espionage / Expeditions / Luna / Combat / ACS / Messages | implementados y certificados | — | **CLOSED** |
| Research Lab + IRN | implementados | — | **CLOSED** |

**Instalaciones ausentes** (las 5 "Facilities" clásicas que LGI no define):

```text
robot_factory     → gatea shipyard 2 y muchos edificios en OGameX

## 8. MATRIZ AUTORITATIVA

| Mecánica | LGI | Evidencia LGI | OGameX/equivalente | Estado | Gap real | Decisión necesaria |
|---|---|---|---|---|---|---|
| Crawler base | cap/bonus/energía | `calculate_planet_production`, fixture 10/10 | `CivilShipObjects.php` 217 + clásico | IMPLEMENTED / LIVE VERIFIED | NO | — |
| Crawler overload | no | — | sólo foro PTS | BLOCKED BY PRODUCT DECISION | NO (es divergencia) | ¿exceso consume energía? |
| Crawlers excedentes | **no consumen energía** | `v_energy_consumption + v_crawler_effective*50` | "still consume energy" | **PARTIAL — REAL GAP** | SÍ (divergencia) | SÍ (toca economía) |
| Lifeforms | datos sembrados, fuera de scope | `lifeform_*` | Lifeforms | EXCLUDED BY PRODUCT DECISION | NO | — |
| Alloys | 0 | 0 columnas/funciones | ausente en el clásico | NO CORRESPONDE AL SCOPE | NO | — |
| Missile Silo | 0 | `building_definitions` | requerido por ABM/IPM | **MISSING — REAL GAP** | SÍ | SÍ (alcance) |
| ABM (502) | 0 | `defense_definitions` | verificado | **MISSING — REAL GAP** | SÍ | SÍ |
| IPM (503) | 0 | `defense_definitions` | verificado | **MISSING — REAL GAP** | SÍ | SÍ |
| robot_factory | 0 | `building_definitions` | `StationObjects` 14 | MISSING | SÍ | no (técnico) |
| nanite_factory | 0 | `building_definitions` | clásico | MISSING | SÍ | SÍ (economía) |
| terraformer / alliance_depot | 0 | `building_definitions` | clásico | BLOCKED | NO | SÍ (requiere alianzas) |
| Alianzas | 0 | — | clásico | EXCLUDED | NO | SÍ |
| Research tree | 16/16 | `research_definitions` | clásico 16 | MATCH | NO | — |
| Browser certification | — | — | — | EXTERNAL ENVIRONMENT BLOCKER | NO | credenciales |

## 9. PRODUCT DECISIONS REQUIRED

1. ¿Las crawlers por encima del tope deben consumir energía? (el clásico dice sí; LGI dice no)
2. ¿Se implementa el bloque de misiles (silo + ABM + IPM)? Rediseña el combate.
3. ¿Entra `nanite_factory` (reducción de tiempo de obra)? Toca la economía certificada.
4. ¿Alianzas? Sin ellas, `terraformer` y `alliance_depot` no tienen sentido.
5. **Descartar "Alloys" de la lista de candidatos**: no es mecánica de OGame.

## 10. DOCUMENTATION DRIFT (documentado, NO modificado)

| Fichero / sección | Afirmación | Evidencia contradictoria |
|---|---|---|
| `README_OGAMEX_LGI_MAP.md:147` | "`building_prerequisites` … está **vacía** (0 filas)", clasificado `TECHNICAL GAP` | **FALSO**: 3 filas — `sensor_phalanx→lunar_base 1`, `jump_gate→lunar_base 1`, `fusion_plant→deuterium_synthesizer 5`. El mecanismo está IMPLEMENTADO. |
| `README_OGAMEX_LGI_MAP.md` (varias) | ruta OGameX `application/Settings/BuildingObjects.php` | **Ruta obsoleta**: 404. La real es `app/GameObjects/BuildingObjects.php` en `main`. |
| `PROJECT_CONTEXT_PROMPT.md` (~línea 2688) | lista "alloys" como decisión de producto | Alloys no es mecánica de OGame (§5). |
| Informe de la vuelta anterior | "no existe implementación OGameX para el crawler" | **Matizada**: el fichero existe (`app/GameObjects/CivilShipObjects.php`); lo que no está es la fórmula de producción del crawler, que OGameX no define en el objeto. |

## 11. LO QUE ESTÁ CLOSED Y NO SE TOCÓ

Research Lab · IRN · Fleet (7 misiones) · Combat · ACS · Espionage · Expeditions · Luna · Mensajes ·
UI Designer · Identity/Auth · Ownership/ACL · P3 ACL · Economía certificada · Fusion Plant ·
Crawler base · Bootstrap de jugador · Ranking. Ninguno se modificó.

## 12. VERIFICACIÓN

```text
LIVE read-only       catálogos completos (14/17/8/16), prerrequisitos (3/2/16/45/18),
                     0 silo/misiles/alloys, economy tick vivo
git diff --check     0
MIGRATIONS           0
CAMBIOS FUNCIONALES  0
```

nanite_factory    → reduce tiempo de construcción
terraformer       → renombra planetas; requiere ALIANZAS
alliance_depot    → requiere ALIANZAS
missile_silo      → requiere el bloque de misiles (§6)
```

**Alianzas: ausentes por completo** → bloquea `alliance_depot`, `terraformer`, reparar defensas de
aliados y todo lo social. Fuera del scope declarado de LGI.

