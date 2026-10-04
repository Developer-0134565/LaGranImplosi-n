# INDEPENDENT TECHNICAL GAP CLOSURE — 2026-10-01

Misión de **auditoría dirigida + cierre de GAPs técnicos independientes**.
`MIGRATIONS = 2` (aplicadas) · `TESTS = 2 nuevos + 3 reparados` · `RPC = 0 nuevos` ·
`UI = 0 cambios` · `RESIDUO = 0`. Sin commit ni push. Sin mecánicas nuevas.

---

## 1. SYNC GATE

```text
branch          main
HEAD            3669e27e4e9d9f44c68f12244e7a4e4154127b0f   (sin cambios)
origin/main     75bbc48e2b55dc8439ab17e52e254218b96ef8aa   (2026-09-28)
merge-base      3669e27 (= HEAD)  → SIN DIVERGENCIA
ahead/behind    0 / 1
commit remoto   75bbc48 "docs: add Marcianitos learning context"
                → toca SOLO docs/MARCIANITOS_GALAGA_CONTEXT.md (fichero nuevo, sin colisión)

staged          0
modified        21  (20 preexistentes + 1 de esta misión: supabase/tests/fleet_worker_contract.sql)
untracked       81  (79 preexistentes + 4 de esta misión)
deleted         0
stashes         5  (intactos, ninguno tocado)
git diff --cached  0
```

Sin `pull` · `push` · `commit` · `merge` · `rebase` · `reset` · `clean` · `checkout` ·
`restore` · `stash pop/drop` · `db push` · `migration repair`. Ninguna credencial leída ni
revelada (`credentials.txt` y `.env.local` no se han abierto).

**Trabajo local preservado.** El recuento de rutas pasó de 98 a 102, y la diferencia son
exactamente los 4 ficheros nuevos de esta misión. Ningún fichero rastreado previo fue
sobrescrito o descartado; el único `M` nuevo es una fixture de test.

---

## 2. ÁREAS AUDITADAS Y EVIDENCIAS CONSULTADAS

| Área | Evidencia real consultada | Resultado |
|---|---|---|
| Worker de flotas | `process_fleet_movements` (prosrc completo, 3 ramas de aislamiento), `cron.job` + `cron.job_run_details` | **GAP-1, GAP-2** |
| Ciclo de vida de expediciones | `resolve_expedition_arrival`, `resolve_expedition_return`, `expedition_results` | **GAP-2** |
| Misiles / escombros / reciclaje | `collect_debris`, `calculate_recycler_capacity`, `can_recycle_debris`, `get_recyclable_debris_status`, rama RECYCLE del worker | **GAP-1** |
| Combate, botín e idempotencia | `resolve_attack_arrival`, `apply_attack_loot`, ledger `planet_wreck_field_battles` | sin regresión |
| Los nueve tipos de misión | `fleet_movements_mission_type_check` (12 valores) contra las 12 ramas del worker | sin regresión |
| Colas (edificios / investigación / naves / defensas) | `process_building_queue_*`, `process_research_queue_*`, `process_shipyard_queue*`, `process_defense_queue*`, `complete_building/research` | sin regresión |
| Economía y liquidación | `update_planet_resources[_until][_until_raw]`, `settle_resource_stock`, clamp de 20260930240000 | sin regresión |
| Identidad / ownership / ACL | `enforce_player_write_access`, `get_advisors(security)` completo | sin regresión |
| Workers / cron / heartbeat | 6 jobs activos (1 s flotas, 1 min heartbeat, 5 min ranking/IA, 10 min wreck, 4 h retención) | sin regresión |
| Prerrequisitos y catálogos | edificios 16 · naves 17 · defensas 10 · tecnologías 16 | sin regresión |
| Mensajería | `player_messages`, triggers `fleet*` con `dedupe_key` | GAP-4 (fixture) |
| Consistencia frontend ↔ backend | `scripts/contract-inventory.mjs --assert-client-dispatchers` | PASS |
### OGameX consultado (`main` @ `2649076`)

| Fichero real | Qué se comprobó |
|---|---|
| `app/GameMissions/RecycleMission.php` | `processArrival()` harvesta lo que haya y **siempre** llama `startReturn()`; un campo vacío da 0, no un error |
| `app/GameMissions/Abstracts/GameMission.php` | Los ciclos llegada/retorno son contratos de la clase base, no excepciones |
| `app/GameObjects/*.php` | Catálogos y fórmulas ya auditados el 2026-09-30; no se reabrieron |

`OGameX: no new relevant difference` para todo lo demás. **El GAP-1 NO viene de OGameX**: es la
consecuencia interna de que `collect_debris` se niegue y el worker degrade el error. **El GAP-2 no
tiene equivalente upstream**: es un error puramente local de PL/pgSQL.

---

## 3. GAPs ENCONTRADOS

### GAP-1 · RECYCLE atascado en un campo de escombros agotado — ALTO

**Severidad: ALTA.** Destrucción permanente de naves + pérdida permanente de slot de flota.

```text
collect_debris (coordenada sin restos)
  → RAISE 'No debris field at [%:%:%] in universe %'    ← el primer reciclador drenó el campo y
                                                            collect_debris BORRA la fila
  → RAISE 'Debris field is empty'                       ← fila presente con 0/0
process_fleet_movements
  → exception when others then raise warning 'FLEET_RESOLUTION_FAILED'
    (un WARNING no deshace nada ni se surface)
⇒ la flota reintenta PARA SIEMPRE en OUTBOUND
```

**Reproducción medida en LIVE (sondas con ROLLBACK, por el worker real), antes del arreglo:**

| Escenario | Estado tras una pasada del worker |
|---|---|
| A. campo agotado (0/0) por otro reciclador | `OUTBOUND` |
| B. campo **borrado** por otro reciclador | `OUTBOUND` |

**Impacto medido:**
* las naves (ya debitadas en el despacho) se pierden definitivamente;
* `get_player_fleet_slots` cuenta todo movimiento cuyo estado no sea `COMPLETED`/`CANCELLED`
  ⇒ **un slot de flota perdido para siempre** por reciclador perdido. Con `computer_technology` 0
  (1 slot) es un bloqueo total de flota.

**Alcanzabilidad = orden ORDINARIO, no una carrera exótica.** `start_fleet_mixed` elige el destino
de RECYCLE **en servidor** («el campo no vacío más cercano») y **no lo reserva**. Dos recicladores
lanzados en la misma ventana —del mismo jugador o de dos jugadores del universo— apuntan al mismo
campo. El primero lo drena y lo borra; el segundo es el que se atasca.

**DECISION GATE — la semántica se leyó, no se inventó.** OGameX `RecycleMission::processArrival()`
harvesta lo que haya (`LootService::distributeLoot` devuelve 0 si el campo está vacío) y **siempre**
llama `startReturn()`. LGI ya aplicaba exactamente esa misma regla al caso estructuralmente idéntico
en `resolve_colonize_arrival` («A late worker must not extend the flight» → `RETURNING`, la carga se
conserva). La rama RECYCLE era la única resolutora de llegada sin esa guarda.

**Arreglo mínimo (un call-site, una misión):** en la rama RECYCLE del worker se absorben
**exactamente** esos dos desenlaces y se trata como «recogido 0»; cualquier otro error se vuelve a
lanzar intacto. El movimiento sigue después el camino de éxito **ya existente** (`RETURNING` con
`returns_at = arrives_at + duración`).

**No se toca:** `collect_debris` (md5 byte-idéntico), `calculate_recycler_capacity`, `start_fleet_mixed`,
`get_recyclable_debris_status`, `get_player_fleet_slots`, la firma/seguridad/search_path del worker, y
los 3 manejadores `FLEET_RESOLUTION_FAILED`. Ni un solo valor de coste, tiempo, capacidad o porcentaje.
---

### GAP-2 · `resolve_expedition_return`: referencia ambigua ⇒ el 100 % de las expediciones se atascan — CRÍTICO

**Severidad: CRÍTICA. Determinista. Afecta a todas las expediciones, siempre.**

`resolve_expedition_return` RETURNS TABLE(..., `status text`). El parámetro OUT `status` es una
**variable** de PL/pgSQL y `fleet_movements.status` es una **columna**. La sentencia final la
referenciaba sin cualificar:

```sql
UPDATE public.fleet_movements
SET metal = 0, crystal = 0, deuterium = 0, status = 'COMPLETED'
WHERE id = p_fleet_id AND status = 'RETURNING';
```

Con el `plpgsql.variable_conflict = error` por defecto, Postgres **rechaza la sentencia**. Es un
error de plan, no una carrera: salta en **cada** ejecución.

```text
ERROR:  42702: column reference "status" is ambiguous
DETAIL:  It could refer to either a PL/pgSQL variable or a table column.
```

**Medido en LIVE:** exactamente un movimiento atascado — `EXPEDITION d79a0bd0-…`, `RETURNING` con
`returns_at` 13 h en el pasado y 5 `large_cargo` a bordo. Llamar a la función desplegada sobre él
devolvía 42702. Tras el arreglo se resolvió solo en el siguiente tick del worker (1 s).

**Consecuencia:** cada expedición perdía sus naves para siempre **y** consumía un slot de flota para
siempre. Una expedición con `computer_technology` 0 = bloqueo total de flota.

**Por qué las otras seis no estaban afectadas** (y por qué el arreglo es el de su convención):

| Función | `UPDATE public.fleet_movements` | ¿Ambigua? |
|---|---|---|
| `resolve_transport_arrival` | `fm` (alias) | NO |
| `resolve_deploy_arrival` | `AS fm` | NO |
| `resolve_colonize_arrival` | `fm` (alias) | NO |
| `resolve_espionage_arrival` | `fm` (alias) | NO |
| `process_defense_queue` / `process_shipyard_queue` | `dq` / `sq` (alias) | NO |
| `recall_fleet` | **sin alias** | NO — sus OUT son `out_status`, `out_mission`, …: ninguna se llama `status` |
| `resolve_expedition_return` | **sin alias** | **SÍ** |

**Detección exhaustiva del corpus:** se recorrieron los 56 RPC de `public` buscando todo parámetro
OUT cuyo nombre chocara con una columna usada sin cualificar en un `WHERE`. **Exactamente una
función: `resolve_expedition_return`.** Ninguna otra.

**Arreglo mínimo:** un alias, exactamente como sus cuatro hermanas. El parámetro OUT **no** se
renombra: `status` forma parte de la lista de columnas publicada de este contrato.

**No se toca:** el clamp de 20260930240000, la guarda «Expedition must be RETURNING», la devolución
de naves, el crédito de carga, los valores retornados, la firma `RETURNS TABLE(...)`, la volatilidad
(VOLATILE), SECURITY (INVOKER), `search_path` y la ACL (sólo `service_role`).

---

### GAP-3 · Fixture certificada que no se podía ejecutar — MEDIO (integridad de certificación)

`supabase/tests/fleet_stuck_return_arrival_regression.sql` tenía un bloque
`end $test$; / select; do $summary$; rollback;` insertado **en mitad del cuerpo**, en las líneas
127–142, cuando el `end $test$;` real está en la línea 258.

**Consecuencia medida:** el fichero **abortaba con `42703: column "v_dst" does not exist`** en la línea
145, porque las aserciones 4–13 quedaron **fuera del bloque DO** y sus variables PL/pgSQL ya no
existían. Esas **10 aserciones certificadas eran código muerto**: nunca se ejecutaron. Además, el
bloque de resumen corría antes del `rollback`, así que sólo contaba 3 filas.

**Agravante de seguridad de datos:** todo lo posterior al `rollback` habría corrido en **autocommit**.
Hoy aborta por el identificador inexistente; si algún día ese identificador se volviese resoluble, el
resto de la fixture **escribiría en LIVE y confirmaría**.

**Arreglo mínimo:** se movió el bloque mal colocado al final del fichero. **Ningún texto de
aserción cambió.** Resultado: las 13 aserciones ahora se ejecutan y **todas pasan**.

Defecto de aserción latente que la reparación destapó (mismo fichero, misma familia): la aserción 3
comparaba `count(*) = 5`, pero `count(*)` cuenta **filas**, no unidades — lo que contradecía el
comentario inmediatamente anterior («credited exactly once»). Corregido a *una fila + 5 unidades*,
que es literalmente lo que dice el comentario.

---

### GAP-4 · Dos fixtures certificadas que medían absolutos donde su propia convención exige deltas — BAJO

Ninguna es un defecto de producto; ambas son fallos de medición que hacen que la suite falle en LIVE.

| Fichero | Aserción | Antes | Ahora |
|---|---|---|---|
| `recyclable_debris_status.sql` | 2 | `v_moves = 0` (total absoluto) | `v_moves = v_moves_before` (delta) |
| `fleet_worker_contract.sql` | 3 y 5 | `v_msgs >= 1` / `v_msgs <= 4` (absolutos) | deltas antes/después |

El propio fichero `recyclable_debris_status.sql` documenta en su aserción 4 la convención correcta:
*«Counted as a DELTA (before/after), never as an absolute total: LIVE may already hold RECYCLE rows
for this player»*. LIVE efectivamente tenía 1 fila RECYCLE previa y 25 mensajes `fleet*`, así que
ambas aserciones fallaban por datos ajenos al contrato. El **comportamiento del motor era correcto en
ambos casos** (el rechazo `No debris field available for RECYCLE` se reprodujo literalmente).
---

## 4. CAMBIOS REALIZADOS

### Base de datos (aplicadas con `apply_migration`, bloque de postcondiciones que aborta si el estado no es el esperado)

| Fichero | Qué hace |
|---|---|
| `supabase/migrations/20261001060000_fix_stuck_recycle_fleet_empty_debris_field.sql` | Splice anclado sobre `pg_get_functiondef('process_fleet_movements')`: absorbe exactamente `'Debris field is empty'` y `'No debris field at%'` en la rama RECYCLE; todo otro error se relanza |
| `supabase/migrations/20261001070000_fix_ambiguous_status_in_expedition_return.sql` | Splice anclado sobre `pg_get_functiondef('resolve_expedition_return')`: `UPDATE public.fleet_movements AS fm … WHERE fm.id = p_fleet_id AND fm.status = 'RETURNING'` |

Ambos verificados por `md5(prosrc)` de los cuerpos que **no** debían cambiar:
`collect_debris` `4e63662301c7d89b3b07b720ec4d7627`, `start_fleet_mixed` `611d107dacf0e3869d162d11fb63fcf1`,
`calculate_recycler_capacity` `235910c7dd6a3b31ec7ee712af2d24f1`, `get_player_fleet_slots` `119b1100d6b13b40428545c5ebad3cf4`.

### Tests

| Fichero | Acción |
|---|---|
| `supabase/tests/recycle_fleet_empty_field_regression.sql` | **NUEVO** — 19 aserciones |
| `supabase/tests/expedition_return_ambiguous_status_regression.sql` | **NUEVO** — 15 aserciones |
| `supabase/tests/fleet_stuck_return_arrival_regression.sql` | **REPARADO** — bloque mal colocado movido al final; aserción 3 corregida. 3 → **13 aserciones ejecutables** |
| `supabase/tests/recyclable_debris_status.sql` | **REPARADO** — aserción 2 a delta |
| `supabase/tests/fleet_worker_contract.sql` | **REPARADO** — aserciones 3 y 5 a delta |

**Ningún cambio en `src/`, `package.json`, `worker/`, catálogos ni balances.**

---

## 5. PRUEBAS EJECUTADAS Y RESULTADOS

### Funcionales (LIVE, dentro de ROLLBACK salvo donde se indica)

| Fixture | Resultado |
|---|---|
| `recycle_fleet_empty_field_regression.sql` (nueva) | **19 PASS / 0 FAIL** |
| `expedition_return_ambiguous_status_regression.sql` (nueva) | **15 PASS / 0 FAIL** |
| `fleet_stuck_return_arrival_regression.sql` (reparada) | **13 PASS / 0 FAIL** (antes: 3 ejecutables + 10 muertas) |
| `fleet_stuck_attack_espionage_arrival_regression` | **9 PASS / 0 FAIL** |
| `combat_worker_isolation` | **8 PASS / 0 FAIL** |
| `recyclable_debris_status` (reparada) | **12 PASS / 0 FAIL** |
| `fleet_worker_contract` (reparada) | **6 PASS / 0 FAIL** |

Detalle de los controles que prueban que **no** se cambió ningún comportamiento:

```text
RECYCLE control  · campo con 60 000 de restos · 5 recicladores
                 · recogido 59 999,999999999999998 (= least(5 × 20 000, 60 000), tolerancia 1e-6)
                 · lo que SALIÓ del campo es EXACTAMENTE lo que LLEGÓ al planeta origen
                 · quedan 2e-17 de cristal por el redondeo proporcional preexistente
RECYCLE fail-loud · flota sin reciclador → la negativa SIGUE abortando (OUTBOUND), observable
EXPEDITION        · cierre doble rechazado por la guarda existente (exactly-once)
                  · el clamp de 20260930240000 sigue desplegado
                  · ACL service_role intacta, sin EXECUTE para anon ni authenticated
MENSAJERÍA        · +3 mensajes `fleet*` por un ciclo TRANSPORT completo (≤4) ⇒ dedupe correcto
```

### Locales

```text
npx tsc -b               exit 0
npx eslint src           exit 0
npm run build            exit 0
npm run cert:contracts   exit 0   PASS (56 RPC; dispatchers indirectos detectados)
```

### Residuo LIVE tras la misión

```text
movimientos no terminales        0   (antes: 1 — el GAP-2 atascado, ya resuelto por el worker)
shipyard_queue BUILDING          0
defense_queue  BUILDING          0
building_queue  BUILDING         0
research_queue  RESEARCHING      0
planet_wreck_field_battles       0
749 jugadores · 750 planetas
```

**Efecto de datos inevitable y deseado:** al aterrizar el GAP-2, el worker de 1 s completó el
movimiento `d79a0bd0-…` que llevaba 13 h atascado (rescate de 5 `large_cargo` + 125 000 metal al
planeta origen `f35bd4b9`) y liberó su slot. No se ejecutó ninguna otra escritura fuera de ROLLBACK.
---

## 6. ESTADO DE LAS CERTIFICACIONES PREVIAS

| Sistema | Estado | Nota |
|---|---|---|
| Economía / producción / energía | **CLOSED** | sin regresión; `calculate_planet_production` intacto |
| Combate / botín / idempotencia | **CLOSED** | sin regresión; `combat_worker_isolation` 8/8 |
| Espionaje | **CLOSED** | sin regresión; informe generado, fixture 9/9 |
| ACS / HOLDING / recall | **CLOSED** | sin regresión; `recall_fleet` intacto |
| Misiles | **CLOSED** | **interior no re-auditado** (fuera de alcance) |
| Wreck Field / Space Dock | **CLOSED** | sin regresión; ledger 0 filas |
| Mensajería (4 productores) | **CLOSED** | +3 mensajes por ciclo TRANSPORT, sin duplicados |
| Lifecycle edificio / investigación | **CLOSED** | sin regresión |
| Identidad / Ownership / RLS / ACL | **CLOSED** | sin regresión; advisor sin hallazgo nuevo |
| Catálogos y prerrequisitos | **CLOSED** | sin cambios |
| UI: contrato → RPC → refresh | **NO GAP** | `cert:contracts` PASS |
| **Expediciones (retorno)** | **GAP-2 CERRADO** | estaba roto al 100 %; ninguna certificación lo cubría |
| **Reciclaje (llegada)** | **GAP-1 CERRADO** | el único arrival resolver sin guarda de precondición |

---

## 7. PENDIENTES QUE DEPENDEN DE DECISIÓN DE PRODUCTO

**No implementados en esta misión**, tal como estaba registrado:

Colonias (rangos OGameX + resultado aleatorio persistido) · DEFEND/ACS (ciclo completo, vía
`planet_support_authorizations`) · Friends/Buddies y Alliances/Guilds (arquitectura modular) ·
Late-join · normalización de los 729 perfiles antiguos de IA · activación de IA (todas `DORMANT`) ·
protección de principiantes reutilizada para ataques de IA · escudo (perderlo al atacar o espiar a
cualquier jugador).

**Observación registrada, NO corregida** (fuera de alcance y sin impacto material):
`collect_debris` reparte proporcionalmente con división `numeric`, así que drenar un campo deja un
residuo de ~2e-17 de cristal. Consecuencia: `get_recyclable_debris_status()` puede devolver
`available = true` para un campo sin nada recolectable. No crea ni destruye recursos, ninguna otra
ruta lo usa para decidir, y **el GAP-1 hace que esa flota vuelva a casa igual**. Corregirlo sería
mezclar una corrección no relacionada en esta misión.

---

## 8. CONFIRMACIÓN DE PRESERVACIÓN DEL TRABAJO LOCAL

* `HEAD` = `3669e27e4e9d9f44c68f12244e7a4e4154127b0f` — **sin cambios**.
* `origin/main` = `75bbc48…`; `ahead/behind` = `0 / 1` — **igual que al empezar**; sin divergencia.
* `staged` = 0 — nada en el índice.
* 5 stashes — **intactos**, ninguno aplicado ni descartado.
* `deleted` = 0 — ningún fichero borrado.
* Rutas: 98 → 102. Los 4 nuevos son los 2 ficheros de migración y las 2 fixtures nuevas.
* De los 20 ficheros modificados que ya existían, **ninguno fue alterado** salvo
  `supabase/tests/fleet_worker_contract.sql`, que es una fixture de test (GAP-4).
* `src/`, `package.json`, `worker/` y `scripts/` intactos.
* No se leyó ni se copió ninguna credencial.

---

## 9. CRITERIO DE CIERRE

**CUMPLIDO.** Los GAPs independientes identificados y verificados quedan cerrados:

* **GAP-1 (ALTO)** — reciclador atascado en campo agotado/borrado → cerrado, 19/19.
* **GAP-2 (CRÍTICO)** — el 100 % de los retornos de expedición fallaban con 42702 → cerrado, 15/15,
  y el único movimiento atascado de LIVE se resolvió solo.
* **GAP-3 (MEDIO)** — fixture certificada inejecutable con 10 aserciones muertas → reparada, 13/13.
* **GAP-4 (BAJO)** — dos fixtures con medición absoluta en lugar de delta → reparadas, 12/12 y 6/6.

Sin regresión en ninguna certificación previa. No se ha iniciado ninguna mecánica nueva.