# PLANET TEMPERATURE SYSTEM — 2026-09-30 (LA GRAN IMPLOSIÓN)

Misión de **auditoría OGameX → LGI → LIVE + implementación controlada**.
`MIGRATIONS = 2` · `TESTS = 1 nuevo` · `CAMBIOS DE UI = 1 fila`.
Cierra el único defecto real del sweep del mismo día (`GAMEPLAY_GAP_SWEEP_2026-09-30.md` §3).

## 1. SYNC GATE

```text
branch          main
HEAD            3669e27e4e9d9f44c68f12244e7a4e4154127b0f
origin/main     75bbc48e2b55dc8439ab17e52e254218b96ef8aa
merge-base      3669e27 (= HEAD)  →  SIN DIVERGENCIA
ahead/behind    0 / 1   ·  staged 0 · deleted 0 · stashes 5 (intactos)
commit remoto   75bbc48 → sólo docs/MARCIANITOS_GALAGA_CONTEXT.md (nuevo, sin colisión)
```
Sin pull / push / commit / merge / rebase / reset / clean / checkout / restore / stash-pop /
`db push` / `migration repair`. El trabajo previo (Robot Factory, auditorías) queda intacto.

## 2. AUDITORÍA OGameX — DEPENDENCIAS DE TEMPERATURA (CERRADA)

Barrido exhaustivo de `app/**` (299 ficheros PHP descargados y grepeados). En **todo** el código upstream
la temperatura aparece en exactamente estos sitios:

| # | Sitio | Qué hace | Clasificación |
|---|---|---|---|
| 1 | `GameObjects/BuildingObjects.php:86` | `deuterium_formula = 10·L·1.1^L·(1.44 − 0.004·getPlanetTempAvg())` | **MECÁNICA** |
| 2 | `GameObjects/CivilShipObjects.php:171` | `floor((getPlanetTempMax() + 140)/6)·level` (satélite) | **MECÁNICA** |
| 3 | `Services/PlanetService.php` 2587-2620 | `getPlanetTempAvg/Min/Max` (leen `planets.temp_min/max`) | getter |
| 4 | `Factories/PlanetServiceFactory.php` `planetData()` | banda de temperatura por posición 1..15 | **MODELO** |
| 5 | `Factories/PlanetServiceFactory.php` `setupPlanetProperties()` + PR #514 | `temp_max = rand(lo,hi)`; `temp_min = temp_max − 40` | asignación |
| 6 | `Factories/PlanetServiceFactory.php` `setupMoonProperties()` y `Jobs/CreateLegorMoon.php` | luna = punto medio de la banda de su posición | asignación |
| 7 | `Http/Controllers/OverviewController.php:112-113` | `planet_temp_min/max` en la UI | presentación |

**No hay término de temperatura** en research, fleet, combate, campos, lifeforms, oficiales, clase de
personaje ni bonificaciones. Barrido cerrado.

## 3. RELACIÓN POSICIÓN ↔ TEMPERATURA (OGameX)

```text
OGAMEX DIRECT
  persistida      sí (planets.temp_min / temp_max), una vez al crear el cuerpo
  derivada        NO de la posición: se tira un número dentro de la banda
  aleatoriedad    sí — rand(lo, hi) para temp_max
  cambio posible  NO (no hay setter; se fija al crear el cuerpo)
  dependencia de universo/config  NO
  rango           SIEMPRE 40°  (PR #514, mergeado: temp_min = temp_max − 40)
  posición        NO (la posición sólo elige la BANDA dentro de la que se tira)

OGAME CLASSIC
  banda           distinta (otras cifras absolutas) — no se mezcla: LGI sigue la banda de OGameX
  variante satélite  documentada como floor((T_avg + 160)/6); con el rango de 40° es IDÉNTICA a la de
                    OGameX porque T_avg = T_max − 20 ⇒ (T_avg+160) = (T_max+140) ⇒ no hay conflicto
```

**Decisión de compatibilidad:** LGI adopta la banda de **OGameX** (es su referencia declarada) y hace la
tirada **determinista** (punto medio). Registrado como INTENTIONAL LGI DIFFERENCE 1.

## 4. POSICIÓN → TEMPERATURA (tabla implementada y verificada LIVE)

| pos | banda OGameX | temp_max | temp_min | T_avg | factor deut | energía/satélite |
|---|---|---|---|---|---|---|
| 1 | [220,260] | 240 | 200 | 220 | 0.56 | 63 |
| 2 | [170,210] | 190 | 150 | 170 | 0.76 | 55 |
| 3 | [120,160] | 140 | 100 | 120 | 0.96 | 46 |
| 4 | [70,110] | 90 | 50 | 70 | 1.16 | 38 |
| 5 | [60,100] | 80 | 40 | 60 | 1.20 | 36 |
| 6 | [50,90] | 70 | 30 | 50 | 1.24 | 35 |
| 7 | [40,80] | 60 | 20 | 40 | 1.28 | 33 |
| 8 | [30,70] | 50 | 10 | 30 | 1.32 | 31 |
| 9 | [20,60] | 40 | 0 | 20 | 1.36 | 30 |
| 10 | [10,50] | 30 | −10 | 10 | 1.40 | 28 |
| 11 | [0,40] | 20 | −20 | 0 | 1.44 | 26 |
| 12 | [−10,30] | 10 | −30 | −10 | 1.48 | 25 |
| 13 | [−50,−10] | −30 | −70 | −50 | 1.64 | 18 |
| 14 | [−90,−50] | −70 | −110 | −90 | 1.80 | 11 |
| 15 | [−130,−90] | −110 | −150 | −130 | 1.96 | 5 |
| fuera | [0,40] | 20 | −20 | 0 | 1.44 | 26 |

El salto 12→13 (10 → −30) es una irregularidad **de la propia tabla de OGameX**: se reproduce verbatim.

## 5. FÓRMULAS

```text
DEUTERIO   deuterium_base × (1.44 − 0.004 × T_avg)          [OGameX BuildingObjects.php:86]
           + floor(deuterium_base × 0.0002 × crawlers)        [el término crawler NO lleva el factor:
                                                                en OGameX calculateCrawlerProduction()
                                                                corre DESPUÉS de calculateMine()]

SATÉLITE   energy += floor((T_max + 140) / 6) × cantidad     [OGameX CivilShipObjects.php:171]
           sumado a la misma energía que la planta solar y la de fusión
```

## 6. ARQUITECTURA — UNA FUENTE DE VERDAD

```text
planets.position
      ↓
planet_temperature_for_position(position)     ← la banda, el ÚNICO sitio donde existe
      ↓
planets.temperature_min / temperature_max     ← la instancia persistida
      ↓
planet_temperature(planet)                    ← persistido; si es NULL → el modelo (nunca 0 mágico)
      ↓
calculate_planet_production                   ← el ÚNICO consumidor
```
Los cuatro escritores de planetas (`provision_player`, `resolve_colonize_arrival`,
`reconcile_universe_ai_population`, `settle_moon_creation_for_battle`) escriben llamando al mismo helper.
Cero fórmulas en frontend, fixtures o triggers.

## 7. OGameX / LGI DIFFERENCE REGISTER (§16)

| Mecánica | OGameX | OGame classic | LGI | Decisión |
|---|---|---|---|---|
| Temperatura por posición | banda 1..15 | banda distinta | banda OGameX | **MATCH** |
| Rango de temperatura | 40° (PR #514) | 40° | 40° | **MATCH** |
| Selección dentro de la banda | `rand(lo,hi)` | fija | punto medio | **INTENTIONAL LGI DIFFERENCE 1** |
| Persistencia | sí, 1 vez | sí | sí, 1 vez | **MATCH** |
| Cambio de temperatura | no | no | no | **MATCH** |
| Dependencia de universo | no | no | no | **MATCH** |
| Deuterio × temperatura | `1.44 − 0.004·T_avg` | idem | idem | **MATCH** |
| Término crawler con factor | NO | NO | NO | **MATCH** |
| Satélite solar | `floor((T_max+140)/6)` | `floor((T_avg+160)/6)` (idéntica) | `floor((T_max+140)/6)` | **MATCH** |
| Temperatura de la luna | banda de su posición | idem | banda de su posición | **MATCH** |
| Average temperature | `(min+max)/2` redondeado | idem | `(min+max)/2` exacto (min = max−40) | **MATCH** |
| Posición fuera de 1..15 | banda [0,40] | — | banda [0,40] | **MATCH** |
| Nombres de columna | `temp_min/temp_max` | — | `temperature_min/max` (preexistente) | ADAPTATION |
| Suelo 0 en los términos | no | no | sí | **INTENTIONAL LGI DIFFERENCE 2** |
| `planet_temperature` total | — | — | siempre 1 fila | ENDURECIMIENTO LGI |
| Backfill | n/a | n/a | 692 filas | **MIGRATION** |
| Cambio de posición | no existe | no existe | no existe | sin acción |

## 8. MIGRACIONES

| Fichero del repositorio | Versión realmente aplicada en LIVE | Contenido |
|---|---|---|
| `20260930160000_planet_temperature_system.sql` | **`20260930041846`** | modelo + helper del planeta + `calculate_planet_production` + los 4 escritores + backfill + post-condiciones que abortan |
| `20260930161000_planet_temperature_missing_planet_hardening.sql` | **`20260930041918`** | `planet_temperature` pasa a ser **total** (antes devolvía 0 filas para un planeta inexistente → un `SELECT INTO` recibía NULL) |

> **DRIFT DE LEDGER DETECTADO (NO reparado — `migration repair` está fuera de la misión).**
> El ledger de LIVE asigna su propia marca temporal, que no coincide con el nombre del fichero. Esto es
> exactamente lo que ya ocurre con la migración anterior de esta misma tanda
> (`20260930090000_robot_factory.sql` aplicada como `20260930025831`), así que el patrón ya existe en el
> proyecto. **Consecuencia a tener en cuenta:** un `supabase db push` futuro intentará volver a aplicar
> los ficheros locales, porque sus versiones no están en el ledger. La reconciliación del ledger es una
> decisión humana y fuera del alcance de esta misión. Lo que sí queda garantizado es que el **estado final
> de LIVE es el correcto y está verificado** por las fixtures.

RPC nuevos: `planet_temperature_for_position(integer)`, `planet_temperature(uuid)` — ambos de sólo
lectura, `SECURITY INVOKER`, `search_path` fijado, `EXECUTE` sólo para `service_role`.

## 9. BACKFILL

```text
ANTES     692 planetas · 692 con temperature_min NULL · 692 con temperature_max NULL
          lunas 0 · destruidos 0 · posiciones fuera de 1..15: 0
DESPUÉS   692 planetas · 0 NULL · 0 desacuerdos con el modelo · 0 rangos ≠ 40°
          condición: sólo filas con alguna temperatura NULL, y nunca pisa una temperatura existente
          la migración aborta si queda algún NULL o algún desacuerdo
```

## 10. TESTS (LIVE, transaccionales, ROLLBACK)

`supabase/tests/planet_temperature.sql` — **13 PASS + 1 INFO, residuo 0**:
modelo por posición (1/5/8/10/15) · irregularidad 12→13 · banda fuera de rango · backfill · totalidad
(UUID aleatorio y UUID NULL) · **deuterio frío 77 733 > medio 52 351 > caliente 22 209** · **ratio exacto de
deuterio 0.424242 / 1.484848 = ratio de factores OGameX** · **satélite 10 uds: caliente +630, medio +310,
frío +50 (exacto)** · sólo el deuterio varía con la temperatura · integridad (posición, recursos, 4
edificios, 0 flotas) · ACL (sin EXECUTE para anon/authenticated) · fail-closed (planeta ajeno con sesión
y planeta propio sin sesión → 0 filas).

**Regresión económica obligatoria:**

| Fixture | Resultado |
|---|---|
| `fusion_and_crawler.sql` | **10 PASS + 1 INFO** (sin cambios) |
| `energy_technology_production.sql` | **7 PASS** (sin cambios) |
| `plasma_technology_production.sql` | **12 PASS** — su TEST 13 (deuterio a plasma 0) se actualizó: la línea base ahora incluye el factor de temperatura. Todo lo demás es relativo y no se tocó. |

Certificado además de extremo a extremo: `provision_player` para un jugador nuevo real en la posición 7
devuelve `20/60`, que coincide con el modelo y respeta el rango de 40°.

## 11. SEGURIDAD

* Los dos helpers son de sólo lectura, `SECURITY INVOKER`, `search_path` fijo, `EXECUTE` sólo
  `service_role` (la misma postura que `calculate_planet_production`). Sin `anon`, sin `authenticated`.
* No se abrió ninguna superficie de escritura: la temperatura se escribe exclusivamente desde funciones
  `SECURITY DEFINER` que ya escribían la fila del planeta.
* Ningún RPC acepta temperatura como entrada; ningún `player_id` viene del cliente en este camino.
* Verificado en fixture: planeta ajeno con sesión → 0 filas; planeta propio sin sesión → 0 filas.

## 12. FRONTEND

Una fila `TEMPERATURA` en el panel de overview, alimentada por la fila `planets` que el jugador ya tenía
(RLS del propietario). **Sin contrato nuevo, sin pantalla nueva, sin regla derivada en el cliente**: se
muestran los dos valores de servidor. `App.tsx`: el `Pick` del tipo `Planet` y las tres consultas
`from('planets')` incorporan `temperature_min,temperature_max`.

## 13. REGRESIÓN ESTÁTICA

```text
npx tsc -b              exit 0
npm run build           exit 0  (worker + cliente emitidos)
npx eslint src          exit 0  (0 errores; 5 warnings preexistentes de exhaustive-deps)
git diff --check        0
npm run cert:contracts  exit 0  PASS
```

## 14. PRODUCT DECISIONS QUE QUEDAN

1. **Sorteo aleatorio dentro de la banda**: LGI usa el punto medio. Volver a `rand(lo,hi)` es una decisión
   de producto, no técnica (haría la temperatura irreproducible).
2. **Banda clásica alternativa**: si algún día se quiere la banda del OGame clásico en vez de la de OGameX,
   es un cambio de una tabla, no del sistema.

## 15. CIERRE

`TEMPERATURE SYSTEM — IMPLEMENTED / LIVE VERIFIED`.
Dependencias descubiertas: clasificadas todas (sólo dos mecánicas consumían temperatura). Fixtures PASS.
Regresión PASS. Seguridad PASS. Documentación actualizada. Sin commit ni push.



