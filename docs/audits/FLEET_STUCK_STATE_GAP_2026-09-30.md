# FLEET STUCK-STATE GAP — SHIPS LOST FOREVER ON A PAST EVENT (2026-09-30)

Misión de barrido gameplay. **GAP TÉCNICO REAL — IMPLEMENTADO, TESTED, LIVE VERIFIED.**
`MIGRATIONS = 2` (aplicadas) · `TESTS = 1 nuevo` · `RPC = 0` · `UI = 0 cambios` · `RESIDUO = 0`.
Sin commit ni push. Solo se tocaron las 4 funciones de liquidación de flota del gap; ningún otro
sistema fue modificado.

## 1. SYNC GATE

```text
branch          main
HEAD            3669e27e4e9d9f44c68f12244e7a4e4154127b0f
origin/main     75bbc48e2b55dc8439ab17e52e254218b96ef8aa   (git fetch origin: sin cambios)
merge-base      3669e27 (= HEAD)  → SIN DIVERGENCIA
ahead/behind    0 / 1   (el commit remoto 75bbc48 toca SOLO docs/MARCIANITOS_GALAGA_CONTEXT.md,
                         fichero NUEVO → cero colisión con las 22 modificadas + 61 untracked)
staged 0 · modified 20 · untracked 61 · deleted 0 · stashes 5 (intactos)
```

Sin pull / push / commit / merge / rebase / reset / clean / checkout / restore / stash-pop /
`supabase db push` / `migration repair`.

## 2. EL GAP

**Una flota podía quedarse congelada para siempre y sus naves se perdían definitivamente.**

Cada liquidación de flota ancla el reloj económico a la **marca del evento programado**:

| Llamador | Ancla |
|---|---|
| `process_fleet_movements` (rama RETURNING) | `update_planet_resources_until(origen, returns_at)` |
| `resolve_transport_arrival` | `update_planet_resources_until(destino, arrives_at)` |
| `resolve_deploy_arrival` | `update_planet_resources_until(destino, arrives_at)` |
| `resolve_expedition_return` | `update_planet_resources_until(origen, returns_at)` |

Y `update_planet_resources_until` **rechaza correctamente** mover el reloj de un planeta hacia atrás
(`INVALID_RESOURCE_TIMESTAMP`). Esa guarda es correcta y **no se toca**.

El bug: el manejador por flota del worker degrada cualquier error a un `WARNING`:

```sql
exception when others then
  raise warning 'FLEET_RESOLUTION_FAILED fleet=% mission=% sqlstate=% error=%', ...
```

Un `WARNING` no deshace nada ni se superficie. Así, cuando la marca del evento **ya estaba detrás**
del reloj de producción de ese cuerpo, la liquidación fallaba en **cada** latido, para siempre.

### Por qué es alcanzable en juego real (sin artificios)

Basta el orden ORDINARIO de eventos: cualquier acción del jugador sobre ese cuerpo liquida el
planeta a `now()` — `start_building`, `cancel_building`, `load_fleet_cargo`, el comerciante, o la
propia UI (`sync_current_planet_resources`). Si el evento de la flota ya había pasado, el reloj del
cuerpo queda por delante y la liquidación es imposible.

Reproducción medida en LIVE, sin rebobinar nada:

```text
salida 9 h atrás · llegada 7 h atrás · ventana de espera expiró 6 h atrás · pierna de ida 2 h
  => returns_at = 6 h atrás + 2 h = 4 h ATRÁS
el jugador tocó el planeta de origen mientras tanto
  => origen 0 naves · movimiento varado con 5 cruceros · status RETURNING · PARA SIEMPRE
```

Idéntico en `TRANSPORT`: `arrives_at` 2 h en el pasado contra un destino ya liquidado a `now()`
⇒ status `ARRIVED` para siempre, **carga nunca entregada**.

## 3. EL ARREGLO

Un clamp por punto de liquidación: `greatest(<marca del evento>, last_calculated_at)`.
## 4. VERIFICACIÓN

| Prueba | Antes | Después |
|---|---|---|
| ACS_HOLD overdue, 5 cruceros | `RETURNING` perpetuo, **5 naves perdidas** | `COMPLETED`, **5 naves recuperadas** |
| TRANSPORT overdue | `ARRIVED` perpetuo, carga perdida | `COMPLETED`, **1000 M / 500 C entregados** |
| Evento FUTURO (camino normal) | — | sigue liquidando en la marca exacta, `RETURNING` (idéntico) |
| `INVALID_RESOURCE_TIMESTAMP` | rechaza hacia atrás | **sigue rechazando** (asertación 8) |
| Ciclo completo de transporte | — | `OUTBOUND→RETURNING→COMPLETED`, carga entregada, naves en casa |
| `cancel_building` reembolso | 455,625 | 455,625 (sin regresión) |

`fleet_stuck_return_arrival_regression.sql` (nueva): **13 PASS / 0 FAIL** (ROLLBACK).
`resource_settlement_cargo_preservation.sql` (misión previa): **18/18**, sin regresión.

| Puerta | Resultado |
|---|---|
| `npx tsc -b` | exit 0 |
| `npm run build` | exit 0 |
| `npx eslint src` | exit 0 (0 errores, 5 warnings preexistentes) |
| `npm run cert:contracts` | exit 0 PASS |
| `git diff --check` | 0 |

## 5. SEGURIDAD

* Sin cambios en ownership, auth, RLS ni grants: ninguna función nueva, ningún RPC nuevo, ninguna
  superficie para el cliente. Los 4 puntos de liquidación son funciones internas ya existentes.
* No se tocó `calculate_planet_production`, `settle_resource_stock` (misión previa), costes, tiempos,
  combustible, ventanas de espera, combate ni recompensas de expedición (aserciones 9-12).
* Se preserva el orden canónico del worker: las flotas se drenan **antes** que los planetas
  (asertación 10).

## 6. RESIDUO

```text
planetas de prueba 0 · jugadores de prueba 0 · usuarios auth de prueba 0
flotas abiertas 0 · atascadas a mitad de ciclo 0 · colas de edificio/investigación/hangar/defensa 0
```

Todos los probes corrieron dentro de transacciones con `ROLLBACK`.

## 7. NOTA DE RIGOR

Dos "hallazgos" iniciales resultaron ser **fallos de mi propio harness**, no defectos del juego, y se
corrigieron antes de reportarlos:

1. `min(uuid)` inexistente y un planeta de prueba creado en un sistema ya lleno.
2. Una prueba de RLS que daba "todo visible": `execute_sql` corre como propietario y **evita RLS**.
   Repetida con `set_config('role','authenticated')` → propietario 1 fila, ajeno/anon 0. Correcto.
3. Un `INVALID_RESOURCE_TIMESTAMP` en `cancel_building` que venía de estado residual de mi propio
   paso anterior; en limpio reembolsa 455,625 exactos.

Ninguno se reporta como gap. El gap reportado (pérdida de naves) está medido y reproducido de forma
independiente en ambos sentidos.

## 8. PENDIENTE

1. **Ledger de migraciones** — reconciliación humana.
2. **`DEFEND`** sigue sin soporte de combate (PRODUCT DECISION ya declarada, `COMBAT_SUPPORT_NOT_READY`).
3. **Lifeforms** sin cablear (0 filas) — decisión de producto de alcance.

* **No** debilita la guarda: sigue rechazando cualquier fecha pasada cruda; el worker simplemente
  deja de **pedir** una.
* Si el evento está en el **futuro** (el camino normal certificado) el clamp es un no-op y el
  anclaje a la marca del evento es **byte-idéntico** (verificado).
* Si está detrás, no queda tiempo transcurrido que acreditar: liquidar en el reloj actual concede
  **cero producción extra** y deja terminar el retorno.
* No se inventa balance: sin coste, tiempo, fórmula ni capacidad nueva.