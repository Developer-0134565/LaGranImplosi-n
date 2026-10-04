# BUILDING / RESEARCH STUCK-STATE ON A PAST EVENT — 2026-10-01

Misión de **hardening**. `MIGRATIONS = 1` (aplicada) · `TESTS = 1 nuevo` · `RPC = 0` · `UI = 0 cambios`
· `RESIDUO = 0`. Sin commit ni push. Cierra el último gap técnico del heartbeat.

## 1. SYNC GATE

```text
branch          main
HEAD            3669e27e4e9d9f44c68f12244e7a4e4154127b0f
origin/main     75bbc48e2b55dc8439ab17e52e254218b96ef8aa
merge-base      3669e27 (= HEAD)  → SIN DIVERGENCIA
ahead/behind    0 / 1  (commit remoto = sólo docs/MARCIANITOS_GALAGA_CONTEXT.md, fichero nuevo)
staged 0 · modified 20 · deleted 0 · untracked 71 · stashes 5 (intactos)
git diff --check  0 (sólo avisos LF→CRLF preexistentes)
```

Sin pull / push / commit / merge / rebase / reset / clean / checkout / stash-pop / `db push`.

## 2. DECISION GATE — **A: completar la cola vencida** (determinado, no inventado)

La semántica se dedujo del código existente, no se eligió:

| Evidencia | Dónde |
|---|---|
| El tick selecciona por `finishes_at <= now()`: **todo lo vencido se completa** | `process_planet_tick` |
| `complete_building` / `complete_research` **no tienen** rama `CANCELLED` **ni** `DELETE` | `prosrc` verificado |
| Sólo `cancel_building` / `cancel_research` ponen `CANCELLED`, y son **acciones del jugador** con reembolso | únicas funciones con `CANCELLED` |
| Ambas son **idempotentes** sobre `COMPLETED` (devuelven nivel / `false`) | ya certificado |

⇒ **No existe ninguna vía de abandono automático.** Descartar una cola pagada sería inventar una
regla nueva y destruir recursos del jugador. Se **completa**.

## 3. ROOT CAUSE

Ambos completers liquidan la economía **en el timestamp del evento** vía
`update_planet_resources_until_raw`, que rechaza correctamente mover un reloj **hacia atrás**
(`INVALID_RESOURCE_TIMESTAMP`). Esa guarda **no se toca**.

```text
complete_building  -> update_planet_resources_until_raw(planet, queue.finishes_at)
complete_research  -> update_planet_resources_until_raw(CADA planeta del jugador, research.finishes_at)
```

Medido: una investigación vencida cuyo reloj ya estaba pasado →
`process_universe_tick` lanzaba `P0001 : INVALID_RESOURCE_TIMESTAMP`, la fila se quedaba
**`RESEARCHING` para siempre** (3 reintentos idénticos) y, al no haber aislamiento de error por
planeta, **ningún planeta del universo liquidaba** en ese heartbeat.

**Cómo se adelanta el reloj:** los anchors de flota/combate usan la variante `_raw` y **no recorren
eventos** (`resolve_attack_arrival → apply_attack_loot`, `resolve_expedition_return`, …), así que un
planeta puede quedar liquidado más allá de un evento de cola pendiente. A partir de ahí el evento es
invisible para el walker (`finishes_at > last_calculated_at` ya no se cumple) pero sigue visible para
el predicado del tick (`finishes_at <= now()`): ésa es la ventana exacta del atasco.

## 4. EL ARREGLO

Mismo clamp ya aceptado en los stuck-states de flota, uno por liquidación:

```text
effective = greatest(<timestamp de la cola>, <last_calculated_at de ESE planeta>)
```

* Evento en el **futuro** (vía certificada normal) → no-op; verificado: el reloj queda
  **exactamente** en `finishes_at`, byte-idéntico.
* Evento **detrás** → no queda tiempo que acreditar ⇒ **cero producción extra** y la cola completa.

## 5. VERIFICACIÓN — 21/21 PASS

```text
CASO 1  building atrasado        1a/1b/1c  PASS  (tick OK · COMPLETED · nivel 1 concedido)
CASO 2  research atrasado        2a/2b/2c  PASS  (tick OK · COMPLETED · nivel 1 concedido)
CASO 3  timestamp normal         3a/3b     PASS  (futura sigue BUILDING · nivel 2 -> 2 sin cambio)
CASO 4  anti-vacuuidad           4a/4b/4c  PASS  (el reloj REALMENTE estaba adelantado)
CASO 5  idempotencia             5a/5b/5c  PASS  (nivel 1, no 2 · fields_used no se re-incrementa)
CASO 6  multi-planeta            6a..6e    PASS  (homeworld atrasado + colonia válida · nivel 1)
CASO 7  guarda intacta           7          PASS  (timestamp crudo hacia atrás sigue rechazado)
CASO 8  producción extra         8          PASS  (3 000 000 -> 3 000 000, cero)
```

Regresiones sobre el camino **no** stale (byte-identidad demostrada):

```text
B1 reloj por DETRÁS del evento → B2 liquidado EXACTAMENTE en finishes_at  → PASS (building)
B5 research liquidado EXACTAMENTE en finishes_at                          → PASS
C BUILDING_NOT_FINISHED sigue rechazando una cola futura                  → PASS
D "Research is not finished yet" sigue rechazando una research futura     → PASS
E BUILDING_QUEUE_NOT_ACTIVE sigue rechazando una fila CANCELLED           → PASS
A cancel_building reembolsa exacto (60, stock 1 000 000 -> 1 000 060)    → PASS
complete_building x2 → nivel 1 (no 2), una sola fila                     → PASS
BUILDING_LEVEL_MISMATCH: current=0, target=2 sigue lanzando               → PASS
```

```text
apply_migration  postcondiciones OK (clamp, guarda, firmas, guardas COMPLETED, sin EXECUTE cliente)
npx tsc -b         exit 0
npm run build      exit 0   (el aviso de chunk>500 kB va a stderr; PowerShell lo surface como error)
npx eslint src     exit 0   (0 errores, 5 warnings preexistentes)
cert:contracts     exit 0 PASS
git diff --check   0
RESIDUO            colas BUILDING 0 · RESEARCHING 0 · colonias de fixture 0 · universos fallando 0
```

**Sin `EXECUTE` indebido:** `complete_building` y `complete_research` siguen sin EXECUTE para
`authenticated` ni `anon`; `search_path`, volatilidad y `SECURITY` intactos.

## 6. RIGOR — dos falsos positivos míos, no productos

1. **`3b` falló** al comparar `count = 0` para `crystal_mine`: el planeta **ya tenía** `crystal_mine`
   L2 en LIVE. La aserción correcta es «nivel **sin cambio**». Corregida → `2 -> 2`.
2. **`BUILDING_LEVEL_MISMATCH` «no saltó»**: mi aserción usaba igualdad exacta, pero el mensaje real
   es `BUILDING_LEVEL_MISMATCH: current=0, target=2`. Verificado con el mensaje completo: **la guarda
   está intacta**.

Ninguno se reporta como gap.

## 7. OGameX

`OGameX: no new relevant difference.` El clamp no procede de OGameX: es la consecuencia interna de una
guarda ya existente y correcta. No se introduce balance, costes, tiempos ni semántica nueva.

## 8. ESTADO

**CLOSED.** No queda ningún gap técnico conocido en el heartbeat de colas. Los sistemas cerrados
anteriores (fleet, economy guard, missile, wreck field, messaging, lifecycle) no se han reabierto.

## 9. LIMITACIONES

* Las sondas son **secuenciales y dentro de ROLLBACK**. La concurrencia real (dos workers sobre la
  misma cola) no se ejecuta; el `pg_advisory_xact_lock` por jugador y el `FOR UPDATE` de la fila de
  cola quedan **sin modificar**.
* **Browser: ENVIRONMENT BLOCKED.** El cambio es 100 % backend y no añade superficie de UI, así que
  no hay nada nuevo que certificar en navegador.
**Aislamiento por planeta en `complete_research`:** el clamp se calcula **dentro** del bucle, contra
el planeta que se liquida. Así un planeta ya adelantado se liquida en su propio reloj (no-op) en vez
de lanzar y abortar los planetas restantes **y** la concesión de la investigación. No introduce
semántica nueva: la investigación se completa exactamente una vez.

Se conserva `_raw` a propósito: es lo que evita el procesamiento recursivo mientras un walker ya
recorre ese mismo evento.