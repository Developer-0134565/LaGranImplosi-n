# ECONOMY GAP SWEEP — 2026-10-02

> **Resultado: `NO OBJECTIVE ECONOMY GAP FOUND`.** Barrido *discovery-first*: **no se modificó código**
> (ni SQL, ni RPC, ni TS/TSX, ni CSS, ni fixtures). Este documento existe para que el barrido **no
> se repita** y para dejar trazable por qué se descartó cada candidato.

```text
Backend implementation   NO CHANGE (no gap to implement)
Live verification        CLOSED (economy surface probed LIVE, owner-scoped)
Product decisions        2 RECORDED, not invented
Environment blockers     1 (fleet browser certification, out of scope here)
```

## 1. Método (medición, no lectura de informes)

```text
sync gate     main, behind 2, sin divergencia, 22 modificados / 95 untracked / 5 stashes, todo preservado
superficie    scripts/contract-inventory.mjs -> 92 nombres RPC/tabla que el cliente usa de verdad
contraste    ese conjunto contra pg_proc + has_function_privilege('authenticated', …) en LIVE
humo          los 11 contratos economicos ejecutados COMO EL JUGADOR AUTENTICADO REAL (no service_role)
```

El contraste se hizo sobre `supabase.rpc('…')`, **no** sobre `database.types.ts`: ese fichero declara
*todas* las funciones de la base de datos, así que buscar un nombre ahí da falsos positivos
(`get_planet_economic_rates_snapshot`, `calculate_virtual_production`, `calculate_planet_storage`,
`project_building_production` y `calculate_planet_production_snapshot` "aparecen" en `src/` y sin
embargo **no** se invocan nunca).

## 2. Candidatos evaluados y por qué NO son gap

### 2.1 `get_economic_sustainability_check` existe LIVE y no tiene consumidor — **NO GAP**

Era el candidato más fuerte (criterio A). Su cuerpo es `STABLE SECURITY DEFINER`, owner-scoped
(`players.user_id = auth.uid()`), y devuelve `allowed / reason_code / reason` más
`recovery_available`. Está `authenticated`-executable y hay **0 llamadas** desde `src/**`.

**Por qué no es gap:** el pre-flight que la UI ya usa, `can_start_building`, devuelve *el mismo hecho
decisivo*. Medido LIVE sobre un planeta al borde:

```text
can_start_building(...,'metal_mine')     -> allowed = false
                                           reason  = "Esta mejora dejaria al planeta sin produccion
                                                      de energia suficiente: … se detendria de forma permanente"
get_economic_sustainability_check(...)   -> allowed = false, reason_code = INSUFFICIENT_ENERGY_SUSTAINABILITY
```

El jugador **ya** recibe veredicto y motivo antes de actuar. Lo que el contrato añade son cifras de
contexto (energía antes/después, `production_factor_after`) y `recovery_available`: **más
información**, no una capacidad ausente. La misión prohíbe expresamente mover cosas por estética
arquitectónica. `NO GAP`.

### 2.2 Planetas con producción detenida por déficit energético (2 en LIVE) — **NO GAP**

LIVE tiene 2 cuerpos con `energy_production = 0` y consumo > 0 (incluido el `Homeworld` del jugador
auténtico: las tres `*_per_hour = 0`, `energy_production = 0`, `energy_consumption = 24.2`).
Sospecha inicial: "el jugador ve `+0/h` y no entiende por qué".

**Por qué no es gap:** el estado **sí** está representado, con todos sus operandos y con la salida
visible en el mismo panel del Overview:

```text
METAL / CRISTAL / DEUTERIO   · +0/h
ENERGÍA                     · -24.2/h
ENERGÍA PROD/CONS           +0 / -24.2
```

y la recuperación está disponible y autorizada: `can_start_building(…,'solar_plant') -> allowed=true`,
`get_economic_sustainability_check(…,'solar_plant') -> allowed=true, recovery_available=true`.
Información de diagnóstico **y** acción de reparación, ambas visibles. `NO GAP`.
### 2.3 Cobertura del guard de sostenibilidad — **CORRECTA, NO GAP**

`building_energy_definitions` tiene exactamente 4 filas: `metal_mine`, `crystal_mine`,
`deuterium_synthesizer` (consumo) y `solar_plant` (producción). Ni naves ni defensas consumen energía,
así que que `evaluate_economic_sustainability` se invoque **solo** desde `start_building` es
correcto, no una omisión. `NO GAP`.

### 2.4 Humo de los contratos economicos como su dueño real — **TODO OK**

Ejecutados con `request.jwt.claims` del jugador autenticado, dentro de `BEGIN … ROLLBACK`:
`get_planet_economy_overview`, `get_planet_building_preview`, `get_planet_crawler_status`,
`get_current_planet_resources`, `get_planet_economic_rates_snapshot`, `calculate_planet_energy_balance`,
`calculate_planet_storage`, `sync_current_planet_resources` → **8/8 sin error**.
(`calculate_planet_production_snapshot`, `calculate_virtual_production` y `calculate_universe_rates`
exigen argumentos de tasa explícitos: los primeros intentos fallaron por **firma equivocada en el
probe**, no por defecto del producto.) `NO GAP` — el criterio E no se activa.

### 2.5 Cálculo en el frontend — **NO GAP**

`formatRate` y `formatStorage` sólo **comparan y formatean valores que ya devuelve el servidor**
(`economy.metal_per_hour`, `economy.metal_capacity`, …). No derivan ninguna regla autoritativa.
`NO GAP` — el criterio B no se activa.

### 2.6 Estado de los datos en LIVE — **SIN ANOMALÍAS**

```text
negative_stocks        0        overdue_buildings   0
metal_at_cap           1        overdue_research    0
energy_throttled       0        overdue_defense     0
energy_starved         2        overdue_shipyard    0
```

Los 2 `energy_starved` son los de §2.2 (ya representables). El `metal_at_cap` es el caso que el
panel ya marca como `ALMACÉN LLENO`. Ninguna cola vencida ⇒ nada que el worker no liquiere.

## 3. Decisiones de producto registradas (NO implementadas)

```text
DECISION REQUIRED — crawler overload 0-150 %
  Question:   ¿ Existe un overload configurable de crawler, y con qué límites?
  Evidence:   information_schema.columns -> 0 columnas con '%overload%' en todo el schema public.
              El sistema ya está cerrado y verificado: get_planet_crawler_status expone
              crawler_count / crawler_cap / crawler_effective / crawler_bonus_percent / crawler_energy_per_hour.
  Interpret.: (a) el overload no existe en LGI y no debe añadirse; (b) existe con slider 0-150 %.
  Afecta:    fórmula de crawler, contrato de estado, UI.
  Stopped:   no se inventa ni slider ni columna ni fórmula.

DECISION REQUIRED — demolition refund + política ion-technology
  Question:   ¿ Qué se reembolsa al demoler, y qué penaliza o nivela el coste en ion-technology?
  Evidence:   start_demolition.prosrc no menciona 'refund' (0 coincidencias). El guard de ranuras
              del silo (D2) ya está implementado y verificado; lo NO decidido es el reembolso.
  Interpret.: sin decisión humana, cualquier porcentaje sería inventado.
  Afecta:    start_demolition, saldo de recursos del jugador.
  Stopped:   diferido por instrucción explícita de la misión.
```

## 4. Fuera de alcance

* **Missile System** — `CLOSED — BACKEND / LIVE VERIFIED`. No se ha tocado.
* **Certificación browser de flotas** — `ENVIRONMENT BLOCKED` (sin credenciales DEV). No simulada.
* **Ledger de migraciones** — drift conocido y documentado; `supabase db push` prohibido.
* **Gaps ya cerrados** (espionage gating, P3 ACL, AI protection, missile, fleet slots/recall,
  counter-espionage, messaging, ranking refresh, cancelación de colas, merchant, read contracts de
  economía, debris visibility) — no reabiertos.

## 5. Nota de sync gate

`origin/main` avanzó 2 commits durante la ventana previa a este barrido
(`0dbebe3 docs: close missile system and define economy gap sweep`). **Colisión** en
`docs/PROJECT_CONTEXT_PROMPT.md`, cuyo contenido remoto también cierra el Missile System (redactado
distinto, compatible en sustancia). **No se integró**: `pull`/`merge` están prohibidos y el trabajo
local no se toca. Debe reconciliarse con `REMOTE + LOCAL -> RECONCILIATION` antes de integrar.


> Contraste con el precedente cerrado (§"Resource-panel honesty", B): allí el tope de almacén **no se
> mostraba junto al stock**, así que una mina parada era indistinguible de una a medias. Aquí la
> energía **sí** se muestra junto a la producción. El precedente no aplica. `NO GAP`.
