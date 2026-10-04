# SOLAR SATELLITE END-TO-END — AUDIT 2026-09-30 (LA GRAN IMPLOSIÓN)

Misión de **auditoría OGameX → clásico → LGI → LIVE + una corrección de definición**.
`MIGRATIONS = 1` (un valor de datos) · `TESTS = 1 nuevo` · `RPC = 0` · `UI = 0 cambios`.
No se tocó temperatura (ya IMPLEMENTED/LIVE VERIFIED), ni Fusion Plant, ni Crawler, ni Fleet/Combat/ACS/AI.

## 1. SYNC GATE

```text
branch main · HEAD 3669e27 · origin/main 75bbc48 · merge-base 3669e27 (= HEAD) → SIN DIVERGENCIA
ahead/behind 0/1 · staged 0 · deleted 0 · stashes 5 (intactos)
```
Sin pull / push / commit / merge / rebase / reset / clean / checkout / restore / stash-pop /
`db push` / `migration repair`.

> **RESIDUOS ANTERIORES DETECTADOS Y ELIMINADOS.** El barrido de la sesión anterior había dejado
> **458 ficheros basura** (`UsersMISSIN~1AppDataLocalTempogx*.php`) en la raíz del repo: un `curl` con
> rutas de Windows interpretó el destino como ruta relativa. Se verificaron uno a uno (contenido = fuentes
> PHP de OGameX, ningún fichero del proyecto) y se eliminaron. Estado actual: **15 ficheros en la raíz
> (todos reales) y 57 rutas en `git status`, 0 residuo.**

## 2. FUENTES OGAMEX EXACTAS

| Dato | Fuente | Valor verbatim |
|---|---|---|
| id / nombre | `app/GameObjects/CivilShipObjects.php` | `212`, `solar_satellite` |
| precio | ídem | `new GameObjectPrice(0, 2000, 500, 0)` → metal 0, cristal 2000, deuterio 500, energía 0 |
| prerrequisitos | ídem | `new GameObjectRequirement('shipyard', 1)` — y **nada más** |
| tipos de cuerpo | ídem | **no asigna `valid_planet_types`** ⇒ vacío = ambos tipos (la regla que LGI ya aplica) |
| perfil | ídem | `new GameObjectProperties($obj, 2000, 1, 0, 0, 0, 1)`, firma `(parent, SI, shield, attack, speed, capacity, fuel)` ⇒ **SI 2000, escudo 1, ATAQUE 0, velocidad 0, carga 0, combustible 1** |
| producción | ídem | `energy_formula = floor((getPlanetTempMax() + 140) / 6) * level` |
| tiempo | `PlanetService::getUnitConstructionTime` | fórmula compartida de nave `base / shipyard / (building_speed · √evolución · (1+R))`; **OGameX no tiene tiempo propio por nave** |
| "no cuenta como nave" | `PlanetService::getFlightShipAmount()` | excluye el satélite *"Do not count solar satellite as ship"* — **pero la función NO tiene ningún llamante en todo el upstream**: intención sin consumidor ⇒ nada que implementar |
| capa | `GameObjectProduction::calculate()` | el satélite se suma a `energy_production_total` en `updateResourceProductionStatsInner()`, igual que la planta solar y la fusión |

## 3. FUENTES CLÁSICAS

* Satélite solar: SI 2000 · escudo 1 · **ataque 0** · velocidad 0 · carga 0. **Coincide con OGameX.**
* Fórmula de energía: la variante documentada `floor((T_media + 160) / 6)`; con el rango de 40° que impone
  la banda de LGI (`T_media = T_max − 20`) es **idéntica** a la de OGameX. Sin conflicto de variantes.
* Sin límite de cantidad, sin materia oscura, sin prerrequisito de investigación.

## 4. ESTADO ANTERIOR DE LGI

El satélite **ya existía** en `ship_definitions` y en el pipeline de naves; su energía ya estaba
implementada el 2026-09-30. Lo que faltaba era **certificar el ciclo de vida**.

| Campo | OGameX | LGI (antes) | Veredicto |
|---|---|---|---|
| metal / cristal / deuterio | 0 / 2000 / 500 | 0 / 2000 / 500 | MATCH |
| prerrequisitos | shipyard 1 | shipyard 1 (única fila) | MATCH |
| tipos | ambos | `{PLANET, MOON}` | MATCH |
| SI → hull | 2000 | 200 | MATCH (convención del proyecto: hull = SI/10) |
| escudo | 1 | 1 | MATCH |
| **ataque** | **0** | **1** | **DIVERGENCIA CORREGIDA** |
| velocidad | 0 | 0 | MATCH |
| carga | 0 | 0 | MATCH |
| **combustible** | **1** | **0** | DIVERGENCIA INERTE, no tocada (§9) |
| tiempo base | compartido | 20 s | diferencia propia de toda la tabla de naves |
| producción | `floor((T_max+140)/6)` | implementada | MATCH |

## 5. DIFERENCIAS OGameX / LGI

`attack 1 → 0` era la única divergencia con efecto observable. El perfil de LGI (ataque 1, escudo 1,
velocidad 0, carga 0, combustible 0) era **idéntico byte a byte al del crawler** salvo el hull: la firma
de un copiar-y-pegar en el seed original del catálogo, no una decisión.

**Por qué importa (medido, no supuesto):** `get_combat_unit_snapshot()` e
`initialize_combat_unit_state()` leen `sd.attack` para **toda** fila de `planet_ships` con cantidad > 0,
**sin filtro por `ship_type`**. Un planeta con N satélites aportaba hoy N de ataque a su línea de defensa.
Upstream aporta 0: un satélite es un *esponja de daño* (escudo 1, casco 200), nunca un arma.

## 6. NATURALEZA DEL SATÉLITE

**A — una nave ordinaria**, construida en el **hangar** (`shipyard_queue` + `start_ship`). No se convirtió
en edificio ni instalación aunque produzca energía: OGameX lo modela en `CivilShipObjects`, LGI lo mantiene
en `ship_definitions` con la cola de naves, y esa es la arquitectura existente que se reutiliza. **No se
creó ningún sistema paralelo.**

## 7. LO QUE LA FIXTURE CERTIFICA (LIVE, `ROLLBACK`, residuo 0)

`supabase/tests/solar_satellite.sql` — **25 PASS + 3 INFO, 0 FAIL**:

1. definición · 2. coste lineal · 3. gate de shipyard · 4. **0→1: cobra 2000/500/0 metal, cola BUILDING,
energía fantasma 0** · 5. **completado: 1 satélite, energía +31 = floor((50+140)/6)** · 6. **el worker es
idempotente** · 7. **1→10: cobra 20000/5000, 11 satélites, energía +341 = 11×31** · 8a/8b/8c. cantidad 0,
negativa y absurda rechazadas · 9a/9b/9c/9d. planeta ajeno, UUID inventado, `player_id` falsificado y
ausencia de sesión → cuatro rechazos distintos y **ninguna fila creada** · 10. **temperatura: caliente
+630, frío +50 (exactos, caliente > frío)** · 11. **Energy Technology mueve el total (3031→4377) pero el
término del satélite no cambia** · 12. **Plasma 20 no toca la energía** · 13. **la fusión suma su propio
término (+191) y 40 crawlers dejan `energy_per_hour` intacto** · 14. **la tasa de producción del universo
no escala la energía** · 15. **se construye y produce en una LUNA** (2721 = planta 2690 + satélite 31) ·
16. **no puede volar**: `Ship speed must be greater than zero: 0` · 17. sin tope de cantidad ·
18. `ui_ship_definitions()` ya lo lista (sin contrato nuevo) · 19. **perfil de combate = OGameX**.

## 8. CAMBIO APLICADO

`supabase/migrations/20260930200000_solar_satellite_combat_profile.sql` — un único valor:
`ship_definitions.attack` de `solar_satellite` **1 → 0**. Guardado: el `UPDATE` es no-op salvo que la fila
siga llevando el valor auditado, y la migración aborta si el resto del perfil derivó.

> **DRIFT DE LEDGER (NO reparado — `migration repair` está prohibido en esta misión).** El fichero es
> `20260930200000` y LIVE lo aplicó como **`20260930051714`**. Es el mismo patrón ya presente en esta tanda
> (`robot_factory` 20260930090000 → 20260930025831, `planet_temperature_system` 20260930160000 →
> 20260930041846). Un `supabase db push` futuro intentará reaplicar los ficheros locales. El estado final
> de LIVE es correcto y está verificado; la reconciliación del ledger es una decisión humana.

```text
LIVE: attack 0 · shield 1 · hull 200 · speed 0 · cargo 0 · 0/2000/500 · {PLANET,MOON}
      crawler attack 1 (intacto, coincide con OGameX) · light_fighter 50 · espionage_probe 0
```

## 9. LO QUE SE DOCUMENTÓ Y NO SE TOCÓ

* **`fuel_consumption` 0 (LGI) vs 1 (OGameX).** Con `speed = 0`, `calculate_fleet_travel_time` lanza
  `Ship speed must be greater than zero` **antes** de calcular combustible (certificado por la prueba 16),
  así que el valor de upstream no tiene ningún camino alcanzable. El valor clásico no se pudo establecer
  desde una fuente primaria aquí, así que cambiarlo sería inventar. **Queda como divergencia declarada.**
* **Hallazgo adyacente (no es del satélite):** `calculate_planet_energy_balance` suma **solo**
  `building_energy_definitions`, de modo que el consumo de crawlers que `calculate_planet_production` añade
  internamente (unidades efectivas × 50) **no** aparece en el consumo reportado. Es preexistente, está
  certificado así por `fusion_and_crawler`, **no afecta a los satélites** y **no se ha tocado**. Queda
  como decisión de producto.
* `getFlightShipAmount()` de OGameX excluye el satélite de "naves que vuelan", pero **no tiene llamantes
  en upstream**: no hay regla que implementar.

## 10. REGRESIÓN

```text
fusion_and_crawler            10 PASS / 0 FAIL   (re-ejecutado tras el cambio)
solar_satellite (nuevo)       25 PASS / 0 FAIL + 3 INFO
catálogo                      17 naves íntegro; crawler / light_fighter / probe sin cambios
economía                      fusion +220 energía, combustible exacto, ratios de crawler intactos
npx tsc -b                    exit 0
npx eslint src                exit 0 (0 errores, 5 warnings preexistentes)
npm run cert:contracts        exit 0 PASS
git diff --check              0
```

## 11. RESIDUO

```text
planetas de prueba 0 · jugadores de prueba 0 · satélites 0 · filas de cola nuevas 0
planetas totales 692 (sin cambios) · la única fila de shipyard_queue es histórica (2026-09-19, COMPLETED)
```

## 12. PENDIENTES QUE NO SON GAP

1. `fuel_consumption` del satélite: 0 vs 1 de upstream, sin efecto alcanzable. Si algún día se decide
   Alignarlo por fidelidad, es un valor.
2. `calculate_planet_energy_balance` no refleja el consumo de crawlers. Afecta a la lectura de
   "ENERGÍA PROD/CONS" de la UI, no a la producción real. Toca un contrato certificado.
3. Tiempos base de la tabla de naves (20 s para el satélite) frente a la fórmula clásica por
   (metal + cristal). Es una decisión de balance de toda la tabla, no del satélite.

## 13. ESTADO FINAL

### `IMPLEMENTED / LIVE VERIFIED / BROWSER BLOCKED`
