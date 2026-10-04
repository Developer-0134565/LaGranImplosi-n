# LGI CORE RECOVERY — 2026-10-01

Misión: certificar y recuperar el core jugable. Este documento registra **lo verificado**, no lo supuesto.
No se toca el ledger de migraciones, ni los sistemas ya cerrados (combate, ACS, settlement de recursos/flotas).

---

## 1. P0 — SOFT-LOCK ECONÓMICO: CAUSA RAÍZ (reproducible)

La certificación con navegador real encontró `DevPlayer` en `MET 0 / CRY 0 / DEU 0` con producción 0 y
**todos los CTA de construcción, producción e investigación deshabilitados**. La causa raíz NO es un
parche de esa cuenta: es una regla del core.

### Cadena causal (medida sobre `prosrc`, no inferida)

```text
bootstrap_new_player_state
  → otorga 500 metal / 500 cristal (defaults de planet_resources) y NO siembra edificios
  → el jugador arranca sin ninguna fuente de energía

calculate_planet_production
  → v_production_factor := GREATEST(0, LEAST(1, v_energy_production / v_energy_consumption))
  → con energía producida = 0 y consumo > 0  ⇒  factor = 0  ⇒  producción = 0 en los tres recursos

inspect_demolition
  → exige recursos (INSUFFICIENT_RESOURCES antes de arrancar la cola)
  ⇒ la demolición NO es una vía de rescate con stock 0
```

### Reproducción en DOS movimientos legales desde el endowment real

| Paso | Coste | Restante | Energía |
|---|---|---|---|
| inicio | — | 500 M / 500 C | prod 0 / cons 0 |
| `shipyard` L1 | 400 M / 200 C | 100 M / 300 C | cons 11/h |
| `crystal_mine` L1 | 48 M / 24 C | **52 M** / 276 C | cons 22/h |

`solar_plant` L1 cuesta **75 M**: con 52 M el jugador **no puede comprar la energía** que su
producción necesita. Factor 0 ⇒ ingreso 0 ⇒ **bloqueo permanente**.

Es decir: el jugador nuevo hace una elección legal pero subóptima y queda *soft-locked de forma
irrecuperable*. El mismo estado que hoy tiene `DevPlayer` (crystal_mine L2 + shipyard L1, sin
`solar_plant`, −24.2/h).

### Por qué NO se aplicaron los "parches" prohibidos

- **NO** `if resources == 0 then grant resources` (rescate de admin disfrazado).
- **NO** `if energy < 0 then solar plant automatically` (regla de balance inventada).
- **NO** un gate de construcción por energía: `docs/systems/README_ECONOMY.md:169-171` registra una
  decisión explícita de LGI — *"**Energía = información, nunca puerta.** […] LGI NO bloquea la
  construcción por energía"* — verificada sobre `prosrc` de `start_building` y
  `evaluate_building_start_internal`. Una puerta de energía **reabriría un sistema cerrado**.

### Estado: **CLOSED 2026-10-01** — regla de producto aprobada e implementada (pre-flight de autosostenibilidad)

La *"decisión de producto"* que bloqueaba este GAP fue tomada y ya **no** es una incógnita: se
implementó el **pre-flight económico de autosostenibilidad** (ver
`docs/systems/README_ECONOMY.md`, sección *«PRE-FLIGHT DE AUTOSOSTENIBILIDAD»*). Resumen:

- `evaluate_economic_sustainability(planet, building, target_level)` simula por **cálculo puro**
  el estado post-acción con las mismas funciones de energía que `calculate_planet_production`, y
  devuelve `blocks = true` exactamente cuando el estado posterior deja `production_factor = 0`
  con consumo > 0 **y** existe una recuperación económica razonable.
- Se cableó en el oráculo único `evaluate_building_start_internal` (cliente + IA) **y también en
  `start_building`**, porque se descubrió que `start_building` **no** delega en `can_start_building`:
  cablear solo el oráculo dejaba libre la vía de mutación directa (la del atacante).
- El rechazo ocurre **antes de cobrar**: una acción bloqueada no cuesta recursos ni encola nada.
- Se respetó la decisión histórica: la energía sigue sin ser una puerta de construcción. Solo se
  bloquea el colapso demostrado. No se aplicó ningún `resource grant`, ni `auto-solar`, ni cambio de
  costes, ni cambio del arranque.

**Dos correcciones de datos** registradas en el ledger de migraciones: el delta energético de un
consumidor es **negativo** (`crystal_mine` L1 = −11), no positivo. La primera versión lo sumaba al
consumo y el guard quedaba **siempre inerte**; dos migraciones correctivas lo arreglan y la
aserción anti-vacuidad de la fixture impide que vuelva a pasar por bueno.

**Corrección de auditoría:** la secuencia «shipyard L1 + crystal_mine L1 → 52 metal» **no es
alcanzable desde el bootstrap**, porque `shipyard` cuesta además 100 deuterio y el arranque deja 0.
La secuencia real y alcanzable es de cinco pasos (documentada en README_ECONOMY) y termina con
5 metal frente a los 75 que cuesta la planta solar.

---

## 2. P1 — WRECK FIELD: PÉRDIDAS, AISLAMIENTO E IDEMPOTENCIA

### Defecto real corregido (`20261001000000`)

`settle_wreck_field_for_battle` derivaba las pérdidas de **`combat_unit_state`**, motor **muerto**
(`combat_unit_state` tiene **0 filas** en LIVE; el ledger vivo es `combat_individual_units`).
Además tomaba `quantity - quantity_alive` de la **última fila por unidad**, y las unidades que
mueren se **eliminan** en rondas posteriores ⇒ **subcuentaba** las pérdidas.

Corrección: la fuente es ahora **`calculate_combat_ship_losses(battle_id)`**, el ledger
*certificado y consciente de participantes*, que compara ronda 1 contra la última ronda y filtra
`unit_type = 'SHIP'` internamente (las defensas nunca entran al campo).

Bug encontrado por la propia fixture durante la certificación: la primera versión usaba la columna
inexistente `l.destroyed` (42703). Corregido a `l.destroyed_quantity` en una migración de una sola
lógica. **La fixture lo detectó; el motor anterior nunca habría podido fallar así porque jamás
llegaba a ejecutarse.**

---

## 3. RLS / ACL

| Tabla | Antes | Después |
|---|---|---|
| `planet_wreck_fields` | **RLS OFF**, sin grant a `authenticated` | RLS ON, `SELECT` owner-scoped, **sin** política de escritura |
| `planet_wreck_field_ships` | **RLS OFF**, sin grant | RLS ON, `SELECT` owner-scoped vía su campo |
| `planet_wreck_field_battles` | (no existía) | RLS ON, **sin** grants a `anon`/`authenticated` |

No se activó RLS a ciegas: se diseñó según el contrato real. Los contratos de motor
(`settle_wreck_field_for_battle`, `create_or_extend_wreck_field`, `start_wreck_field_repairs`,
`complete_wreck_field_repairs`, `run_wreck_field_worker`) **siguen siendo `service_role`-only**: un
cliente no puede fabricar un campo de restos.

**Verificado con roles reales** (no como superusuario, que ignora RLS):

```text
anon          → SELECT directo DENIED (42501)        <-- sin grant de tabla
authenticated → SELECT directo = 0 filas (no-owner) <-- RLS filtra
owner         → SELECT = 1 fila
no-owner      → get_planet_wreck_field() = 0 filas
no-owner      → start_planet_wreck_field_repairs() = DENIED / WRECK_FIELD_NOT_FOUND_OR_NOT_OWNED
```

Las 2 RPCs nuevas son `SECURITY DEFINER` con `search_path` fijo (`public, pg_temp`), resuelven el
propietario desde `auth.uid()` ellas mismas y **nunca lanzan excepción** ante un planeta ajeno: 0 filas.

Las otras 3 tablas con RLS off del reporte previo (`building_research_prerequisites`,
`moon_creation_rolls`, `moon_destruction_attempts`) **no se tocaron**: son tablas *append-only* de
auditoría interna del motor lunar, sin lecturas ni escrituras desde el frontend (`cert:contracts` no
lista ninguna). Su modelo de acceso correcto es backend-only y **ya lo es**. Abrirles una política de
cliente ampliaría superficie sin contrato.

---

## 4. FRONTEND

`src/WreckFieldPanel.tsx` (nuevo), montado en **DEFENSAS** junto a `MissileControlPanel` — mismo
patrón de la vista que ya aloja el panel de misiles y el de demolición.

**La UI no decide nada:**
- única lectura → `get_planet_wreck_field(planet)`; nunca envía id de jugador;
- única mutación → `start_planet_wreck_field_repairs(planet)`;
- tras mutar **re-lee** el contrato: **nunca** decrementa una cantidad en local;
- no calcula porcentaje recuperable, ritmo, duración ni expiración: los renderiza como vienen;
- no escribe `planet_wreck_fields`/`planet_wreck_field_ships` (no existe política de escritura);
- un rechazo de RPC es un **estado de error explícito**, no un campo vacío (para no ocultar un resto).

Estados cubiertos: `loading`, `empty`, `available`, `recovering` (refresca cada 5 s), `expired`
(expira en 72 h y el worker lo borra), `error`, `unauthorized`. Cerrojo anti doble-envío con
generación que descarta respuestas obsoletas al cambiar de cuerpo.

`cert:contracts` confirma que el panel **no añade ni una sola tabla** al acceso directo del cliente:
sólo RPCs.

---

## 5. VERIFICACIÓN

```text
tsc -b                0 errores
npm run build         OK
npx eslint src        0 errores · 5 warnings (las preexistentes, sin cambio)
npm run cert:contracts PASS · 56 RPC · sin operandos filtrados
git diff --check      limpio
```

Navegador real (Chrome headless/CDP, sesión autenticada, credenciales sólo por entorno):

```text
7/7 PASS  ·  panel renderizado en DEFENSAS  ·  estado real del servidor
           ·  sin error RPC  ·  sesión = DevPlayer (no el fallback anónimo)
```

El fixture SQL `wreck_field_recovery_certified_losses.sql` tiene **anti-vacuidad**: aborta si la
batalla de prueba no produce pérdidas reales, de modo que no puede pasar contra un motor roto.
Antes de esta corrección habría fallado: el motor anterior leía `combat_unit_state` (0 filas) y
devolvía siempre `NULL`.

---

## 6. MATRIZ DE DECISIÓN — PENDIENTE (no se aplicó)

Ningún elemento de esta matriz existe hoy en el repositorio. **Ninguno se introdujo.**

| # | Opción de regla de recuperación | Efecto en balance | Nota |
|---|---|---|---|
| A | Suelo mínimo de producción con déficit energético | **Altera la economía** | Rompe el `production_factor` certificado |
| B | Planta solar gratuita/garantizada con déficit | **Altera la economía** | Colisiona con "energía nunca puerta" en su lectura extrema |
| C | Bootstrap siembra `solar_plant` L1 + `metal_mine` L1 | Cambia el estado inicial | Rompe el invariante certificado "0 buildings" (`ai_bootstrap_and_dormant.sql:86`) |
| D | Demolición gratuita sólo con déficit (recurso devuelto) | Menor, sigue siendo regla nueva | Exige tocar `calculate_building_demolition_cost` |
| E | Rescue/newbie protection server-side | Nueva mecánica | La misión prohíbe mecánicas no solicitadas |

**Recomendación, sin aplicarla:** `C` es la más coherente con OGameX (empieza con mina + solar) y
convierte el fallo de "recuperación" en "imposible por construcción". Requiere decisión explícita
porque rompe un test certificado y cambia el estado de los imperios IA ya existentes.
**Corolario relevante:** `C` **no** repara cuentas ya agotadas como `DevPlayer` — esa seguiría
necesitando una acción administrativa autorizada, que esta misión no ejecuta.

---

## 7. PENDIENTE / NO RESUELTO

- **P0 soft-lock**: bloqueado a la espera de decisión de producto (§6). Sin inyector de recursos:
  conceder recursos para fabricar un PASS está prohibido.
- **Cuenta nueva confirmada**: `mailer_autoconfirm: false`; el signup exige confirmar correo.
  `DevPlayer` sigue siendo el **único humano**, y su ciclo económico completo
  (construir/producir con recursos reales) queda **UNPROVEN** — no hay bloqueos que lo impidan, pero
  tampoco recursos con los que ejecutarlo.
- **Wreck Field en combate real**: el backend está certificado con una batalla real (10 naves
  destruidas → campo creado → extensible e idempotente) y la UI está certificada leyendo su estado.
  Lo que **no** se ha ejecutado es un combate completo *disparado desde la UI* seguido de la
  recuperación en la misma sesión: la cuenta no tiene naves con las que hacerlo. Marcado UNPROVEN.
### Ledger de aislamiento e idempotencia

`planet_wreck_field_battles (battle_id PK)` — un combate liquida **como máximo una vez**:

- `INSERT … ON CONFLICT DO NOTHING` + `IF NOT FOUND` ⇒ el perdedor de la carrera no añade nada;
- el re-disparo del trigger, un retry del worker o una llamada manual son **no-op**;
- una batalla **sin pérdidas** no deja fila (se libera el reclamo) ⇒ **cero campo fantasma**;
- el campo pertenece **solo** al planeta defensor de *esa* batalla.

Medido en vivo (rollback): 10 naves perdidas → **2 almacenadas** (20 % = `least(100, 20+8·nivel)` con
Dique 0); tras re-liquidar la misma batalla → **sigue 2, no 4**. Defensas excluidas. Ledger = 1 fila.

### Reglas preservadas (NO inventadas)

Todo lo de balance viene de `20260926230000` + `docs/systems/README_FLEET_ENGINE.md`: un campo por
planeta; una batalla nueva lo **extiende** y refresca la expiración de **72 h**; sólo naves; en el
planeta **defensor**; recuperable = `least(100, 20 + 8 · nivel_dique)` %; reparaciones **gratuitas**
(sólo tiempo); reparo = `5 · nivel` naves/h. **Cero pérdidas ⇒ ningún campo.** Ningún umbral, expiry
o fórmula nueva fue introducida por esta misión.