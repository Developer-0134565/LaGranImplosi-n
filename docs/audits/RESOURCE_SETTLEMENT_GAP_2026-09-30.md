# RESOURCE SETTLEMENT GAP — CARGO SILENTLY DESTROYED (2026-09-30)

Misión de barrido economía/gameplay. **GAP TÉCNICO REAL — IMPLEMENTADO, LIVE VERIFIED.**
`MIGRATIONS = 2` (aplicadas) · `TESTS = 1 nuevo` · `RPC = 0` · `UI = 0 cambios` · `RESIDUO = 0`.
Sin commit ni push. Ningún sistema cerrado reabierto.

## 1. SYNC GATE

```text
branch          main
HEAD            3669e27e4e9d9f44c68f12244e7a4e4154127b0f
origin/main     75bbc48e2b55dc8439ab17e52e254218b96ef8aa
merge-base      3669e27 (= HEAD)  → SIN DIVERGENCIA
ahead/behind    0 / 1   (el commit remoto 75bbc48 toca SOLO docs/MARCIANITOS_GALAGA_CONTEXT.md,
                         fichero NUEVO → cero colisión con las 22 modificadas + 60 untracked)
staged 0 · deleted 0 · stashes 5 (intactos)
```

Sin pull / push / commit / merge / rebase / reset / clean / checkout / restore / stash-pop /
`supabase db push` / `migration repair`.

## 2. EL GAP

**Los recursos entregados por una flota se acreditaban y acto seguido se destruían.**

Los resolvers de llegada acreditan la carga **sin tope**, igual que hace OGameX:

| Resolver | Código | Tope |
|---|---|---|
| `resolve_transport_arrival` | `metal = pr.metal + v_fleet.metal` | ninguno |
| `resolve_deploy_arrival` | `metal = pr.metal + v_fleet.metal` | ninguno |
| `resolve_expedition_return` | `metal = pr.metal + v_fleet.metal` | ninguno |

Pero **las dos funciones de liquidación** terminaban así:

```sql
v_metal := LEAST(v_metal_capacity, GREATEST(0, v_metal + v_metal_produced));
```

Eso recorta el **TOTAL EN CURSO**, no el incremento. Medido contra LIVE, con transición real:

```text
capacidad 100 000 · stock 99 000 · un transporte entrega 50 000
  → llegada           : 149 000 metal en el planeta
  → siguiente tick    : 100 000 metal
  → 49 000 metal DESTRUIDOS, sin evento, sin informe, sin entrada en ningún log
```

`resolve_expedition_return` sufre la misma suerte: el botín de una expedición también se perdía al
siguiente tick.

## 3. EVIDENCIA OGameX

`app/Services/PlanetService.php` → `updateResourcesUntil` (descargado y leído literalmente hoy):

```php
$max_metal     = $this->metalStorage()->get();
$current_metal = $this->metal()->get();
if ($current_metal < $max_metal) {
    $add_resources->metal->add(new Resource($this->planet->metal_production * $hours_difference));

    // Prevent adding more metal than the max limit can support (storage limit).
    if (($current_metal + $add_resources->metal->get()) > $max_metal) {
        $add_resources->metal->set($max_metal - $current_metal);
    }
}
```

El tope se aplica **a la cantidad que se suma**, jamás al stock ya poseído. Un planeta por encima de
su capacidad conserva los recursos y simplemente deja de producir hasta que el jugador gaste el
excedente. Upstream no pierde nada.

`addResources()` (usado por `TransportMission::processArrival`) tampoco recorta por capacidad; sólo
aplica `max(0, ...)`. Es decir: **la entrega y la producción nunca compiten por el mismo tope en
upstream**. En LGI competían, y ganaba la producción.

## 4. EL ARREGLO

Una única autoridad inmutable, `settle_resource_stock(current, delta, capacity)`:

## 5. VERIFICACIÓN

| Prueba | Resultado |
|---|---|
| `resource_settlement_cargo_preservation.sql` (nueva, 18 asserts) | **18 PASS / 0 FAIL** (ROLLBACK) |
| Regresión medida antes/después | `metal_destroyed` **49 000 → 0** |
| Producción normal bajo el tope | monótona y acotada (PASS) |
| Planeta exactamente en el tope | deja de producir (PASS) |
| Sólo queda 100 de hueco | rellena hasta el tope, no lo pasa (PASS) |
| Consumo de la planta de fusión | 100 000 → 0, **no** anclado al tope (PASS) |
| `resolve_deploy_arrival` | sigue completando y descargando (PASS) |
| `cancel_building` | reembolsa exacto (500 000 − 499 544,375 = 455,625) (PASS) |
| `npx tsc -b` | exit 0 |
| `npm run build` | exit 0 |
| `npx eslint src` | exit 0 (0 errores, 5 warnings preexistentes) |
| `npm run cert:contracts` | exit 0 PASS |
| `git diff --check` | 0 |

**Guarda anti-vacuidad**: la primera versión de la fixture fallaba 2 asserts porque
`bootstrap_new_player_state` **no crea edificios** ⇒ el planeta de prueba producía 0/h y la
asertión 9 (la regresión) pasaba por vacuidad. Corregido: la fixture siembra minas explícitas y
**aborta** (`TEST_ABORT`) si el planeta no produce realmente.

## 6. SEGURIDAD

* `settle_resource_stock`: `IMMUTABLE`, `search_path` fijo, `EXECUTE` **sólo `service_role`**
  (misma postura que `calculate_planet_production`). No es un contrato de cliente.
* Las funciones de liquidación conservan su ACL: **cero superficie nueva** para el navegador.
* No se añadió ningún RPC de escritura, ni `player_id` confiado, ni acceso a `service_role` desde
  el cliente, ni bypass de RLS. Verificado en las aserciones 14 y 15.
* Advisor de seguridad: los avisos son **preexistentes y ajenos** (RLS sin política en 3 tablas,
  `search_path` mutable en 9 funciones antiguas). El helper nuevo fija `search_path` y no otorga
  permisos a `anon`.

## 7. RESIDUO

```text
planetas de prueba 0 · jugadores de prueba 0 · usuarios auth de prueba 0
flotas 1 (histórica, COMPLETED) · 715 jugadores · 715 planetas
```

El recuento de cuerpos subió 714 → 715 durante la sesión, pero **no es residuo mío**: es
`AI-G1-S42-P14`, un mundo autónomo creado por el tick del universo (`player_type = AI`,
`created_at 20:03`). Todos mis probes corrieron dentro de transacciones con `ROLLBACK`.

## 8. DESCARTADO EN ESTE BARRIDO (con motivo)

| # | Candidato | Veredicto |
|---|---|---|
| 1 | `ui_defense_queue` sin llamador en cliente | **FALSO POSITIVO.** `App.tsx` lee `defense_queue` como tabla y RLS sí lo permite (`defense_queue_owner_read`, `anon+authenticated`, vía `auth.uid()`). El RPC es redundante, no un hueco. |
| 2 | `ui_universe_galaxies` sin llamador | **FALSO POSITIVO.** `GalaxyView.tsx` lee `universe_galaxies` directamente. |
| 3 | `project_building_production` sin UI | **YA DOCUMENTADO como cableado deliberadamente prohibido** (`README_ECONOMY` §"No cableado"): mezcla producción autoritativa con fórmulas desnudas y sobreestimaría una mejora. |
| 4 | Lifeforms: `storage_percent` / `crawler_efficiency_percent` sin consumir | **FUERA DE ALCANCE.** Las 4 lifeforms, 48 edificios y 72 technologies existen, pero `planet_lifeforms`, `planet_lifeform_research` y `planet_lifeform_buildings` tienen **0 filas**: subsistema sin cablear, ya excluido (§6 del sweep previo). |
| 5 | Edificios sin fila en `building_energy_definitions` | **CORRECTO.** Sólo las 3 minas consumen energía (+ `solar_plant` con 0); en OGameX los almacenes, el laboratorio, el hangar y el resto tampoco consumen. |
| 6 | `defense_queue` sin `time_check` | **Cosmético.** Sus hermanos `building_queue`/`shipyard_queue`/`research_queue` sí lo tienen, pero `start_defense` calcula `finishes_at` desde `GREATEST(now(), …)`, luego siempre `> started_at`. Endurecerlo es una misión de robustez, no un hueco jugable. |
| 7 | Temperatura −150…240 | **CORRECTO.** Span de exactamente 40° en las 15 bandas (PR #514 de OGameX). El −150/240 es la banda 1, no un dato corrupto. |
| 8 | `calculate_planet_storage` no aplica bonus de lifeform | **FUERA DE ALCANCE** (ver #4: 0 filas de lifeform en el universo). |

## 9. PENDIENTE

1. **Ledger de migraciones** — reconciliación humana (sin cambios en esta misión).
2. **`defense_queue` sin `finishes_at > started_at`** — robustez, opcional.
3. **Lifeforms** — siguen sin cablear; es la mayor superficie de economía muerta, pero exige
   decisión de producto de alcance, no un gap determinable.
4. **Browser certification** — NO aplica a esta misión: el arreglo es 100 % backend y no toca
   `src/`. No hay ninguna superficie de UI nueva que certificar, y la UI de recursos ya muestra
   `ALMACÉN M/C/D` leyendo `get_planet_economy_overview`, cuyo valor no cambia.
```sql
greatest( 0,
  current
  + least( greatest(delta,0), greatest(capacity - current, 0) )  -- producción: sólo hueco libre
  + least( delta, 0 )                                          -- consumo: siempre completo
)
```

* `update_planet_resources_until_raw` y `update_planet_resources` delegan en ella (una sola
  autoridad, dos llamadores).
* El consumo (negativo, p. ej. la planta de fusión) **nunca** se recorta: sin esta separación,
  arreglar el overflow habría roto el combustible de la fusión.
* El resultado nunca es negativo (`max(0, ...)` de OGameX).
* `LEAST(capacity, current + delta)` queda **explícitamente descartado**: es la expresión que
  destruía el excedente.

Los resolvers de llegada **no se tocan**: siguen acreditando exactamente como OGameX. La migración
sólo impide que la liquidación se lo arrebate después.

**No se inventa balance**: no hay coste, tiempo, fórmula ni capacidad nueva. Se restaura el
comportamiento demostrado de upstream.