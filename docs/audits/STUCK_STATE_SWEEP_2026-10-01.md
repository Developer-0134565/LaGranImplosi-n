# STUCK-STATE SWEEP — 2026-10-01 (EXTRA AUDIT)

Misión de **auditoría con una corrección inequívoca**. `MIGRATIONS = 1` (aplicada) · `TESTS = 1 nuevo`
· `RPC = 0` · `UI = 0 cambios` · `RESIDUO = 0`. Sin commit ni push.

## 1. SYNC GATE

```text
branch          main
HEAD            3669e27e4e9d9f44c68f12244e7a4e4154127b0f
origin/main     75bbc48e2b55dc8439ab17e52e254218b96ef8aa
merge-base      3669e27 (= HEAD)  → SIN DIVERGENCIA
ahead/behind    0 / 1   (el commit remoto 75bbc48 toca SOLO docs/MARCIANITOS_GALAGA_CONTEXT.md,
                          fichero NUEVO → cero colisión con el trabajo local)
staged 0 · modified 20 · untracked 63 · deleted 0 · stashes 5 (intactos)
```

Sin pull / push / commit / merge / rebase / reset / clean / checkout / restore / stash-pop /
`db push` / `migration repair`.

## 2. HALLAZGO PRINCIPAL — GAP REAL CERRADO: 4 ANCHORS DE ASENTAMIENTO SIN CLAMP

**Familia idéntica al gap cerrado el 2026-09-30, en los call sites que aquel fix no enumeró.**

`20260930240000` + `20260930241000` corrigieron la trampa «evento pasado + reloj del cuerpo ya
adelantado» en una lista **fija** de puntos de asentamiento. Quedaron **cuatro** que seguían
pasando el timestamp crudo:

| Anchor sin clamp | Cuerpo liquidado |
|---|---|
| `resolve_attack_arrival` | defensor |
| `resolve_espionage_arrival` | objetivo |
| `resolve_expedition_arrival` | origen |
| `apply_attack_loot` | defensor |

### Medición (LIVE, sondas con ROLLBACK, por el worker real)

Evento 2 h en el pasado + cuerpo ya liquidado a `now()`, llamando a `process_fleet_movements()`:

```text
ANTES                                    DESPUÉS
ATTACK      OUTBOUND (tras 5 pasadas)   → COMPLETED   · 1 batalla creada
ESPIONAGE   OUTBOUND · 0 informes      → COMPLETED   · 1 informe creado
EXPEDITION  OUTBOUND                   → RETURNING   · resultado persistido
TRANSPORT   COMPLETED (control 241000) → COMPLETED   (sin regresión)
```

Causa raíz aislada contra `prosrc`, no inferida:

```text
update_planet_resources_until_raw -> INVALID_RESOURCE_TIMESTAMP
  la guarda rechaza mover el reloj hacia atrás  ← CORRECTA, NO SE TOCA
process_fleet_movements -> exception when others then raise warning 'FLEET_RESOLUTION_FAILED'
  un WARNING no deshace nada ni se superficie → la flota reintenta para siempre
  y las naves, ya debitadas en el despacho, se pierden definitivamente
```

**Alcanzabilidad = orden ORDINARIO de eventos**, no una carrera exótica: el worker corre cada 1 s
mientras `universe-heartbeat` corre cada minuto y liquida todos los planetas a `now()`; cualquier
acción del jugador sobre el cuerpo (`start_building`, `cancel_building`, `load_fleet_cargo`, el
comerciante, la UI `sync_current_planet_resources`) hace lo mismo.
## 3. SEGUNDO HALLAZGO — REAL GAP, **NO CORREGIDO** (queda para la siguiente misión)

**Un edificio en una colonia + una investigación que lo sobrevive matan el heartbeat entero.**

`complete_research` liquida **todos** los planetas del jugador con
`update_planet_resources_until_raw(planeta, finishes_at)`. Si **uno** ya está adelantado, lanza y
**aborta `process_universe_tick` completo**: ningún planeta del universo liquida, y la investigación
y el edificio quedan en `RESEARCHING`/`BUILDING` **para siempre** (medido: 3 reintentos, idéntico).

```text
secuencia NORMAL: colonia con edificio que acaba a T_b; investigación que acaba a T_r > T_b
  process_planet_tick(home) -> el research vence -> complete_research -> liquida la colonia a T_r
  → el edificio a T_b queda DETRÁS del reloj ⇒ invisible para el walker (finishes_at > clock)
  → process_planet_tick(colonia) lo ve por `finishes_at <= now()` -> complete_building -> RAISE
  ⇒ el heartbeat muere y TODOS los planetas del universo dejan de liquidar
```

Medido en LIVE: `P0001 : INVALID_RESOURCE_TIMESTAMP`, `queue_status=BUILDING`,
`building_level=0`, permanente.

**Por qué NO se corrigió aquí.** Es la misma familia, pero el radio de impacto es el **núcleo
económico certificado** (`complete_building` / `complete_research` conceden niveles y producción) y
la semántica correcta —*¿completa una investigación cuyo cuerpo ya pasó su `finishes_at`? ¿se
conceden el nivel y el edificio?*— no es un detalle mecánico sino una decisión temporal con
consecuencias de balance. Queda como **NEXT GAP**, con el arreglo ya identificado (el mismo clamp en
ambos `complete_*`), pero requiere esa decisión explícita.

## 4. AUDIT MATRIX

| AREA | ESTADO | EVIDENCIA | ACCIÓN |
|---|---|---|---|
| Stuck-states: flotas (ATTACK/ESPIONAGE/EXPEDITION/loot) | **REAL GAP → CLOSED** | OUTBOUND tras 5 pasadas vs COMPLETED | 1 migración + fixture 11/11 |
| Stuck-states: flotas (TRANSPORT/DEPLOY/RETURNING) | CLOSED (previo) | 241000/240000 | no tocado |
| Stuck-states: edificio/investigación | **REAL GAP (abierto)** | heartbeat aborta el universo | documentado, no corregido |
| Settlement / carga preservada | CLOSED (previo) | 230000 | no tocado |
| Pre-flight autosostenibilidad | CLOSED (previo) | 20261001 | no reabierto |
| Missile system | CLOSED | 18 migraciones + `missile_system.sql` | interior no re-auditado |
| Wreck Field / Space Dock | CLOSED | ledger `battle_id` PK, 0 filas residuo | no reabierto |
| Economía (producción/energía/costes) | CLOSED | sin regresión en fixture | verificado |
| Messaging (4 productores) | CLOSED | triggers + `get_player_messages` | sin hueco |
| UI: contrato → RPC → refresh | NO GAP | `contract-inventory` PASS, 56 RPC | sin hueco |
| Ownership de los 4 anchors | VERIFIED | sin EXECUTE cliente, `search_path` intacto | postcondiciones |
| DEFEND / Lifeforms | PRODUCT DECISION | ya declaradas | fuera de alcance |

## 5. VERIFICACIÓN

```text
fixture  fleet_stuck_attack_espionage_arrival_regression.sql   11 PASS / 0 FAIL (ROLLBACK)
  · anti-vacuuidad: el reloj realmente estaba adelantado al evento
  · ATTACK/ESPIONAGE/EXPEDITION salen del estado no terminal
  · 1 batalla + 1 informe + 1 resultado de expedición persistidos
  · TRANSPORT (ya cubierto) sin regresión
  · la guarda sigue rechazando un timestamp crudo hacia atrás
  · el clamp acredita CERO recursos extra (2000 -> 2000)
supabase apply_migration  postcondiciones OK (clamp, guarda, firmas, ACL)
npx tsc -b     exit 0
npm run build  exit 0   (el "error" inicial era el aviso de chunk>500 kB por stderr, no un fallo)
npx eslint src exit 0   (0 errores, 5 warnings preexistentes)
npm run cert:contracts  exit 0 PASS
git diff --check  0
RESIDUO  flotas abiertas 0 · colas BUILDING 0 · queues RESEARCHING 0 · wreck ledger 0
```

**BROWSER: ENVIRONMENT BLOCKED.** No se ejecutó navegador; no se marca como certificado. El fix es
100 % backend y no añade superficie de UI.

## 6. FALSOS POSITIVOS DESCARTADOS

1. **12 «dispatchers sin caller»** — artefacto de mi propia consulta, que listaba funciones cliente
   sin cruzarla con `src/`. Los 12 **sí** tienen caller
   (`contract-inventory.mjs --assert-client-dispatchers` → PASS).
2. **`complete_research` recorriendo todos los planetas** — no es código duplicado: es exactamente
   lo que produce el gap del §3. Se reporta como tal.
3. **RLS deshabilitada en 3 tablas** (`moon_creation_rolls`, `moon_destruction_attempts`,
   `building_research_prerequisites`) — aviso del advisor, **preexistente y ajeno a esta misión**
   (tablas de registro/procedencia). No se aplica remediación automática: habilitar RLS sin
   políticas bloquearía el acceso. Queda señalado para decisión.

## 7. OGameX

Sin diferencias nuevas. La regla del clamp **no viene de OGameX**: es la consecuencia interna de la
guarda `INVALID_RESOURCE_TIMESTAMP` que ya existe y es correcta. No se introduce balance.

### El arreglo

El **mismo** clamp ya aceptado en 240000/241000, uno por anchor:
`greatest(<timestamp del evento>, last_calculated_at)`. Splicing textual anclado sobre
`pg_get_functiondef()` (misma técnica que `20261001010000`), con cada anchor verificado como
**ocurrencia única** antes de editar. Postcondiciones en la migración: clamp presente en los 4,
guarda intacta, 4 firmas sin cambios, y ninguna función gana EXECUTE de cliente.

No se toca: costes, tiempos, combustible, ventanas de espera, combate, topes de botín 50 %,
recompensas de expedición, reglas de revelado de espionaje, ni las colas de hangar/defensa (sólo
filtran `finishes_at <= p_until` y no liquidan recursos, luego no pueden lanzar).