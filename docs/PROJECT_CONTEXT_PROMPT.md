# CURRENT CANONICAL STATUS — 2026-10-04 (supersedes older status snapshots below)

This compact block is the current operational truth for session recovery. Older dated sections are retained as history; when they conflict with this block or the linked specialist documents, this block and the latest specialist closure records take precedence.

## Recently closed gameplay systems

- **Missile System:** CLOSED — backend, D1 and LIVE verified. Browser re-certification was not run in the closure session. Migration-ledger drift remains documented; never use db push as a repair.
- **Crawler overload:** CLOSED — configurable 0–150%, default 100%, server-owned validation and LIVE verification.
- **Demolition / Ion:** CLOSED — existing removed-level cost and 4% per Ion level reduction verified; no rewrite required.
- **Queue expiry:** CLOSED — expiry resolves to COMPLETED, not CANCELLED.
- **Queue retention:** CLOSED — RETAIN terminal rows indefinitely; no purge. Revisit only with a queue-history feature or measured growth.
- **Fleet slot cap:** CLOSED — 1 + Computer Technology, enforced player-wide in the database with player-row serialization. OGameX premium/Officer bonuses are not imported.
- **Fleet browser certification:** CLOSED for the explicitly tested ATTACK pipeline — 9/9 browser steps, real-time dispatch/arrival/combat/return, ownership and cleanup, residue 0. This is not certification of every mission type.
- **Dark Matter premium economy:** DEFERRED to a future update. Do not add premium slots, Officers, Commander bonuses or DM spending without a later product decision.

Durable evidence:
- [Economy system](systems/README_ECONOMY.md) — crawler overload, queue expiry/retention and demolition/Ion closure.
- [Fleet engine](systems/README_FLEET_ENGINE.md) — player slot cap and narrow-scope browser E2E certification.
- [Missile system](systems/README_MISSILE_SYSTEM.md) — canonical D1, authoritative lifecycle, fixture repairs and verification caveats.

## Backend / ACL closure — 2026-10-04

- **`provision_player` ACL regression: CLOSED (LIVE).** Root cause: the `grant execute ... to authenticated`
  declared in `20260921073405` and `20260926296000` targeted the OLD two-argument overload
  `provision_player(text, text)`. Onboarding work replaced it with the four-argument version, whose
  `CREATE OR REPLACE` carries no GRANT of its own; the old overload was dropped out-of-band and took
  its ACL with it. The privilege was orphaned onto a signature that no longer existed.
  Proof, not inference: a real `authenticated` session calling `supabase.rpc('provision_player')`
  returned `HTTP 403 / SQLSTATE 42501 "permission denied for function provision_player"`. Because the
  privilege check precedes the function body, nothing was created.
  Corrective migration `20261004120000_restore_authenticated_execute_provision_player`: exactly one
  `GRANT EXECUTE ON FUNCTION public.provision_player(text, text, text, text) TO authenticated`,
  plus a post-condition block asserting the grant was restored AND that `anon`/`PUBLIC` stayed closed.
  Final LIVE ACL: `public=FALSE · anon=FALSE · authenticated=TRUE · service_role=TRUE`.
  Function body verified byte-identical across the change (`md5(prosrc)` unchanged,
  4165 bytes); owner `postgres`, `SECURITY DEFINER`, `search_path=''`, single overload.
  Regression: `supabase/tests/wrong_client_invoker_helpers.sql` test 9 moved from 52 contracts /
  51 with the grant (FAIL) to **52 / 52 (PASS)** — the repo's existing battery already covered this.
  Safe to grant because identity is never a parameter: `v_user_id := auth.uid()` with
  `AUTHENTICATION_REQUIRED` when null, so an authenticated caller cannot provision for another
  identity, claim a foreign planet, choose the universe or escalate; reuse-first plus
  `pg_advisory_xact_lock` already prevent replay and concurrent double provisioning.
  Functional onboarding E2E is **BLOCKED**, not skipped: this project requires email confirmation,
  so no session can be minted for a throwaway identity without the Admin API.
- **Migration ledger — reconciled 2026-10-04.** An earlier snapshot of this file recorded
  `20261004010000`, `20261004020000` and `20261004030000` as "absent from the LIVE ledger". That was
  **wrong**, and is corrected here rather than deleted, because the misreading is worth keeping visible:
  all three WERE registered in LIVE under tool-generated versions, with identical migration names.
  The local filename timestamp is not the applied version. Verified against
  `supabase_migrations.schema_migrations`:

  ```text
  local file                                          -> LIVE ledger version / name
  20261004010000_fleet_slot_player_lock.sql           -> 20261003221411  fleet_slot_player_lock
  20261004020000_player_country_code.sql              -> 20261003225843  player_country_code
  20261003232139_onboarding_planet_name_avatar.sql    -> 20261003232139  onboarding_planet_name_avatar
  20261004120000_restore_authenticated_execute_...sql -> 20261004013503  restore_authenticated_execute_provision_player
  ```

  All four effects were verified present in LIVE object by object (columns, function bodies, lock
  scope, ACL). Nothing was missing and nothing needed re-applying.

  **One real repo defect was found and fixed.** `20261004030000_onboarding_planet_name_avatar.sql`
  had 13 orphaned lines after its `COMMIT;` holding the `v_pname` / `v_avatar` assignments, leaving
  the local function body declaring but never assigning them. The file also carried a design header
  absent from the applied payload. It was replaced by the byte-exact ledger payload and renamed to
  the real applied version `20261003232139`, so a future `db push` can no longer attempt the broken
  file (it would have failed with a syntax error). The removed design rationale is preserved in
  git history at commit `2550b7a`.

  `supabase db push` and `migration repair` remain PROHIBITED and were never run.
## Recent frontend work — local implementation reports, not deployed

The following two implementation reports were supplied for the 2026-10-03/04 local work. They explicitly state that the product changes were not committed/pushed or deployed in those sessions. The documentation has been segregated here, but **the documentation commits do not publish the corresponding product code**.

- **Onboarding/profile:** optional planet name (32 chars, empty → Homeworld), 12 procedural SVG avatars, es/en/ru preference with country fallback and localStorage precedence, login/onboarding translations, email-link localhost correction and removal of obsolete provision_player overload. About 180 gameplay strings remained Spanish-only; do not claim full-game i18n. Supabase Auth Site URL correction and deployment were still manual/pending in the report.
  Detail: [Onboarding and profile](systems/README_ONBOARDING_PROFILE.md).
- **Responsive shell/navigation:** .neo-nav vertical flex layout on desktop, intentional horizontal navigation at ≤760px, separated brand/player labels, removal of dead shell CSS, and a geometry assertion with a negative control. The headless fixture was not a full authenticated app session. The report explicitly says no deployment occurred.
  Detail: [Responsive layout](ui/README_RESPONSIVE_LAYOUT.md).

Do not mark either frontend change as deployed until the actual product files are present in the target branch, the Supabase Auth Site URL is checked where relevant, and the Worker is deployed and verified.

## Current scope guardrails

- Lifeforms remain deferred/out of scope.
- Dark Matter premium economy remains deferred.
- Do not reopen any CLOSED item without new regression evidence or an explicit human decision.
- OGameX is a reference, not authority. Adapt only compatible behavior; do not import absent class/Officer systems or invent balance.
- Distinguish implementation, LIVE verification, browser certification and deployment; one does not imply another.
- Keep this file as the operational index. Durable formulas, contracts, tests, caveats and evidence belong in the linked specialized READMEs.

---

<!-- A partir de aqui: corpus documental local consolidado 2026-09/10. -->
<!-- Se conserva integro. El bloque canonico de arriba tiene precedencia -->
<!-- sobre cualquier instantanea historica que lo contradiga. -->

# PROJECT CONTEXT — LA GRAN IMPLOSIÓN

> **Purpose:** compact operational memory for safe session recovery.
>
> This document is the operational control panel, not an encyclopedia. Durable technical detail belongs in
> the specialized documents linked below.


## GAMEPLAY GAP STATUS — CANONICAL (2026-10-03)

> **Este bloque es el ÍNDICE AUTORITATIVO del estado de gameplay.** Si cualquier sección más abajo
> de este documento contrasta con él — en particular si marca algo CLOSED como pendiente, o la
> certificación de navegador como bloqueada — **manda este bloque** y la sección afectada es
> HISTÓRICA. No se borra historia: se marca.

```text
GAMEPLAY GAP STATUS
===================

OGameX final gap check:      16/16 areas CLOSED · REAL GAPS: 0
Economy:                     CLOSED
Missile System:              CLOSED — backend + LIVE verified
Crawler overload:            CLOSED — default 100 %, maximum 150 %
Demolition / Ion:            CLOSED
Queue expiry:                CLOSED
Fleet browser:               CLOSED — 9/9 browser · E2E PASS · ownership PASS
                                      · cleanup PASS · residue 0
Fleet slot cap:              CLOSED — max = 1 + computer_technology, server-enforced,
                                      now serialised per player (concurrency fixed)

Environment blocker:         RESOLVED
```

### Alcance EXACTO de la certificación de navegador de flotas

```text
Fleet pipeline E2E = CLOSED
  ATTACK mission = browser E2E certified     worker = certified
  arrival = certified                        resolution = certified
  return = certified                         accounting = certified
  ownership = certified                      cleanup = certified
  residue = 0
```

**Lo que NO se certificó** (y no debe afirmarse): *todos* los tipos de misión de flota.
La certificación cubre **una** misión `ATTACK` real, contra un objetivo **sin combate**, por el
**pipeline completo en tiempo real**. No se inventaron combates ni destinos adicionales para
alargar la prueba. Detalle: `docs/audits/FLEET_BROWSER_CERTIFICATION_2026-10-03.md`.

### Cualquier texto «ENVIRONMENT BLOCKED» sobre el navegador de flotas es HISTÓRICO

Varias secciones anteriores de este documento (y algunos informes previos) dicen que el navegador de
flotas estaba bloqueado por falta de credenciales DEV o por falta de driver. **Eso ya no es cierto**:

```text
DEV credentials disponibles · navegador disponible (Edge) · login real PASS
9/9 PASS · E2E PASS · ownership PASS · cleanup PASS · residue 0
```

**No vuelvas a asumir que faltan las credenciales.** Se leen en tiempo de ejecución de
`credentials.txt` (fichero local, ahora en `.gitignore`) y se pasan por `DEV_EMAIL` /
`DEV_PASSWORD`. El harness acepta `CERTIFY_MAX_STEP` para correr sólo la parte diagnóstica sin
mutar datos; los pasos omitidos **no** cuentan como PASS y la corrida parcial devuelve exit 3.

### PRODUCT DECISION REQUIRED ≠ TECHNICAL GAP

Queda **una** decisión humana pendiente. NO es un gap técnico, NO está rota y **no debe
implementarse** sin decisión explícita:

```text
1. Dark Matter / premium economy   — modelo de negocio, no fallo técnico (update posterior)
```

> **Queue terminal purge / retention: ya NO está pendiente.** Se midió y se cerró como `RETAIN`
> el 2026-10-03: sin consumidor, sin dependientes, sin acumulación (0 filas creadas en 14 días) y
> con índices completos; además son el ÚNICO historial de construcción/investigación que existe.
> No hay regla de purga de colas ni en OGameX ni en LGI, así que cualquier plazo habría sido
> inventado. Ver §"QUEUE RETENTION" más abajo.

> El **tope de slots de flota** estuvo aquí durante meses como "product decision". **Ya no**:
> la política estaba decidida (`1 + computer_technology`) y aplicada; lo que faltaba era la
> serialización por jugador. Cerrado el 2026-10-03 → ver §"Fleet slot cap" más abajo.

### ADVERTENCIA — el mapa OGameX/LGI antiguo contiene falsos `MISSING`

`docs/reference/README_OGAMEX_LGI_MAP.md` es de **2026-09-25** y describe un estado ya superado.
Estos sistemas estaban marcados como ausentes y hoy están **implementados y cerrados**:

```text
Missile System · Moon destruction · Demolition + Ion · recall_fleet
wreck/message cleanup · Crawler overload
```

> **DO NOT TRUST THE OLD OGameX/LGI GAP MAP AS CURRENT STATE.**
> La evidencia LIVE actual tiene prioridad sobre cualquier mapa histórico.

### Estado canónico por misión (detalle durable en el README especializado)

```text
OGameX final gap check   docs/audits/OGAMEX_FINAL_GAP_CHECK_2026-10-03.md
Economy gap sweep        docs/audits/ECONOMY_GAP_SWEEP_2026-10-02.md
Missile System            docs/systems/README_MISSILE_SYSTEM.md §18
Fleet browser            docs/audits/FLEET_BROWSER_CERTIFICATION_2026-10-03.md
```

### REMOTE INFORMATION TO RECONCILE — `origin/main` `0dbebe3` (NO integrado)

Colisión conocida en este mismo fichero. **No se ha integrado**: `pull`/`merge` están prohibidos y el
trabajo local no se toca. El commit remoto **borra 1283 líneas** de este documento; hacerlo
automáticamente destruiría historia local que aún no está en remoto.

| | LOCAL (working tree) | REMOTE `0dbebe3` |
|---|---|---|
| Missile System | CLOSED — backend + LIVE verified (§18, detalle) | CLOSED — mismo fondo, **redacción distinta** |
| Nota de fixtures inválidos | presente | presente (coincide) |
| Economy gap sweep | **hecho: CLOSED** | "próxima misión candidata" → **caducado** |
| Crawler / demolition / queue expiry | **hechos y CLOSED** | no mencionado |
| Fleet browser | **CLOSED 9/9 + E2E + residue 0** | "environment-blocked; no driver + human DEV credential" → **FALSO hoy** |

**Antes de integrar hay que reconciliar a mano.** Lo que aporta remoto y aún no está local, en
sustancia: la redacción propia de su cierre de misiles y su lista de "no reabrir" — compatible con
nuestro §18, no contradictorio. Lo que **no** debe adoptarse sin corregir: la afirmación de que el
navegador sigue bloqueado y que el sweep de economía está pendiente.


## MANDATORY SYNC GATE

Before any new Cline/Copilot implementation mission, verify LOCAL ↔ \`origin/main\` first. The gate must record branch, local HEAD, remote HEAD, merge-base, ahead/behind, staged/unstaged/untracked/deleted files, stashes and relevant divergences. If local work is not understood or the trees diverge, stop implementation and protect the work first. Do not automatically pull, merge, rebase, reset, clean, checkout, stash-pop/drop, commit or push. For backend/migration/RPC/RLS work, also verify Supabase LIVE and consult the cloud reconciliation record: [\`docs/audits/CLOUD_STATE_RECONCILIATION_2026-09-28.md\`](audits/CLOUD_STATE_RECONCILIATION_2026-09-28.md).

**The physical local working tree is the only source of truth for local state.** ChatGPT memory, this document,
GitHub and previous agent reports are context, never proof. Never assume the trees are synchronized and never
perform a blind pull. Re-state this gate verbatim in EVERY new Cline/Copilot agent prompt, and re-run it at the
start of every session — a clean gate in a previous session says nothing about the current one.

```text
MANDATORY SYNC GATE (repeat verbatim in every agent prompt)

LOCAL ↔ origin/main
        ↓
comprobar el estado real  (nunca confiar en la memoria)
        ↓
identificar el trabajo local (modified / untracked / stashes)
        ↓
identificar los commits remotos  (git log HEAD..origin/main)
        ↓
detectar el solapamiento  (remote-only / local-only / shared files)
        ↓
proteger el trabajo  (parche verificable + copia de los untracked)
        ↓
solo entonces diseñar y ejecutar la misión
```

Non-negotiable consequences of the gate:

1. **Never overwrite local work to make a pull succeed.** Reconciliate: `REMOTE change + LOCAL change →
   RECONCILIATION`. If both facts are compatible, keep both. If they genuinely contradict, STOP and REPORT —
   never invent a resolution.
2. **Untracked files are protected work.** Identify them explicitly and check none collides with a path
   \`origin/main\` is about to add, before any integration step.
3. **A dirty working tree can be correct.** The goal is never a clean tree at any price; it is
   \`LOCAL preserved + origin/main integrated safely + no lost or duplicated work\`.
4. **A clean tree is not a reconciliation.** Do not mark anything CLOSED merely because Git reports no conflict.
5. **Backend work adds a third authority.** Repository, Supabase LIVE and this document can disagree; a
   migration may not be renamed, deleted or invented to make a ledger look tidy. Detect and report the drift.
6. **If local work cannot be proven preserved, STOP** and do not continue into gameplay.

## CLOUD RECONCILIATION OVERRIDE — 2026-09-28

`docs/audits/CLOUD_STATE_RECONCILIATION_2026-09-28.md` is authoritative for the latest LIVE state.

- GitHub `main` includes UI Designer via PR #5.
- Guest ownership/RLS hardening is **CLOSED LIVE as of 2026-09-28**.
- LIVE applied the guest RLS migration as version `20260928021418` and the live-shape ownership reconciliation as version `20260928021509`.
- Final LIVE catalog check: **0** public functions still reference `is_guest`, excluding only `register_guest_player` and `reconcile_universe_ai_population`.
- The historical `20260920120800_remove_guest_ownership_bypasses.sql` is superseded because its precondition did not match LIVE `start_colonize_fleet()`; do not replay it.
- The repository now carries migration files matching the actual LIVE versions.
- Historical migration provenance drift remains documented separately; do not infer absence of functionality solely from a missing historical version prefix.

## 1. Project mission

La Gran Implosión is an OGame-like browser game with a React/TypeScript/Vite frontend, a Cloudflare Worker
boundary and Supabase/PostgreSQL as the authoritative game backend. The project keeps its own mechanics,
architecture and universe-evolution model. OGameX is a reference library, never a dependency or authority.

```text
src/       presentation and client integration
worker/    Cloudflare HTTP and asset boundary
supabase/  authoritative game engine, schema and migrations
```

## 2. Source of truth

```text
LIVE SUPABASE STATE / DEFINITIONS
        ↓
CURRENT GITHUB CODE + CHECKED-IN MIGRATIONS
        ↓
SPECIALIZED DOCUMENTATION / LIVING MONITORS
        ↓
docs/PROJECT_CONTEXT_PROMPT.md
        ↓
OGAMEX REFERENCE / OLD SESSION ASSUMPTIONS
```

The canonical identity chain is:

```text
auth.uid() → players.user_id → players.id → owned active planet → universe
```

Ownership checks are mandatory. Do not infer an active planet from global “first planet” heuristics or trust
client-provided player identity without backend authorization.

## 3. Architecture and terminology

Validated layer order:

```text
BASIC GAME ENGINE → TEMPORAL LAYER → UNIVERSE EVOLUTION
```

Canonical fleet terms:

- **PEACEFUL:** `TRANSPORT`, `DEPLOY`, `COLONIZE`, `EXPEDITION`
- **WAR:** `ATTACK`, `ESPIONAGE`, `RECYCLE`
- **HOLDING:** `ACS_HOLD`, `HOLDING`, `DEFEND`
- **Canonical fleet pipeline:** `calculate_player_ship_speed` → `calculate_mission_fleet_speed_multiplier`
  → evolution `E^(1/3)` → mission/item/lifeform modifiers → `calculate_fleet_travel_time`
  → `calculate_player_fleet_fuel_for_distance`
- `calculate_mission_fleet_speed_multiplier()` is an internal backend helper, not a public API.
- Supabase functions/RPCs are authoritative for speed, fuel, cargo, prerequisites and movement state.

Detailed fleet rules, mission matrix, modifier order, propulsion routing, fuel semantics and lifecycle:
[`docs/systems/README_FLEET_ENGINE.md`](systems/README_FLEET_ENGINE.md).

## GAMEPLAY COMPLETION SWEEP (2026-09-26) — index and current state

Implementation mission (not an audit). LIVE migrations `20260926120000` … `20260926124035`; the map and the domain
READMEs below hold the durable detail. Nothing was committed or pushed.

```text
IMPLEMENTED + TESTED (LIVE, rolled back, zero residue)
  fleet slots          1 + computer_technology ENFORCED server-side on every dispatch path (BEFORE INSERT guard on
                       fleet_movements).  tests/fleet_slots_enforcement.sql 6 PASS
  fleet recall         recall_fleet(): owner-gated, atomic, mirror return leg, cargo preserved, replay-safe.
                       tests/fleet_recall.sql 7 PASS
  counter-espionage    OGameX chance formula + real battle of the probes against the target's SHIPS through the
                       existing Combat Engine, losses written back, debris at the target, reveal gating,
                       defender notified, report written even when every probe dies.
                       tests/counter_espionage.sql 13 PASS
  messaging            every gameplay event produces a message (fleet arrival/return/holding, combat, attack
                       received, expedition outcome, colony founded, debris harvested, espionage, counter-
                       espionage). Replay-safe via a dedupe key; never blocks the engine.
                       docs/systems/README_MESSAGING_ENGINE.md
  ranking refresh      run_ranking_worker() + pg_cron 'lagranimplosion-ranking-refresh' every 5 minutes (OGameX
                       cadence). tests/ranking_refresh_worker.sql 6 PASS
  UI (basic)           src/GameplayEnginePanel.tsx: fleet slots + recall, inbox + mark-as-read, espionage reports,
                       ranking top 10. No authority in the client.
  MOONS                accepted model 2026-09-26: planets.kind + parent_planet_id, partial unique coordinate
                       indexes, creation from battle debris (OGameX chance + diameter), lunar base field capacity,
                       building kind/research gating, sensor phalanx, jump gate, moon destruction.
                       tests/moon_engine.sql 13 PASS · tests/moon_services.sql 11 PASS
                       RE-VERIFIED 2026-09-28 (LIVE, ROLLBACK, residuo 0): moon_engine 13 PASS · moon_services 11 PASS ·
                       moon_destruction_mission 6/6 el 2026-09-28.
                       D6 CLOSED 2026-09-28: la destrucción lunar ya no se descarta cuando la luna sobrevive y se pierden
                       todos los deathstars (LIVE `20260928121226` + fixture nuevo fleet_ship_loss_quantity_check 8 PASS).
                       docs/systems/README_MOON_ENGINE.md
  verified live        ACS settlement PG-08/09/10 was already implemented by the previous block; untouched here.

STILL OPEN (evidence recorded, ready to implement)
  fusion plant         CLOSED 2026-09-26 — implemented (20260926140000/…40200) and re-certified LIVE 10/10 on 2026-09-29. The "STILL OPEN" note below was STALE.
  crawler              CLOSED 2026-09-26 — implemented and re-certified LIVE 10/10 on 2026-09-29; on that date its cap / effective / bonus became VISIBLE to the player via get_planet_crawler_status.
  AI behaviour         CLOSED — service-role actor contract + full gameplay policy (see the AI GAMEPLAY
                       BEHAVIOUR section at the end of this document).
  demolition           refund / ion-technology policy not determined with certainty → not invented.
  moon polishing       see docs/systems/README_MOON_ENGINE.md §9 (dedicated destruction mission, phalanx departures,
                       moon UI panel, defence kind gate, wreck field).

## NANITE FACTORY + CRAWLER ENERGY BALANCE — CLOSED 2026-09-30 (Q1–Q15)

Misión de cierre de gaps decididos, con auditoría previa obligatoria. Detalle completo en
`docs/audits/GAP_CLOSURE_2026-09-30.md`.

```text
  IMPLEMENTADO
    nanite factory   Q5/Q6 · 20260930210000_nanite_factory.sql
                     OGameX StationObjects: id 15, 1 000 000 / 500 000 / 100 000, factor 2, PLANET only,
                     requisitos computer_technology 10 + robot_factory 10.
                     Regla única calculate_nanite_factory_build_speed(planet) = 2^nivel, plegada en la
                     MISMA tasa efectiva del Robot Factory: edificios, naves Y defensas.
                     La investigación NO se toca: getTechnologyResearchTime upstream no tiene término
                     nanite, y la migración aborta si alguna vez lo tuviera.
                     La divergencia LGI (upstream no aplica 1+robot a las unidades) se PRESERVA: el 2^nivel
                     se compone con ella; revertirla reabriría la decisión cerrada del Robot Factory.
    crawler balance  Q13 · 20260930211000_crawler_energy_balance.sql
                     BUG CORREGIDO: calculate_planet_energy_balance sumaba sólo building_energy_definitions,
                     así que la UI mostraba el mismo consumo con 0 crawlers que con 40 mientras la producción
                     estaba estrangulada por 2 000 energía/h. Ahora ambos caminos usan el helper único
                     calculate_crawler_energy_consumption(planet). La producción conserva exactamente su
                     valor anterior. Q1 INTACTA: sólo los crawlers efectivos consumen.
    missile system   §5 GAMEPLAY_GAP + D1-D5 cerradas · 18 migraciones (ledger 20260930074024..20260930075958)
                      **CLOSED — BACKEND / LIVE VERIFIED (2026-10-02).** Estado canónico y detalle durable:
                      docs/systems/README_MISSILE_SYSTEM.md §18. No reabrir sin regresion demostrada.
                      IMPLEMENTADO: Missile Silo (20000/20000/1000, factor 2, shipyard 1, PLANET+MOON),
                      ABM (8000/2000/0, silo 2 + shipyard 1, 1 ranura, casco 800) e
                      IPM (12500/2500/10000, silo 4 + shipyard 1 + impulse_drive 1, 2 ranuras, casco 1500).
                      Capacidad 10/nivel; ranura ABM 1 · IPM 2, contando tambien lo encolado.
                      MISSILE_ATTACK propio (NO es ATTACK): alcance (impulse*5)-1, vuelo
                      (30+60*distancia)/velocidad_universo sin pipeline de naves ni combustible, y sin viaje
                      de vuelta. Intercepción 1:1 con el ABM del PLANETA PADRE primero. Prioridad de
                      destrucción con el algoritmo OGameX verificado. ABM/IPM EXCLUIDOS del combate normal
                      en las tres superficies (informe, estado de combate y reparacion).
                      D1 ABM/IPM 60 s: unica divergencia deliberada de balance. D2 el guard de demolicion
                      bloquea si el silo quedaria por debajo de los ranuras ocupadas. D5 reutiliza
                      get_combat_defense_hull, que YA es (casco/10)*(1+0.1*armour): no hay formula paralela.
                      CUATRO BUGS ENCONTRADOS POR LA FIXTURE, todos corregidos: el IPM no puede ir en
                      fleet_movement_ships (FK a ship_definitions) => columna missile_count propia;
                      format() no tiene %d; con 0 ABM el conteo escalar dejaba NULL y LEAST ignoraba NULL,
                      de modo que todo el IPM salia interceptado y ninguna defensa recibia dano; y el
                      guard D2 quedaba enmascarado por INSUFFICIENT_RESOURCES.
                      Detalle y estado por caso: docs/systems/README_MISSILE_SYSTEM.md.
                      Fixture: supabase/tests/missile_system.sql.
                      NOTA: los ficheros locales 2026093022*/2026093023* son BORRADORES superseded;
                      la version aplicada vive en el ledger (mismo drift que el resto de la tanda, sin reparar).

  MISSILE SYSTEM — CLOSED (canónico, 2026-10-02; detalle durable en README_MISSILE_SYSTEM.md §18)
    Backend            LIVE verified end-to-end. Esta misión NO añadió código de producto.
    D1                 60 s silo / time_factor 2 · 60 s ABM · 60 s IPM. Contrastado contra el catálogo
                       LIVE. No reabrir salvo decisión humana explícita.
    Launch             start_missile_attack (auth.uid() → players.user_id → ownership → FOR UPDATE).
    Arrival            resolve_missile_attack_arrival (idempotente por status COMPLETED/CANCELLED).
    Movement           process_fleet_movements — el worker existente, sin segundo motor.
    Destruction        cheapest → metal+crystal ASC → defense_id ASC (determinista, D4).
    Tests              fixtures CORREGIDAS y ejecutadas de verdad en LIVE: ui_surface 5/5,
                       target_priority 13/13, missile_system catálogo+capacidad 31 PASS/0 FAIL,
                       rango/vuelo/prioridad 26 PASS/0 FAIL, combate/idempotencia/seguridad PASS/0 FAIL.
                       Residuo LIVE = 0. Los fallos iniciales eran defecto de FIXTURE, no de producto.
    Static             tsc/build/contracts/diff-check PASS; lint 0 errors (7 warnings preexistentes).
    Browser            NO re-certificado en esta corrida. El PASS 11/11 histórico es de 2026-09-30.
    Ledger drift       documentado; `supabase db push` prohibido. Fuera del cierre funcional.

  AUDITADO SIN CAMBIAR
    Q7 shipyard→robot_factory 2   NO aplicado: el prerrequisito es POR CUERPO y robot_factory es
                                  PLANET-only ⇒ la fila prohíbe el hangar en las LUNAS. Ya era decisión de
                                  producto (tests/robot_factory.sql:218).
    Q8 recálculo de colas          INFO / RESEARCH REQUIRED: LGI fija finishes_at absoluto al encolar; el
                                  clásico acorta el resto del trabajo ya en cola.
    Q12 space_dock→shipyard 2     NO aplicado: el Space Dock es una mecánica LGI definida y CLOSED.
    Q9 tiempos base de naves      AUDITADO, no convertido: upstream usa (metal+cristal)/2500; LGI usa
                                  base_build_time_seconds. Convertirlo cambiaría las 17 naves ~70x.
    Q10 fuel del satélite         AUDITADO: 0 vs 1 upstream NO tiene efecto (velocidad 0 corta el despacho
                                  antes de calcular combustible). Divergencia deliberada y documentada.

  ~~ESPECIFICADO, NO IMPLEMENTADO~~ — RESUELTO, VER §5 MISSILE SYSTEM (CLOSED)
    Missile Silo + ABM + IPM (Q2/Q3/Q4) estaba aquí como "NO implementado" exigiendo un NUEVO tipo de
    misión. **Superado**: `MISSILE_ATTACK` está implementado y verificado en LIVE (2026-10-02), sin tocar
    el settlement de combate cerrado. Estado canónico: `CLOSED — BACKEND / LIVE VERIFIED`.

  Q14 LEDGER    sólo diagnóstico, NO reparado (4 migraciones con versión de ledger ≠ nombre de fichero;
                 comprobado que no hay doble aplicación).
  TESTS         tests/nanite_and_crawler_balance.sql 13 PASS / 0 FAIL (ROLLBACK) · fusion_and_crawler 10/10
                 con ratios de crawler idénticos · tsc 0 · eslint 0 errores · cert:contracts PASS ·
                 diff --check 0 · buildings 16 / ships 17 / defenses 8
  SEGURIDAD     ambos helpers de sólo lectura, SECURITY INVOKER, search_path fijo; el de crawlers es
                 service_role only. Ningún RPC de escritura nuevo.
  RESIDUO       0 planetas de prueba · 692 jugadores · 692 planetas
```

## PLANET TEMPERATURE SYSTEM — CLOSED 2026-09-30

LIVE migrations `20260930160000` + `20260930161000` (aplicadas en LIVE con las versiones de ledger
`20260930041846` y `20260930041918`; drift de ledger detectado y NO reparado — ver
`docs/audits/PLANET_TEMPERATURE_SYSTEM_2026-09-30.md` §8). Cierra el único hueco real que dejó el gap sweep
del 2026-09-30 (`docs/audits/GAMEPLAY_GAP_SWEEP_2026-09-30.md` §3): el **satélite solar era una nave inerte**.

```text
  SOURCE (OGameX main, verificado hoy; NO la ruta obsoleta application/Settings/*)
    PlanetServiceFactory::planetData()      banda de temperatura por posición 1..15
    PR #514 (MERGED, cierra #513)           temp_min = temp_max − 40  ⇒ rango de 40° SIEMPRE
    PlanetService::getPlanetTempAvg()       (temp_min + temp_max)/2
    BuildingObjects.php:86                  10·L·1.1^L·(1.44 − 0.004·T_avg)   ← DEUTERIO
    CivilShipObjects.php:171                floor((T_max + 140)/6)·n          ← SATÉLITE
    GameObjectProduction::calculate()       calculateCrawlerProduction() va DESPUÉS de calculateMine()
                                            ⇒ el término crawler NO lleva el factor de temperatura
    tests/Unit/ResourceProductionTest       testDeuteriumProductionTemperatureDependency (16 vs 11)
    PlanetServiceFactory::setupMoonProperties() + Jobs/CreateLegorMoon.php
                                            la luna toma la temperatura de la POSICIÓN que orbita

  MODELO (una sola fuente de verdad)
    planets.position → planet_temperature_for_position(position)   [banda OGameX verbatim]
                     → planets.temperature_min / temperature_max  [instancia persistida]
                     → planet_temperature(planet)                  [persistido; si es NULL, el modelo]
                     → calculate_planet_production                 [único consumidor]
    Los 4 escritores de planetas usan el mismo helper. Ninguna fórmula duplicada en frontend/fixture/trigger.

  EFECTO ECONÓMICO DELIBERADO: el deuterio ahora escala con la temperatura (0.56 en pos 1 … 1.96 en pos 15).
  Metal, cristal, el balance de solar/fusión y los términos crawler NO cambian.

  INTENTIONAL LGI DIFFERENCE 1 — punto medio de la banda en vez del `rand(lo,hi)` de OGameX: una tirada
  aleatoria por fila no es auditable ni reproducible. La banda y el rango de 40° son de OGameX.
  INTENTIONAL LGI DIFFERENCE 2 — suelo 0 en los dos términos derivados de la temperatura (OGameX no lo
  necesita porque su temperatura siempre está en rango).

  BACKFILL  692 planetas, 692 NULL antes → 0 NULL · 0 desacuerdos con el modelo · 0 rangos ≠ 40. Idempotente.
  LIVE      tests/planet_temperature.sql 13 PASS + 1 INFO (ROLLBACK, residuo 0)
            tests/fusion_and_crawler.sql 10 PASS · tests/energy_technology_production.sql 7 PASS
            tests/plasma_technology_production.sql 12 PASS (su TEST 13 se actualizó: la línea base de
            deuterio ahora incluye el factor de temperatura)
  UI        fila TEMPERATURA en el panel de overview, leída de la fila `planets` (RLS del propietario);
            sin pantalla nueva y sin contrato nuevo.
  DOCS      docs/audits/PLANET_TEMPERATURE_SYSTEM_2026-09-30.md (registro de diferencias incluido)
```

## SOLAR SATELLITE END-TO-END — CLOSED 2026-09-30

`20260930200000_solar_satellite_combat_profile.sql`. El satélite **ya existía** y ya producía energía
(el sistema de temperatura del 2026-09-30 lo habilitó); esta misión lo auditó de extremo a extremo y
corrigió **un** valor de definición que ambas fuentes fijaban y LGI tenía mal.

```text
  AUDITADO (OGameX CivilShipObjects.php, main, hoy)
    precio 0/2000/500 · prerequisite ÚNICO shipyard 1 · sin valid_planet_types ⇒ planeta y luna
    perfil  SI 2000 · escudo 1 · ATAQUE 0 · velocidad 0 · carga 0 · combustible 1
    producción floor((T_max + 140)/6) · sin tope de cantidad · sin materia oscura
    GameObjectProperties no define tiempo propio: usa la fórmula compartida de nave

  NATURALEZA  una NAVE (A), construida en el hangar. NO es un edificio ni una instalación, aunque
              produzca energía. Se reutilizó el pipeline existente; ningún sistema paralelo.

  CORREGIDO   ship_definitions.solar_satellite.attack  1 → 0
              por qué: el perfil de LGI (ataque 1, escudo 1, vel 0, carga 0, comb 0) era idéntico al del
              CRAWLER salvo el casco = copiar-y-pegar del seed. Y get_combat_unit_snapshot() /
              initialize_combat_unit_state() leen sd.attack de TODAS las filas de planet_ships sin
              filtrar ship_type ⇒ un planeta con N satélites aportaba N de ataque a su defensa.

  NO TOCADO (documentado)   combustible 0 vs 1 de upstream: con velocidad 0 el despacho se corta
                            antes de calcular combustible, así que el valor no tiene camino alcanzable y
                            el valor clásico no pudo establecerse desde fuente primaria.
                            calculate_planet_energy_balance no refleja el consumo de crawlers
                            (preexistente, certificado así por fusion_and_crawler, no afecta al satélite).
                            getFlightShipAmount() de OGameX excluye el satélite pero NO tiene llamantes.

  CERTIFICADO LIVE (ROLLBACK, residuo 0)   tests/solar_satellite.sql 25 PASS + 3 INFO, 0 FAIL
    ciclo 0→1→10→11 con cobro exacto (2000/500 y 20000/5000), energía fantasma 0 mientras está en cola,
    worker idempotente, energía +31/+341 exactos, temperatura caliente +630 / frío +50, Energy Technology
    mueve el total pero no el término del satélite, Plasma no la toca, la fusión suma su propio término,
    la tasa del universo no escala energía, se construye y produce en luna, no puede volar
    (Ship speed must be greater than zero: 0), sin tope de cantidad, y 4 rechazos de ownership/IDOR/sesión.

  REGRESIÓN   fusion_and_crawler 10 PASS · tsc 0 · eslint 0 errores · cert:contracts PASS · diff --check 0
  DOCS        docs/audits/SOLAR_SATELLITE_AUDIT_2026-09-30.md
```

> **RESIDUO DE SESIÓN ANTERIOR ELIMINADO:** el barrido OGameX de la sesión previa había dejado 458 ficheros
> basura (`UsersMISSIN~1AppDataLocalTempogx*.php`, rutas de Windows mal interpretadas por `curl`) en la raíz
> del repo. Verificados como fuentes PHP de OGameX, ninguno del proyecto, y eliminados. Estado: 15 ficheros
> en la raíz, todos reales.

DOCUMENTS
  docs/reference/README_OGAMEX_LGI_MAP.md   status update section (supersedes the named rows)
  docs/systems/README_MESSAGING_ENGINE.md   NEW — producers, message set, replay safety, ACL, tests
  docs/systems/README_ESPIONAGE_ENGINE.md   §9 counter-espionage implemented
  docs/systems/README_RANKING.md            §9 scheduler wired + UI
  docs/systems/README_FLEET_ENGINE.md       §29 slots enforcement + recall + fixture prerequisite
```

Validation: `git diff --check` clean · `npx tsc -b` exit 0 · `npm run build` emitted worker + client bundles ·
LIVE migration history repaired to the repository file-name convention (10 rows) · no commit, no push.

## GAMEPLAY COMPLETION SWEEP II (2026-09-26) — index and current state

Second implementation pass (not an audit). LIVE migrations `20260926140000` … `20260926150100`. Nothing was committed
or pushed. Detail lives in the domain READMEs; this is the index.

```text
IMPLEMENTED + TESTED (LIVE, rolled back, zero residue)
  fusion plant      OGameX id 12: 900/360/180 (factor 1.8), deuterium_synthesizer 5 + energy_technology 3,
                    energy 30·L·(1.05+0.01·ET)^L and fuel burn 10·L·1.1^L expressed inside the authoritative
                    production rate (the raw settlement recovers the base per hour). Fuel policy: the reactor stops
                    without deuterium (official OGame rule; OGameX's own code would create free energy).
                    tests/fusion_and_crawler.sql 10 PASS
  crawler           OGameX id 217: 2 000/2 000/1 000, shipyard 4 + combustion_drive 4 + armour_technology 4 +
                    laser_technology 4, PLANET only; +0.02 % of mine output per effective unit, effective units
                    capped at (mines sum) × 8, energy 50 per effective unit. tests/fusion_and_crawler.sql 10 PASS
  kind authority    ONE server-side gate per family: building_definitions.valid_kinds (+ building_queue trigger) and
                    ship_definitions.valid_kinds (+ shipyard_queue trigger), aligned with OGameX valid_planet_types
                    (empty list = both kinds) → storages and the shipyard are now legal on moons, the crawler is
                    planet-only. Defences declare nothing in OGameX → none is moon-banned (verified).
  AI service actor  ai_actor_begin / is_ai_actor_target / ai_actor_end: an AI player can act through the SAME
                    authoritative dispatchers (construction, research, ships, defence, fleets, support, colonisation)
                    while every ownership gate stays closed for humans, anon, undeclared service calls and
                    cross-player declarations. tests/ai_service_actor.sql 9 PASS
                    docs/systems/README_AI_ENGINE.md
  moon polish       D2 phalanx outputs VERIFIED · D3 MoonsPanel UI IMPLEMENTED · D4 kind gate IMPLEMENTED ·
                    D1 dedicated destruction mission CLOSED 2026-09-26 (`20260926190000`) · D5 wreck field CLOSED
                    (`20260926230000`, backend-only, sin contrato de cliente)

STILL OPEN / DECISIONS
  AI behaviour policy   which action an AI picks and when (priority list, cadence, budget, reserve, attack policy) —
                        the execution contract is done, the policy is product. README_AI_ENGINE.md §4.
  wreck field           CLOSED 2026-09-26 (`20260926230000` + `20260926270000`): implemented BACKEND-ONLY (`space_dock`,
                        PLANET+MOON, 9/9 PASS); no client contract → not a UI gap.
  fusion research_lab   OGameX gates the fusion reactor behind a research laboratory; the laboratory now EXISTS
                        (20260926180000), so that gate is a data row. What remains open for fusion_plant is its
                        own energy/deuterium burn (see the fusion note below), not the laboratory.
  crawler overload      player-set 0–150 % overload does not exist in LGI (100 % assumed).
  moon destruction D6   CLOSED 2026-09-28 (LIVE `20260928121226`): a survived attempt that lost EVERY deathstar was
                        silently dropped (no attempt row, no messages, Deathstars kept). The same bug also blocked
                        expedition BLACK_HOLE. Both fixed by deleting exhausted stacks before subtracting.
                        tests/fleet_ship_loss_quantity_check.sql 8 PASS + 2 INFO.
                        See README_MOON_ENGINE.md §12.4 and README_FLEET_ENGINE.md §30.

DOCUMENTS
  docs/systems/README_ECONOMY.md        fusion + crawler integration, fuel policy, kind authority
  docs/systems/README_AI_ENGINE.md      NEW — the actor contract, tests, behaviour-policy decision, OGameX comparison
  docs/systems/README_MOON_ENGINE.md    §12 moon final verification, §12.4 D6 fixed and certified
  docs/systems/README_FLEET_ENGINE.md   §30 BLACK_HOLE stock loss fixed + certified
  docs/reference/README_OGAMEX_LGI_MAP.md   status update section for this sweep
```

Validation: `git diff --check` clean · `npx tsc -b` exit 0 · `npm run build` emitted worker + client · LIVE history
repaired to the repository file-name convention · no commit, no push.

## AUTONOMOUS GAMEPLAY GAP SWEEP (2026-09-27) — GAP A/B verified, dead ACL surface closed, sweep evidence

Cycle run: verify → find real gap → implement → test → certify → close → continue.

```text
GAP A — ESPIONAGE BUILDINGS/RESEARCH (authorised product decision): VERIFIED + CERTIFIED
  state      `20260927130000` is LIVE: `espionage_reports.buildings/research` + the four stored reveal flags;
             `resolve_espionage_arrival` carries the OGameX thresholds verbatim
             (buildings `remaining >= 5 or level - 3 >= defender`, research `7 / level - 4`);
             `get_player_espionage_reports` returns 27 columns including the four sections and the four outcomes.
  certified  fresh independent-derivation probe THIS mission (**6/6 PASS**, rolled back): 0 vs 2 with 4 probes ->
             nothing stored; 0 vs 2 with 6 probes -> ships only; 0 vs 1 with 6 probes -> ships+defence+buildings
             (threshold exactly 5); 0 vs 0 with 7 probes -> all four (research map 16 keys); 2 vs 0 with 4 probes ->
             ships+defence only; 4 vs 0 with **1 probe** -> all four via the level path. Cross-owner read isolation
             0 foreign rows.
  durable    `supabase/tests/espionage_read_contract_reveal_flags.sql` (13 PASS, table-driven, expectation derived
             from the rule) + `espionage_report_gating.sql` (17 PASS) remain the regression battery.
  no espionage object changed in this mission.

GAP C — ESPIONAGE MISSION COMPOSITION: GAP FOUND + CLOSED 2026-09-28
  found      `start_fleet` / `start_fleet_mixed` enforce the composition rule for RECYCLE but NOTHING
              for ESPIONAGE. MEASURED LIVE: `start_fleet_mixed(3 × light_fighter,'ESPIONAGE')` was
              accepted, persisted, charged fuel and consumed a fleet slot; the resolver then returned
              `probes_sent = 0`, counter chance 0 and all four reveal flags false — a report
              STRUCTURALLY guaranteed to reveal nothing, at full cost. Everything the resolver
              computes derives from `espionage_probe` (probes_sent = SUM of probes; chance = 0 when
              probes = 0; the whole reveal ladder is `max(0, probes − level_gap²)`), so the empty
              report was guaranteed, not unlucky. Internal gameplay defect, not a security hole.
  fixed      `20260928150000_enforce_espionage_probe_composition_rule` (LIVE): one guard per
              dispatcher, mirroring the existing RECYCLE rule, raising INSIDE the composition loop
              (atomic — nothing is charged) and rejecting mixed probe+fleet compositions.
              `ESPIONAGE_MISSION_REQUIRES_PROBES`. The patch inserts into the current `prosrc` via a
              once-only anchor instead of retyping the certified bodies, and re-asserts the
              `DEFAULT 'TRANSPORT'` (create-or-replace refuses to drop it, 42P13).
  certified  `supabase/tests/espionage_mission_composition.sql` **11 PASS + 2 INFO**, LIVE, ROLLBACK,
              residue 0: both dispatchers refuse; refusal is atomic; a REAL probe flight is still
              accepted and still produces a genuine report (probes_sent = 3, ships revealed);
              RECYCLE unchanged; ATTACK never raises the espionage guard; anonymous refused; the
              resolver carries no guard (level gating untouched); ACL unchanged (anon denied).
  untouched  the resolver, the reveal rule, level gating, the report contract, the ACL, the fleet
              engine. EspionageReportsPanel needed no change (it already consumed all 26 columns).
  ledger     `20260928144117` was applied BY MISTAKE with an empty body (no-op row, nothing changed).
              Left in place deliberately; the real change is `20260928150000_…`. Disclosed in
              README_ESPIONAGE_ENGINE.md §12.4.
  See docs/systems/README_ESPIONAGE_ENGINE.md §12.

GAP D — BEGINNER PROTECTION VISIBILITY: GAP FOUND + CLOSED 2026-09-28
  found      the 24 h beginner protection of §25 is ENFORCED (LIVE: attacking a fresh empire raises
              TARGET_BEGINNER_PROTECTED) but was INVISIBLE: `get_player_attack_protection(player_id, at)`
              is service_role only and `src/` had ZERO references — the rule surfaced only in the raw
              error of a FAILED attack. A real gap in an already-enforced mechanic, not a new rule.
  fixed      `20260928210000_add_my_attack_protection_read_contract` (LIVE): ONE read-only contract
              `get_my_attack_protection()` with NO arguments; ownership via auth.uid() -> players;
              it DELEGATES to `get_player_attack_protection` (the same authority the ATTACK trigger
              calls) so the UI can never drift from the enforcement. ACL authenticated + service_role,
              anon denied. The internal helper stays service_role only and the migration raises if that
              ever changes. UI: `ProtectionStatusPanel` on the overview screen, reusing existing CSS
              classes only, rendering nothing when the empire is not protected.
  certified  `supabase/tests/my_attack_protection_visibility.sql` **8 PASS + 2 INFO**, LIVE, ROLLBACK,
              residue 0 (incl. "same answer as the trigger authority" and "no session -> 0 rows").
              Regression 8 PASS: transport/espionage/battle contracts intact, protection trigger and
              espionage guards untouched, internal helper still service_role only, no RLS change.
  untouched  the 24 h window, the trigger, the AI scope, the balance, any CSS.
  browser    ENVIRONMENT BLOCKED — the contract is certified, the panel's render is not.
  See docs/systems/README_FLEET_ENGINE.md §31.

GAP E — RECYCLE DISCOVERABILITY: GAP FOUND + CLOSED 2026-09-28
  found      the RECYCLE mission lets the SERVER pick the target, and `start_fleet_mixed` raises
              'No debris field available for RECYCLE' when there is none. That refusal was already
              correct and ATOMIC (0 movements, no slot, no fuel) — NOT a correctness bug. The gap was
              discoverability: `launchBlock` warns pre-flight for FLEET_SLOTS_FULL /
              EXPEDITION_SLOTS_FULL / COLONY_CAP_REACHED, and RECYCLE had no such case, so the only
              feedback was the error AFTER pressing launch. On LIVE the human universe has ZERO debris.
  no decision needed  existence-only is EXACT, not a weakening: the dispatcher's own precondition is
              `universe_id = <mine> AND (metal>0 OR crystal>0)`, so the boolean IS that condition, with no
              ordering and no distance. Verified LIVE on both an empty and a populated universe. The
              richer option (which field, how much) was explicitly REJECTED: it would duplicate the
              dispatcher's ORDER BY and require a distance metric for a target that has no planet.
  fixed      `20260928220000_add_recyclable_debris_status_contract` (LIVE): `get_recyclable_debris_status()`
              with NO arguments, ownership via auth.uid() -> players.universe_id, SECURITY DEFINER with a
              pinned search_path, ACL authenticated + service_role (anon denied), read-only. It does NOT
              reveal the target field and does NOT model capacity. The migration raises if an argument,
              a distance/range/capacity/order-by/limit token, or any engine dependency ever appears.
  frontend   only the EXISTING pieces: one clause in the existing `launchBlock` (which already disables
              the launch button) plus one sentence in the existing NEAREST_DEBRIS note. No new component,
              no CSS. The contract is fetched only while RECYCLE is selected.
  certified  `supabase/tests/recyclable_debris_status.sql` **12 PASS + 2 INFO**, LIVE, ROLLBACK, residue 0
              — including the decisive pair: the contract says NO and the ENGINE refuses (test 2), and the
              contract says YES and the engine ACCEPTS the flight (test 4). Re-verified 2026-09-29: the
              fixture shipped WITHOUT its positive half (assertions 3/4 and the debris INSERT they need),
              so it aborted LIVE with 1 failure; repaired and re-run green. Contract itself unchanged.
  Regression 7 PASS: dispatchers
              keep the RECYCLE branch and their DEFAULTs, get_universe_debris unchanged, debris_fields
              still closed, previous contracts still callable, espionage guard intact.
  untouched  start_fleet_mixed, collect_debris, the worker, the RECYCLE composition rule,
              calculate_recycler_capacity, ACS, Combat, Espionage, Messaging, AI, Lifeforms, Moon.
  browser    ENVIRONMENT BLOCKED — the contract is certified, the rendering is not.
  See docs/systems/README_FLEET_ENGINE.md §32.

GAP F — EXPEDITION COMBAT DETAIL (enemy fleet + losses): GAP FOUND + CLOSED 2026-09-28
  category  B (backend complete, consumer missing) — the same shape as the Battle Report UI gap.
  found     the expedition CYCLE was verified complete and was NOT touched. The gap was inside it:
            `get_player_expedition_reports` returns `enemy_ships` and `lost_ships` and NOTHING in
            `src/` consumed them. `expeditionDetail()` printed the literal word "combate", so a pirate
            or alien encounter never told the player who they fought or what they lost.
  evidence  LIVE, rolled back, driving the REAL `resolve_expedition_pirates`:
            result ATTACKER_WIN, enemy_ships {"light_fighter": 8}; the contract returned exactly that
            to the client; the panel rendered only "combate".
  fixed     UI ONLY. `expeditionDetail()` renders both maps verbatim ("rival light_fighter×8",
            "perdidas light_fighter×3"). The local `ExpeditionReportRow` type gained the two fields —
            the generated `database.types.ts` already declared them. No RPC, no migration, no CSS,
            no new component; ids are printed as the contract returns them.
  certified `supabase/tests/expedition_combat_detail.sql` **11 PASS + 2 INFO**, LIVE, ROLLBACK, residue 0
            (real pirate battle, enemy fleet exposed, loss reported verbatim, cross-owner 0 rows, no
            session 0 rows, limit clamp, ACL, and an explicit "engine NOT modified" assertion).
            Regression 5 PASS: five resolvers intact, merchant/items callable, all previous contracts
            callable, espionage guard + protection trigger alive, expedition_results still closed.
  untouched the expedition engine, probabilities, rewards, resolvers, worker, ACL, CSS, and every CLOSED
            system. Scope per §2: Buildings/Research/Fleet/Combat/Moon/Messaging/Espionage/Beginner
            protection/RECYCLE/P3/AI were all checked first and left untouched — no regression found.
  browser   ENVIRONMENT BLOCKED — the contract is certified, the rendering is not.
  See docs/systems/README_MESSAGING_ENGINE.md §9.

GAP G — DEFENCE REPAIR VISIBILITY: GAP FOUND + CLOSED 2026-09-28
  category  A (consumer) — backend complete and authoritative, no consumer.
  found     `repair_defenses_after_combat` (OGameX ~70 % rebuild) is wired into `resolve_attack_arrival`
            and already applied to `planet_defenses`. `get_player_battle_reports` returns
            `defenses_repaired` and NOTHING in `src/` read it, so `BattleReportsPanel` printed
            "DEFENSAS 40→22" without saying 10 had come back — understating the wall the player is
            deciding to attack next. A player-facing fact, not an internal score.
  evidence  LIVE, rolled back, real path (start_fleet_mixed → resolve_attack_arrival):
            before 40, destroyed 17, repaired 10, planet_defenses 40-17+10 = 33;
            the contract returned defenses_repaired = 10; the panel ignored it.
  fixed     UI ONLY. One extra line, rendered only when a repair happened:
            "REPARADAS 10 (quedan 33)" = defender_defenses_after + defenses_repaired, which is exactly
            what the engine left standing. `BattleReportRow` gained the field (the generated types
            already had it). No RPC, no migration, no CSS, no new component.
  certified `supabase/tests/defense_repair_visibility.sql` **11 PASS + 2 INFO**, LIVE, ROLLBACK, residue 0
            (real attack → real combat → real repair; the wall verified in planet_defenses; cross-owner
            0 rows; no session 0 rows; ACL; explicit "engine NOT modified").
            Regression 5 PASS: resolver + repair function intact, repair still wired, ~70 % roll
            unchanged, all previous contracts callable, espionage guard + protection trigger alive.
  own error A first version of assertion 5 asserted `planet_defenses >= before`. That was a FIXTURE bug —
            the defender loses units — corrected to `before - destroyed + repaired` after measuring the
            real timeline. No product defect.
  untouched the combat engine, the 70 % rule, combat tables, loot, debris, ACS, and every CLOSED system.
  browser   ENVIRONMENT BLOCKED — the contract is certified, the rendering is not.
  See docs/systems/README_COMBAT_ENGINE.md.

GAP H — EXPEDITION CARGO CLAMP VISIBILITY: PRODUCT DECISION → CLOSED 2026-09-28
  decided    previous cycle ended with `NO SAFE GAMEPLAY GAP FOUND` + an explicit PRODUCT DECISION on the
             six unconsumed expedition report fields. Decision taken: expose the CLAMP RESULT, keep the
             FORMULA private.
  gap        the engine computes `final = LEAST(base × multiplier, cargo_capacity)`. When the find
             exceeded the hold, the difference was discarded SILENTLY and the report showed only the
             award — the player could not tell "found nothing" from "found plenty, my cargo was too
             small", while the contract already returned both sides of the clamp unused.
  fixed      UI ONLY. `expeditionDetail()` adds ONE conditional fragment, only when the clamp bit:
             "encontrado 23107 · carga 100 · 23007 no cabía, se transportó el máximo"
             Both numbers come from the contract; nothing is recomputed. No RPC, no migration, no CSS.
  hidden     reward_tier, reward_multiplier and max_resource_find stay DELIBERATELY unrendered: they are
             formula internals (tier is a restatement of the roll and its persisted value, `NORMAL`, does
             not even match the SMALL/MEDIUM/LARGE vocabulary of select_expedition_reward_tier).
             loot_applied_at is out of scope entirely: it is NOT an expedition field — it lives on
             combat_battles and is the idempotency guard written by apply_attack_loot.
  certified `supabase/tests/expedition_reward_visibility.sql` **10 PASS + 2 INFO**, LIVE, ROLLBACK, residue 0.
             Uses the REAL dispatcher + REAL resolver, retried until the random outcome roll yields
             RESOURCES (nothing forced, nothing mocked). Asserts CLAMPED, UNCLAMPED, zero-hold, verbatim
             values, cross-owner 0 rows, no session 0 rows, ACL, engine not modified, and that the
             LEAST(tier_amount, cargo) formula is unchanged.
             Regression 6 PASS: five expedition resolvers, merchant/items/slots, combat resolver + repair,
             all previous missions' contracts, espionage guard + protection trigger, and
             expedition_results still closed to direct client access.
  untouched resolve_expedition_arrival, the reward formulas, the economy, cargo capacity, every RPC, the
             ACL, CSS, Fleet, Combat, Espionage, AI, Lifeforms.
  browser   ENVIRONMENT BLOCKED — the contract is certified, the rendering is not.
  See docs/systems/README_MESSAGING_ENGINE.md §10.

## OGameX FINAL GAP CHECK 2026-10-03 — `REAL GAPS = 0` (PASS), 0 líneas de código

Comparación final OGameX→LGI + matriz de 16 áreas. **Diagnóstico puro**: no se modificó SQL, RPC,
TS/TSX, CSS ni fixtures. Probes en `BEGIN…ROLLBACK`, **residuo 0**.

```text
  REAL GAPS FOUND            0
  IMPLEMENTED                0  — nada estaba ausente de forma objetiva
  NO GAP (verificado)        16 áreas: buildings, research, production, queues, fleet, missions,
                             combat, espionage, expeditions, planets, moons, colonization,
                             recycling, transport, reports, workers
  PRODUCT DECISION REQUIRED  1 (NO implementado) — economía premium / Dark Matter
  ENVIRONMENT BLOCKED        0 — la certificación browser de flotas se resolvió el 2026-10-03

  MAPA OBSOLETO (2026-09-25) 6 filas que hoy son FALSOS gaps: MissileMission, MoonDestruction,
                             getObjectDowngradePrice, dispatchRecallFleet, CleanupWreckFields/
                             DeleteOldMessages y crawler overload — todos ya IMPLEMENTADOS en LIVE.
                             No reabrir por leer el mapa viejo.

  DESCARTADO POR MEDICIÓN   (a) purga de colas: RETENCIÓN CERRADA como RETAIN el 2026-10-03
                             (ver §QUEUE RETENTION). Sin consumidor, sin dependientes, sin
                             acumulación y con índices completos; además son el único historial.
                             Higiene, no gap objetivo. NO purgar.
                             (b) scan_with_phalanx no escribe informe: devuelve por diseño las flotas
                             ajenas OUTBOUND/RETURNING hacia el sistema (semántica OGameX de falange);
                             la UI lo muestra como "flota(s) en tránsito". NO GAP.

  CERTIFICADO E2E (real)    TRANSPORT: contrato→ownership→despacho→worker→COMPLETED→+1000 metal en
                             destino→mensaje→idempotencia (2º tick no duplica).
                             FALANGE: ownership ok, sesión falsificada RECHAZADA, 5000 de deuterio
                             cobrados en servidor (20000→15000).

  SEGURIDAD                 las 20 acciones autenticadas tienen consumidor en src/**; los 3 helpers
                             de solo lectura siguen cerrados. Cuerpo ajeno y sesión falsificada
                             rechazados en servidor, no ocultando botones.

  DECISIONES                1) economía premium / Dark Matter (modelo de negocio)
```

> Las decisiones 3) "adopción del tope global de flotas" y 1) "purga de colas terminales"
> ya NO están pendientes: el tope de flota se cerró el 2026-10-03, y la retención de colas se
> cerró ese mismo día como `RETAIN`. Ver §"QUEUE RETENTION" más abajo.

Detalle y evidencia por área: `docs/audits/OGAMEX_FINAL_GAP_CHECK_2026-10-03.md`.

## QUEUE RETENTION — CLOSED 2026-10-03 / policy: RETAIN (no purge)

Decisión: **no purgar las filas `COMPLETED`/`CANCELLED`. No se escribió código.**
Resuelve la última decisión pendiente de esta área (antes: "retención sin decidir").

```text
MEDICIÓN LIVE (read-only)
  cola              total  terminales  activas  más antigua  más reciente
  building_queue        3          3        0  2026-09-18   2026-09-18
  research_queue        5          5        0  2026-09-18   2026-09-19
  shipyard_queue        1          1        0  2026-09-19   2026-09-19
  defense_queue         0          0        0  —            —
  TOTAL                 9          9        0

POR QUÉ NO HAY NADA QUE RESOLVER
  1. SIN CONSUMIDOR UI   las 5 consultas cliente filtran a estados ACTIVOS
     (.in('status',['BUILDING','QUEUED']) / .eq('status','RESEARCHING') / .in('status',['BUILDING'])).
     No existe ninguna pantalla de historial de construcción/investigación/astillero.
  2. SIN DECISIÓN DE JUEGO can_start_research, evaluate_building_start_internal e
     inspect_demolition filtran por 'RESEARCHING'. Borrar terminales no cambiaría NADA.
  3. SIN DEPENDIENTES     0 claves foráneas entrantes sobre las cuatro colas: sin hijos,
     sin reportes, sin mensajes, sin historial colgando (nunca estuvo en juego un CASCADE).
  4. SIN ACUMULACIÓN      9 filas en toda la era y **0 filas creadas en 14 días**, frente a
     546 planetas creados en esa misma ventana. El universo está activo; las colas no se escriben.
  5. ÍNDICES COMPLETOS    las 4 colas están indexadas, incluidos los compuestos estado/fin
     (idx_research_queue_player_researching_finish). No hay presión de escaneo que aliviar.

POR QUÉ PURGAR SERÍA INCORRECTO
  El esquema NO tiene ninguna tabla audit/history/log/event (verificado en information_schema).
  Las colas son el ÚNICO registro de qué construyó, investigó y produjo cada imperio.
  Borrarlas sería destrucción irreversible del único historial a cambio de beneficio CERO.

POR QUÉ NO SE ELIGIÓ NINGÚN PLAZO (sin constantes inventadas)
  OGameX  su mantenimiento cubre highscores, DarkMatterRegenerate, CleanupWreckFields,
          DeleteOldMessages, CleanupDestroyedPlanets y ResetDebrisFields.
          NO define ninguna regla de retención de colas: OGameX no autoriza nada aquí.
  LGI     existe un default de 7 días, pero en run_message_retention_worker; esa ventana viene
          de DeleteOldMessages y es una regla de MENSAJES. Aplicarla a colas por analogía sería
          un error de categoría, no una derivación.

  status:  CLOSED
  policy:  RETAIN (indefinida)
  purge:   DISABLED — no implementado, no necesario
  revisit: solo si se construye una pantalla de historial de colas (ahí sí sería una política
          real), o si el crecimiento llega a ser medible: medir primero, luego decidir
```

**Queue expiry NO se tocó:** expirado → `COMPLETED` sigue igual que como se certificó. Nada
convierte `COMPLETED` en `CANCELLED` ni altera reembolsos. Detalle completo en
`docs/systems/README_ECONOMY.md` §"Queue retention".

## FLEET SLOT CAP — CLOSED 2026-10-03 (ya NO es product decision)

```text
  POLÍTICA (sin cambios)   max = 1 + computer_technology. Sin Dark Matter / Officers / premium.
                           Ocupan slot: OUTBOUND, ARRIVED, HOLDING, RETURNING.
                           Liberan al pasar a COMPLETED o CANCELLED. Consumo en el INSERT.
  LO QUE YA EXISTÍA       trigger BEFORE INSERT trg_enforce_fleet_slots sobre fleet_movements →
                           assert_player_fleet_slot_available → FLEET_SLOTS_FULL.
                           Cubría TODOS los caminos de inserción (RPCs e IA), no sólo los de la UI.
  DEFECTO REAL            el recurso es POR JUGADOR, pero cada despacho bloqueaba sólo el
                           PLANETA DE ORIGEN. Dos despachos concurrentes del mismo jugador desde
                           planetas DISTINTOS no se serializaban: ambos contaban los mismos slots
                           libres, ambos pasaban, ambos insertaban → N slots pasaban a N+1 flotas.
                           Sin tocar nada del cliente.
  FIX                     20261004010000_fleet_slot_player_lock: el assert ahora hace
                           SELECT ... FROM players WHERE id = p_player_id FOR UPDATE.
                           Un solo lock por llamada → no puede formar ciclo de deadlock.
                           Firma, excepción, volatilidad y ACL sin cambios.
  TESTS                   supabase/tests/fleet_slot_cap.sql — 20 PASS / 0 FAIL, LIVE, ROLLBACK.
                           Limitación declarada: harness de una sesión; la exclusión mutua se
                           DERIVA del lock (L1), no de una carrera ejecutada de verdad.
  UI                      ya coherente: FleetModules muestra MÁX/EN VUELO/LIBRES del contrato, y
                           useFleetDispatch bloquea el botón sin dejar de ser la autoridad.
  DARK MATTER             DEFERRED — NO TOCADO. Sin bonos premium de slots.
```

Detalle durable: `docs/systems/README_FLEET_ENGINE.md` §34.

## CRAWLER OVERLOAD + DEMOLITION/ION + QUEUE EXPIRY — CLOSED 2026-10-03

OGameX = referencia de comportamiento · LGI = autoridad. De las tres mecánicas **sólo una era gap real**.

```text
  QUEUE EXPIRY    CLOSED · NO REWRITE. Las 4 colas vencidas se COMPLETAN, nunca se cancelan por
                  expiración: ningún procesador menciona 'cancel', todos usan finishes_at <= y marcan
                  COMPLETED. Verificado LIVE con las 4 colas ya vencidas + reproceso idempotente.
                  La cancelación del jugador conserva su política y su reembolso (no se tocó).
  CRAWLER          IMPLEMENTADO (era el gap: 0 columnas '%overload%' en todo el schema public).
  OVERLOAD        0-150 %, entero, DEFAULT 100 → ningún cuerpo cambia de comportamiento.
                  ENERGÍA  p<=1: 50*p · p>1: 50*p + 50*(p-1)  ⇒ 100%=50,110%=60,120%=70,130%=80,
                  140%=90,150%=100. Por encima de 100 el coste crece MÁS RÁPIDO que la producción.
                  PRODUCCIÓN sigue al porcentaje (bono de crawler * p). Con holgura energética
                  150 % > 100 % (medido); sin ella el guard de sostenibilidad puede Bajarla, y eso es
                  el guard EXISTENTE actuando, no un defecto.
                  SOSTENIBILIDAD por la ruta ya existente (calculate_crawler_energy_consumption →
                  calculate_planet_energy_balance → evaluate_economic_sustainability). Sin reglas nuevas.
                  DIVERGENCIA: el gating por Character Class de OGameX NO se importa — LGI no tiene
                  clases ni Lifeforms; rango 0-150 para todos. No se inventó un Collector.
  DEMOLITION/ION   CLOSED · NO REWRITE. Ya existía calculate_building_demolition_cost(building, level,
                  ion) = coste de construir el nivel RETIRADO × (1-4 %×Ion) → floor por recurso → min 0,
                  e inspect_demolition lo llama con el Ion real antes de cobrar. Medido en vivo con
                  metal_mine 10: Ion 0/1/5/10/25 → 100/96/80/60/0 %. Nunca negativo (Ion 0..60).
                  Coste de demolición ≠ reembolso de cancelación: no se mezclaron.
  SEGURIDAD        set_planet_crawler_percentage es SECURITY DEFINER: auth.uid() → players.user_id →
                  cuerpo propio; 151 % y -1 % rechazados; cuerpo ajeno y player_id falsificado
                  rechazados EN SERVIDOR. Helpers puros cerrados al cliente.
  TESTS            supabase/tests/crawler_overload_demolition_queue_expiry.sql — 32 PASS / 0 FAIL,
                  LIVE, ROLLBACK, residuo 0.
  STATIC           tsc 0 · build 0 · eslint 0 errors (7 warnings preexistentes) · cert:contracts PASS
                  (75 nombres RPC) · git diff --check limpio.
  UI               src/App.tsx muestra el OVERLOAD y ofrece 0/50/100/110/120/130/140/150 %. No calcula
                  producción ni energía: las muestra del contrato.
  TOQUE            1 columna nueva (planets.crawler_percentage), 1 RPC nueva, 3 ocurrencias del término
                  de crawler en calculate_planet_production, y calculate_crawler_energy_consumption /
                  get_planet_crawler_status. Ninguna otra fórmula, ni colas, ni el motor de asentamiento.
  FUERA DE ALCANCE Missile System CLOSED (no tocado) · browser de flotas ENVIRONMENT BLOCKLED ·
                  ledger de migraciones documentado, `db push` prohibido.
```

Detalle durable: `docs/systems/README_ECONOMY.md` §"Crawler overload 0–150 % · Demolition + Ion Technology · Queue expiry".

## ECONOMY GAP SWEEP 2026-10-02 — `NO OBJECTIVE ECONOMY GAP FOUND`, 0 líneas de código

Barrido discovery-first sobre producción, energía, almacén, colas, crawler/fusion y demolición.
Superficie de 92 contratos que el cliente usa de verdad, contrastada contra `pg_proc` + ACL de LIVE,
y **humo de los contratos de economía ejecutado como el jugador autenticado real** (no `service_role`).

```text
  RESULT      NO OBJECTIVE ECONOMY GAP FOUND. No se modificó SQL, RPC, TS/TSX, CSS ni fixtures.
  DESCARTADO  get_economic_sustainability_check existe LIVE, es owner-scoped y NO tiene consumidor,
              pero NO es gap: can_start_building ya devuelve el mismo veredicto (allowed=false) y el
              MISMO motivo INSUFFICIENT_ENERGY_SUSTAINABILITY. Medido LIVE. El contrato solo añade
              cifras de contexto → no es una capacidad ausente.
  DESCARTADO  2 planetas LIVE con producción detenida (energy_production=0, consumo>0, incluido el
              Homeworld del jugador). NO es gap: el Overview ya muestra +0/h junto a ENERGÍA -24.2/h
              y PROD/CONS +0/-24.2, y la salida (solar_plant) está disponible y autorizada.
  VERIFICADO  El guard de sostenibilidad cubre exactamente las 4 filas de building_energy_definitions.
              Naves y defensas no consumen energía → que solo actúe en start_building es correcto.
  VERIFICADO  8/8 contratos de economía sin error como su dueño real; 0 stocks negativos;
              0 colas vencidas; ningún contrato roto (criterio E no se activa).
  VERIFICADO  formatRate/formatStorage solo comparan y formatean valores del servidor; no derivan regla.
  DECISION    crawler overload 0-150 % — 0 columnas overload en el schema. NO implementada.
  DECISION    demolition refund + política ion-technology — start_demolition no menciona refund. NO implementado.
  FUERA        Missile System CLOSED (no tocado) · browser de flotas ENVIRONMENT BLOCKLED ·
              ledger de migraciones documentado, `db push` prohibido.
```

Detalle, evidencia LIVE y trazabilidad de cada candidato descartado: `docs/audits/ECONOMY_GAP_SWEEP_2026-10-02.md`.

## AUTONOMOUS MULTI-GAP CLOSURE SWEEP (2026-09-29) — 5 gaps closed, 0 regressions

Autonomous chained sweep. Sync gate re-run first: no divergence, `origin/main` is 1 commit ahead
(remote-only `docs/MARCIANITOS_GALAGA_CONTEXT.md`, no path collision with local work), HEAD == merge-base,
13 pre-existing modified files and 21 untracked files preserved, 5 stashes untouched. No git operation
other than read-only inspection. Browser certification remains ENVIRONMENT BLOCKED (no driver + human
DEV credential) and was not simulated.

```text
METHOD (every gap was found by measurement, not by re-reading a report)
  inventory  scripts/contract-inventory.mjs derives the UI's `supabase.rpc('…')` surface from src/**
            (48 names) mechanically; it is diffed against the LIVE `authenticated` ACL surface
            (pg_proc + aclexplode). That diff is what produced GAP D. Two read-only subagents ran the
            economy and messaging sweeps in parallel; their findings were re-verified LIVE here before
            anything was implemented (neither has DB access, so nothing was taken on trust).

GAP A — FALSE "COLONY ESTABLISHED" MESSAGE ON EVERY MOON FORMATION: CLOSED
  problem   trg_notify_colony_established is AFTER INSERT ON public.planets, which holds BOTH bodies
            (a colony is kind='PLANET', a moon is kind='MOON'). Its only guard was
            `player_id is null or is_homeworld`, and settle_moon_creation_for_battle inserts the moon
            with the DEFENDER's player_id and is_homeworld=false -> the guard passed.
  evidence  LIVE: settle_moon_creation_for_battle already sends 'Moon formed'; the trigger therefore
            added a SECOND message, "Your colony ship founded Moon at [1:2:3]" — an event that never
            happened. 0 moons exist LIVE (656 PLANET, all homeworlds) and 0 false `colony:` messages,
            so the defect was LATENT: proven from the two live function bodies and a real moon insert.
  fixed     20260929000000_fix_colony_message_for_moon_bodies.sql — one `kind is distinct from 'PLANET'`

GAP B — DEAD `planet_resources.energy` PRESENTED AS A FOURTH RESOURCE: CLOSED (UI only)
  problem   the column is never written outside two resets, and update_planet_resources_until_raw READS
            it, RETURNS it and never UPDATEs it -> the stock is structurally 0 forever, while the UI
            rendered it as a resource in three places (overview, header bar, PDA tile).
  evidence  LIVE: the settlement's single UPDATE writes only metal/crystal/deuterium/
            last_calculated_at; every INSERT hard-codes energy=0. README_ECONOMY already states the
            authoritative semantics ("energy is a balance value, not a produced resource") and the
            fusion migration treats it as a flow.
  fixed     the three dead reads are gone; the contract's own figures are rendered instead (overview
            ENERGIA = energy_balance_per_hour, the PROD/CONS row is unchanged, the PDA tile is now
            ENERGIA /H fed energyBalancePerHour — prop renamed so the type states the semantics).
  untouched the engine: energy is still not accumulated, not produced, not spendable. No RPC, no
            migration, no formula, no cost, no capacity.
  See docs/systems/README_ECONOMY.md "Resource-panel honesty".

GAP C — STORAGE CAP SILENTLY HALTED PRODUCTION AND WAS INVISIBLE: CLOSED (UI only)
  problem   update_planet_resources_until_raw clamps with
            `least(capacity, greatest(0, stock + produced))` from calculate_planet_storage_internal —
            correct — but the panel printed the three capacities as bare numbers, so a bank whose
            production had stopped looked identical to a half-full one.
  fixed     one formatter, formatStorage(stock, capacity) -> " · NN%" and " · NN% ALMACEN LLENO" when
            stock >= capacity. Both operands were already on the client (the stock from the planets read
            and the capacity from the SAME get_planet_economy_overview row already feeding the ALMACEN
            line). The panel compares two server values and derives no rule.
  untouched the clamp, the storage calculation, the settlement and the fusion/crawler integration.

GAP D — FOUR CLIENT-REACHABLE HELPERS THAT COULD ONLY ANSWER WRONG OR ERROR: CLOSED
  problem   four `authenticated`-executable SECURITY INVOKER helpers whose client result is decided by
            the RLS of the table underneath, not by their own logic.
  evidence  MEASURED LIVE, same data and arguments, only the role differing:
              can_recycle_debris(own fleet, real field)   engine TRUE  -> client FALSE
              get_expedition_ship_candidates(own fleet)   engine 5     -> client EXCEPTION
              get_active_expedition_item_effect(own)     engine 42    -> client 0
              check_defense_requirements(OWN planet)     engine OK    -> client "permission denied"
            Cause: debris_fields / expedition_ship_tiers / expedition_item_uses all carry
            `deny_direct_api_access` (qual=false), and defense_prerequisites is not SELECT-granted to

GAP E — `npm run build` REWROTE A COMMITTED MANIFEST WITH WINDOWS PATH SEPARATORS: CLOSED
  problem   `prebuild` runs scripts/fetch-ogamex-assets.mjs, which writes
            public/assets/ogamex/objects/manifest.json. It normalised paths with
            `.replaceAll('\\\\', '/')` — in a JS literal `'\\\\'` is TWO characters, so it searched for
            a double backslash and never matched `path.relative`'s single native separator.
  evidence  every Windows build rewrote all 124 committed entries as "buildings\\x.jpg", dirtying the
            tree on each build. Caught by running the mandatory `git diff --check` after the build.
  fixed     `const toPosix = (p) => p.split(sep).join('/')` with `sep` imported from node:path — correct
            on both platforms, no escaping. The already-dirtied manifest was normalised back and is now
            BYTE-IDENTICAL to HEAD (19648 bytes, verified against `git show HEAD:…`).
  note      `git status` still prints ` M` for that path: with core.autocrlf=true that is a stat-cache
            artifact and `git diff` reports no content change. Deliberately NOT run `update-index` or any
            other index-mutating command, which this mission forbids.

NO REGRESSION (all re-measured after all five changes)
  npx tsc -b exit 0 · npm run build exit 0 (192 modules, only the pre-existing chunk-size warning) ·
  git diff --check clean · LIVE residue 0: planets 656, player_messages 6, players 656,
  planet_resources 656, fleet_movements 1, debris_fields 3, expedition_item_uses 0,
  fleet_movement_ships 1, auth.users 12, player_research 10483 — identical to the pre-run state.
  colony fixture 10 PASS · colony regression 4 PASS · ACL fixture 15 PASS.
  tools added  scripts/contract-inventory.mjs (derives the UI RPC surface mechanically) and
  scripts/repair-encoding.mjs (repairs double-encoded UTF-8, refusing to write unless the ASCII skeleton
  is provably unchanged, plus a --scan mode).

CLASSIFIED, NOT IMPLEMENTED
  PRODUCT DECISION  unread state on the four message-category tabs; message pagination/cursor;
                     crawler overload %, Collector multiplier, crawler reuse, fusion research-lab gate,
                     merchant/shop/Dark Matter premium economy; AI activation and AI aggression policy.
  NO GAP            get_universe_ranking is LEGACY/REDUNDANT, not an orphan: the UI RankingPanel already
                     serves the general ranking through get_universe_ranking_by_category(…, 'GENERAL'),
                     whose body is identical (same pl.rank / pl.points, same ordering, same clamp).
                     Per the rule, a deliberately internal/legacy contract is NOT auto-promoted to UI.
  NO GAP            the DEFEND mission is refused at dispatch with COMBAT_SUPPORT_NOT_READY, and
                     resolve_combat already produces 'Battle report' + 'Attack received' for the
                     defender; the DEFENDER/FLEET arm of the producer is dormant pending the ACS engine,
                     a pre-existing documented state rather than a messaging residue.
  NOT TOUCHED       3 historical migrations carry the same double-encoding in COMMENTS
                     (20260926124030, 20260926124035, 20260926220000). A migration is immutable
                     provenance: rewriting its bytes would be a worse sin than a mojibake em-dash.
                     Recorded, deliberately left alone.
  ALSO REPAIRED     the pre-existing double-encoded UTF-8 in src/App.tsx (245 markers) and
                     docs/systems/README_FLEET_ENGINE.md (525 markers), a regression from an earlier
                     session that made the Spanish UI text and the ⚙/⚡/🛰 glyphs render as garbage.
                     Repaired only after all five safety checks passed, the decisive one being that
                     stripping every non-ASCII byte yields the SAME text before and after.

            the role. A helper that can only lie looks like a supported capability and invites a future
            consumer to build on the lie.
  fixed     20260929010000_acl_revoke_wrong_client_invoker_helpers.sql — revoke public/anon/
            authenticated per OVERLOAD, keep service_role and the owner. The engine, the fleet worker,
            the expedition resolvers and the AI run as postgres/service_role and are unaffected.
  certified supabase/tests/wrong_client_invoker_helpers.sql 15 PASS, LIVE, ROLLBACK, residue 0.
            Includes the decisive no-regression assertion: all 52 UI contracts (the 48-name src/**
            inventory) keep `authenticated` EXECUTE, plus 45 surviving contract names, plus the
            DEFERRED Lifeforms surface, plus the three RLS policies being unchanged.
  untouched every calculate_*/select_expedition_*/inspect_expedition_* helper, every DEFINER contract,
            the whole start_*/cancel_* family, the four ui_*_definitions readers, the get_player_*
            read contracts and Lifeforms.
  NOTE two fixture traps were hit and corrected while writing it, both recorded in the fixture header:
            can_recycle_debris counts RECYCLERS in the fleet (assertion 1 is vacuous without one), and
            `calculate_research_time` has 4 overloads of which only 1 is a client contract, so a
            name-level ACL assertion on it is wrong. Neither was a product defect.

            guard. Colony path byte-identical for PLANET rows; the moon keeps its own producer.
  certified supabase/tests/colony_message_body_kind.sql 10 PASS, LIVE, ROLLBACK, residue 0.
            Regression 4 PASS on the REAL path (start_colonize_fleet -> resolve_colonize_arrival ->
            the colony message is still produced verbatim).
  untouched moon engine, colony engine, create_player_message, the trigger binding, other producers.
  See docs/systems/README_MESSAGING_ENGINE.md §11.


GAP B — P3 ACL CLEANUP: VERIFIED + EXTENDED
  first wave  `20260927130100` (twelve audited INVOKER helpers) verified present; `acl_surface_p3.sql` 11 PASS.
  new finding an autonomous probe of EVERY read contract the frontend consumes (as `authenticated`) returned
             31 OK / 3 failing, which exposed four client-reachable helpers whose only possible client outcome is a
             permission error: `get_planet_economic_rates`, `get_planet_rate_snapshot`, `project_planet_resources`,
             `evaluate_action_at_time` (INVOKER over `universes` / the engine analysis views / an engine-only helper).
  closed     `20260927140000_acl_p3_revoke_dead_client_invoker_helpers` revokes public/anon/authenticated on exactly
             those four, keeps service_role, and asserts no UI-called or working contract lost its grant.
             Baseline: authenticated outside the allow-list 109 -> 105; anon 0; PUBLIC grants 0.
             `acl_surface_p3.sql` corrected (stale `v_internal` list rebuilt from the real call sites + new
             assertion 8c) -> 11 PASS. The frontend inventory was re-derived from every `supabase.rpc(...)` call
             site, which revealed the variable-dispatched `start_building`/`start_research`/`start_ship`/
             `start_defense` family an earlier regex had missed.

SWEEP FINDINGS (evidence, not assumptions)
  reports/messages   every producer (fleet lifecycle, combat participant, expedition, colony, espionage, counter-
                     espionage, attack received) reaches `PlayerInboxPanel` via `get_player_messages`; the four
                     report read contracts work as `authenticated`. NO GAP.
  battle report UI   CLOSED 2026-09-28: the COMBATE category was a one-line summary; `get_player_battle_reports`
                     already returned `rounds` and `participants` with no consumer. New `BattleReportsPanel`
                     (src/GameplayEnginePanel.tsx) renders the round-by-round detail, participants and own losses
                     with the same contract — no new RPC, no engine change. tests/battle_report_ui_contract.sql
                     8 PASS. Browser render still ENVIRONMENT BLOCKED. See README_MESSAGING_ENGINE.md §7.
  transportes       CLOSED 2026-09-28: TRANSPORTES was the last Messages category reading `fleet_movements`
                     straight from the browser. NOT a vulnerability (that RLS is already owner-scoped) — it was
                     the last place the client supplied its own ownership selector. New owner-scoped contract
                     `get_player_transport_movements(p_limit)` (LIVE 20260928131919): auth.uid() -> players
                     -> fleet_movements, mission fixed to TRANSPORT server-side, limit clamped 1..100, no
                     player_id argument, anon denied. loadMessages() now consumes it; same rows, text, order.
                     tests/transport_movement_read_contract.sql 12 PASS, residue 0. See README_MESSAGING_ENGINE §8.
  fleet lifecycle    no regression found; the settle-path regression was closed in `20260927120200`.
  colonization       END-TO-END VERIFIED this mission (rolled back): planet created with the right owner, one
                     `planet_resources` row, "Colony established" message produced, colony ship consumed, movement
                     COMPLETED, replay refused, cap gate certified by `colony_cap.sql`. NO GAP.
  expeditions        all client contracts consumed and working; no orphan contract. NO GAP.
  economy/production 31/31 probed read contracts OK; queues/cancellation certified. NO GAP.
  AI                 all 609 AI profiles are `status = 'DORMANT'` and `run_ai_policy_worker` selects only
                     `status = 'ACTIVE'`, so the espionage/attack/colonize code inside `ai_decide_and_act_core` is
                     inert. Activation policy = PRODUCT DECISION, not touched.
  type surface       seven names declared in the generated `src/lib/database.types.ts` do not exist in LIVE (the
                     retired legacy fleet cluster, `get_player_fleet_speed_multiplier`, `register_guest_player`);
                     pruned to remove the compile-against-a-missing-contract trap. tsc + build clean.
  direct reads       the definitions tables and the RLS-filtered own-row tables the UI reads directly all respond
                     as `authenticated` (verified LIVE). NO GAP.
  NOT EXECUTED       browser certification of the fleet flow — the reserved final item (no driver, no human
                     credential). ENVIRONMENT BLOCKED, not simulated.
DOCS               docs/systems/README_ECONOMY.md (third ACL pass + type-surface prune) ·
                   docs/reference/README_OGAMEX_LGI_MAP.md (status block) · this entry
Validation: `git diff --check` clean · `npx tsc -b` exit 0 · `npm run build` exit 0 · no commit, no push.
```


## ESPIONAGE BUILDINGS/RESEARCH + P3 ACL CLOSURE (2026-09-27)

Both authorised works of this mission are implemented, certified and documented.

```text
IMPLEMENTED + CERTIFIED (LIVE, ROLLBACK, zero residue)
  buildings/research   20260927130000_espionage_report_buildings_and_research — the report now carries the two
                       remaining OGameX categories, gated server-side at arrival with `canRevealData(..., 5, 3)` for
                       buildings and `(..., 7, 4)` for research (OGameX @7c420bad, verified verbatim). Four reveal
                       flags are stored as a true snapshot; the read contract returns the four maps + the four
                       outcomes; the UI renders both new sections with the certified definition names.
                       tests/espionage_read_contract_reveal_flags.sql 13 PASS (table-driven block whose expectation is
                       DERIVED from the OGameX rule) · tests/espionage_report_gating.sql 17 PASS (replay).
  P3 ACL cleanup       20260927130100_acl_p3_revoke_authenticated_invoker_helpers — `authenticated` revoked on the
                       twelve audited SECURITY INVOKER helpers (each measured failing closed for a client and with no
                       frontend/worker caller); `service_role` keeps access. authenticated outside the allow-list
                       121 -> 109; anon 0; PUBLIC grants 0. tests/acl_surface_p3.sql 10 PASS (new assertion 8b).
NOT TOUCHED            the 32-name client allow-list; calculate_building_cost / project_planet_resources /
                       evaluate_action_at_time (fixture-protected); every DEFINER contract; and
                       calculate_planet_production_snapshot (works for authenticated, not in the audited list).
BLOCKED (environment)  browser certification of the fleet flow: no human DEV credential. [CORRECTED 2026-09-28:
                       the driver is NOT missing - scripts/ui-engine-certify.mjs drives real Edge headless over CDP
                       with zero dependencies and scored 27/27. See the BROWSER CERTIFICATION entry below.] Still
                       the next and final work item, not a technical gap.
DOCS                   docs/systems/README_ESPIONAGE_ENGINE.md §3/§7/§11 · docs/systems/README_ECONOMY.md (P3 closure)
                       · docs/systems/README_RESEARCH.md (legacy overloads now engine-only) ·
                       docs/reference/README_OGAMEX_LGI_MAP.md (status block)
Validation: `git diff --check` clean · `npx tsc -b` exit 0 · `npm run build` exit 0 · no commit, no push.
```


## ESPIONAGE EVIDENCE SWEEP (2026-09-27) — gating re-certified, leak oracles closed, settle regression fixed

Mission: sweep Espionage → levelling gating → counter-espionage → reports/messaging → fleet integration → browser
certification → ACL/P3, closing every TECHNICAL gap found against the real code and LIVE.

```text
IMPLEMENTED + CERTIFIED (LIVE, ROLLBACK, zero residue)
  cross-owner oracles   20260927120000_harden_cross_owner_research_and_colony_reads — five client-callable DEFINER
                        contracts (get_research_network_lab_level, calculate_research_time,
                        calculate_max_colony_slots, check_colony_cap, calculate_player_category_scores) allowed any
                        signed-in player to read ANOTHER empire's buildings/research without an espionage mission.
                        Now the certified identity gate (+ planet ownership for the planet-scoped ones).
                        tests/cross_owner_research_and_colony_reads.sql 6 PASS
  reveal outcome        20260927120100_espionage_report_reveal_flags — the read contract returns
                        out_ships_revealed / out_defenses_revealed, DERIVED server-side from the stored snapshot, so
                        the UI can tell «not revealed» from «empty» without duplicating the OGameX rule. UI:
                        EspionageReportsPanel («NAVES / DEFENSAS» with definition names) + the ESPIONAJE message row.
                        tests/espionage_read_contract_reveal_flags.sql 7 PASS
  settle regression     20260927120200_fix_engine_settle_storage_regression — the espionage resolver died with
                        PLAYER_NOT_OWNED whenever a JWT was present, because the engine settle path called the
                        GATED client contract `calculate_planet_storage` (introduced by 20260926280000). Split into
                        `calculate_planet_storage_internal` (service_role) + the unchanged client contract, and
                        repointed the three engine-only consumers. Numeric equivalence asserted for every planet.
  fixture repair        supabase/tests/counter_espionage.sql had a stray statement after ROLLBACK → removed.
REPLAYED (evidence, not assumption)
  espionage_report_gating.sql 17 PASS · counter_espionage.sql 13 PASS · reveal flags 7 PASS · cross-owner 6 PASS
  frontend RPC inventory 41/41 exist and are authenticated-executable · 0 DEFINER functions without pinned
  search_path · anon reaches only the 3 allow-listed names.
NOT DONE (product)      buildings/research sections in the espionage report (OGameX thresholds 5/3 and 7/4).
NOT EXECUTED            browser certification: no human DEV credential available. [CORRECTED 2026-09-28: the
                        driver DOES exist - scripts/ui-engine-certify.mjs runs real Edge headless over native CDP with
                        zero dependencies (27/27 PASS measured on 2026-09-28); playwright/puppeteer/cypress being
                        absent from package.json is therefore NOT evidence of a missing driver.] Route when the
                        prerequisite exists: provide a DEV human account (the driver is already in place), and cover
                        login/session → owned planet → fleet UI → ship selection → destination → mission → dispatch →
                        server acceptance (fleet_movements row + slot consumption) → state transition → return.
                        No simulated result was recorded.
DOCS                    docs/systems/README_ESPIONAGE_ENGINE.md §7 + §10
                        docs/reference/README_OGAMEX_LGI_MAP.md (status block)
Validation: `git diff --check` clean · `npx tsc -b` exit 0 · `npm run build` exit 0 · no commit, no push.
```

## UI DESIGNER BROWSER CERTIFICATION (2026-09-27) — 27/27 CLOSED

The UI Designer browser certification is fully closed.

```text
CERTIFICATION
  script       scripts/ui-engine-certify.mjs
  checks       27/27 PASS
  physical 12d PASS — status → ops
  evidence     pointerdown → pointermove → pointerup
  production   no drag-logic change required
```

The durable technical record is segregated into docs/systems/README_UI_DESIGNER.md. Temporary drag diagnostics
were removed after the 27/27 run; the durable offscreen source/destination geometry remains in the harness.

## AUTONOMOUS FOLLOW-THROUGH (2026-09-27) — fleet backend + P3 verification

Direct LIVE Supabase verification was performed without modifying persistent game state:
- P3 dead-helper cleanup is present in LIVE (`20260927130100` + `20260927140000`); the four dead INVOKER helpers
  have no client EXECUTE, while the fleet/UI contracts retain `authenticated` EXECUTE.
- A real `start_fleet` call was executed with the DevPlayer identity against an AI planet inside a transaction and
  rolled back. The authoritative dispatcher returned a fleet id, mission `TRANSPORT`, origin/destination and
  arrival timestamp. Zero persistent residue remains.
- The LIVE migration history contains both P3 cleanup migrations and the espionage buildings/research migration.

Browser certification of the actual authenticated Fleet screen remains an environment-level item: the available
browser harness can certify the UI workbench, but this session has no reusable human session credential/driver for
the authenticated gameplay surface. It must not be simulated or replaced with a claim of browser certification.

NEXT EXECUTOR: the implementation work remains in-repo/Supabase-owned; no Cline/Copilot handoff is required.

## P3 ACL + ESPIONAGE + FLEET LIVE VERIFICATION (2026-09-27)

P3 ACL fixture has been executed directly against LIVE Supabase and passes 11 assertions (plus INFO):
- 32/32 client RPCs retain authenticated EXECUTE.
- 0 anonymous-reachable functions remain outside the client allow-list.
- 21 internal AI-engine views are unreadable by anon/authenticated and remain service_role-readable.
- AI smoke passes.
- The 12 audited INVOKER helpers and 4 dead client-reachable helpers are engine-only.
- 0 public functions retain an ACL-level PUBLIC EXECUTE grant.
- failed assertions: 0.

The espionage buildings/research migration is LIVE as `20260927130000_espionage_report_buildings_and_research`. Its OGameX-derived server-side thresholds are:
- buildings: remaining probes >= 5 OR attacker espionage >= defender + 3;
- research: remaining probes >= 7 OR attacker espionage >= defender + 4.
The sections are snapshotted at arrival and exposed through the owner-scoped `get_player_espionage_reports` contract.

Fleet backend smoke was also executed against LIVE with DevPlayer inside a transaction and rolled back: `start_fleet` returned a valid fleet id, mission and arrival without persistent residue. Authenticated browser certification of the Fleet screen remains environment-blocked and must not be fabricated.

Durable technical segregation for the espionage engine should live in `docs/systems/README_ESPIONAGE_ENGINE.md`.

## 4. Rules for work

1. Recover this context and only the specialized documents relevant to the task.
2. Inspect the real repository/Git state and Supabase state when backend state matters.
3. Check whether a capability already exists before creating another path.
4. Preserve completed work; contradictions between documentation and implementation are findings to verify.
5. Do not duplicate canonical formulas or make the frontend authoritative.
6. OGameX informs comparison only; never copy its Laravel/PHP/ORM/routing architecture blindly.
7. Use bounded implementation/audit scopes and validate with the smallest relevant test.
8. Document durable discoveries in the specialized README first, then update this context only when operational
   state or an active decision changes.

### Mandatory verification-before-new-work gate

Before proposing, assigning or executing any new audit, investigation, implementation or agent mission, first verify whether the requested subject is already documented, tested, certified or otherwise explicitly closed in the current repository/context.

- **CLOSED / VERIFIED:** do not repeat the work.
- **OPEN but already investigated:** continue from the existing evidence; do not rerun the same audit.
- **PARTIALLY VERIFIED:** work only on the exact unverified residue.
- **UNRESOLVED PRODUCT DECISION:** do not silently convert technical evidence into a product decision.
- **NOT YET VERIFIED:** only then create a new audit/investigation scope.

The check must use the current repository state and the relevant specialized documentation, not memory or an older session assumption. If a prior report already establishes the requested result, treat that result as evidence and identify only what remains missing.

This gate exists specifically to prevent duplicate Cline/Copilot missions, repeated OGameX comparisons and wasted implementation/audit cycles.

### VERIFY BEFORE IMPLEMENT (normative)

Before proposing or executing any implementation of a mechanic, contract, function or technology, first verify
whether that mechanic already exists and is operative in LGI. The check must cover, as applicable: **real code
readers; consuming functions/RPCs; prerequisites and unlocks; migrations; tests; LIVE state; durable
documentation; history/seed/backup when relevant; and OGame/OGameX evidence when the goal is to determine the
contract.**

A technology that has no numeric modifier is **not automatically incomplete**: it may correctly have an
unlock/prerequisite role. If the contract is already implemented and operative, the result is:

```text
GAMEPLAY CONTRACT VERIFIED — NO IMPLEMENTATION REQUIRED
```

and **no code is modified, no migration is created and no redundant test is added**. Never send an
implementation mission for something already verified as implemented. If an effect is missing but the gameplay
contract is not determined by sufficient evidence, the result is:

```text
PRODUCT DECISION REQUIRED — STOP
```

Never invent mechanics.

```text
VERIFY BEFORE IMPLEMENT — GAMEPLAY (consolidated)
Before proposing any gameplay implementation:
1. verify whether LGI already has it (definition → readers → consumers → runtime path);
2. verify prerequisites/unlocks, migrations, tests, LIVE state and durable documentation;
3. consult OGameX when the mechanic is genuinely missing in LGI;
4. distinguish deliberate LGI custom mechanics from OGameX behaviour;
5. if a whole subsystem is missing, reconstruct the OGameX design first, then adapt it to LGI;
6. never invent an equivalent mechanic from intuition.

OGameX is the design reference for missing gameplay. LGI custom = the deliberate exception.
The user is the authority for any deviation from OGameX.
```

### Missing-contract / OGameX implementation rule

When L.G.I. requires a contract, function or subsystem that does **not yet exist**, OGameX must be consulted before designing the missing implementation. Use the current OGameX implementation to determine responsibility, lifecycle, inputs/outputs, ownership model, ordering and relevant failure/idempotency behavior.

The sequence is:

LGI existing invariants → OGameX equivalent/reference → LGI contract definition → human product decision where required → implementation → tests → verification.

OGameX remains a reference, never an authority or dependency. Do not copy Laravel/PHP/ORM/routing architecture or import game/balance semantics blindly. If OGameX contradicts an explicit L.G.I. contract or product decision, L.G.I. wins and the contradiction must be documented.

For an existing L.G.I. contract that has already been verified, do **not** reopen it merely because OGameX has an equivalent implementation. OGameX is primarily required for genuine L.G.I. gaps and for resolving documented architectural unknowns.

### OGameX AS DESIGN SOURCE — GAMEPLAY

When a gameplay mechanic does not exist in LGI yet, do **not** invent its behaviour. Before designing it:

1. Verify that it really is missing in LGI.
2. Consult OGameX as the structural/functional reference.
3. Reconstruct OGameX's contract and runtime (definition → readers → consumers → application point).
4. Adapt it to LGI's current architecture (PostgreSQL/RPC, `universe_clock`, explicit ownership, LGI modifiers).
5. Preserve the LGI custom mechanics that are deliberate: they are part of the project's own design and must be
   kept unless the user explicitly says otherwise.
6. Deviate from OGameX only when the user explicitly specifies it.

"Not present in LGI" does **NOT** mean "invent a solution". If OGameX already contains the mechanic, the design
must be derived from OGameX and adapted to LGI.

Product decisions decide **whether** LGI adopts/adapts a mechanic — they are not a licence to invent its
behaviour arbitrarily when a verifiable OGameX reference exists. Conversely, when the mechanic would require
introducing a subsystem LGI does not have, that is a product decision and not an implementation detail:
classify it `PRODUCT DECISION REQUIRED — STOP` and stop.

Worked example (full detail in [`systems/README_RESEARCH.md`](systems/README_RESEARCH.md) §13):
Intergalactic Research Network. OGameX's contract is verified (research-lab levels → effective lab → duration
denominator); LGI has no research-laboratory subsystem, so the pending decision is *whether LGI adopts/adapts
that verified OGameX model*, not *how IRN should behave*.

### Mandatory implementation-agent selection

Before **every task I give or propose to you**, I must explicitly decide whether the execution belongs to:

- **Cline + DeepSeek Flash 4.1 (with tokens):** complex/multi-file implementation, repository-wide-but-bounded audits,
  difficult debugging, Supabase/Git operations, security/ownership work, or tasks where cross-file reasoning materially
  reduces risk.
- **Copilot Pro:** small/localized implementation, mechanical refactors, focused TypeScript/CSS/UI changes and other
  bounded edits that do not require broad repository reasoning.

I must not leave this choice implicit. Every proposed task must state **Executor: Cline or Copilot** and, when Cline is
selected, also state **Model: DeepSeek Flash 4.1**, **Intelligence: None/Low/Medium/High/Extra**, **Expected cost:
LOW/MEDIUM/HIGH**, and a short reason. If Copilot is selected, the task must remain appropriately bounded for Copilot Pro.

The user may still use ChatGPT for architecture, interpretation, audit design and final verification; this gate concerns
which external implementation agent should execute the task.

The development workflow and tool-selection gate are defined in
[`docs/tools/README_DEVELOPMENT_WORKFLOW.md`](tools/README_DEVELOPMENT_WORKFLOW.md).

## 5. Active decisions

- Universe evolution is a separate temporal/domain layer; technology, mission and item modifiers do not belong
  in `calculate_universe_scaling(E)`.
- The seven implemented fleet missions use one canonical speed/travel/fuel pipeline.
- Engine technologies enter through `calculate_player_ship_speed` and
  `calculate_player_ship_fuel_consumption` only.
- Fuel reduction uses Lifeform `fuel_reduction_percent`; Hyperspace Technology is not a generic fuel discount.
- Energy Technology is a **fleet-independent economy modifier** (GAMEPLAY 01B, an LGI decision — not the
  OGameX Fusion Reactor formula): `calculate_planet_production` applies `+5 %` effective energy production per
  level (`base × (1 + 0.05 × level)`) exactly once, using the planet owner's `energy_technology` level. It
  reaches metal/crystal/deuterium only through the existing energy-balance factor. Detail:
  [`README_ECONOMY.md`](systems/README_ECONOMY.md).
- Plasma Technology is an **economy modifier on mined resources** (LGI rule, sourced from the classic
  reference already present in the repository): `calculate_planet_production` applies once, from the planet
  owner's level, `metal × (1 + 0.01 × level)`, `crystal × (1 + 0.0066 × level)` and
  `deuterium × (1 + 0.0033 × level)`. Energy is untouched, no floor is introduced, and level 0 is
  byte-identical to the previous behaviour. Detail: [`README_ECONOMY.md`](systems/README_ECONOMY.md).

**Gameplay technology status (decision memory — check here before re-auditing or implementing anything):**

```text
IMPLEMENTED — VERIFIED
  energy_technology   +5 % effective energy production per level (calculate_planet_production) · LIVE 20260923141520
  plasma_technology   metal ×(1+0.01·L) · crystal ×(1+0.0066·L) · deuterium ×(1+0.0033·L) (energy untouched) ·
                      LIVE 20260923192800

CONTRACT VERIFIED — NO IMPLEMENTATION REQUIRED
  laser_technology    unlock-only root tech: ion ≥5 · plasma ≥5 · weapons_technology ≥3 · light_laser ≥3 ·
                      heavy_laser ≥6 · 0 numeric readers · LGI, OGame classic and OGameX all agree it has no
                      numeric effect. Do NOT implement a numeric effect without an explicit product decision.
  ion_technology      unlock-only and already operative: ion_cannon ≥4 · cruiser ≥2 · plasma ≥5 · 0 numeric
                      readers. Its only quantitative reference rule (modern OGame template: +1 % demolition
                      refund per level) has NO application point: LGI has no demolition/cancel-refund mechanic
                      (0 functions/columns/tables), so that part is a PENDING PRODUCT DECISION, not a defect,
                      and was not implemented.
  graviton_technology unlock-only and already operative: `deathstar` requires it at level 1 (with shipyard 12,
                      hyperspace_technology 6, hyperspace_drive 7); it is the ONLY capped research
                      (`max_level = 1`), costs 0/0/0 (cost_factor 3) and requires energy_technology ≥ 12.
                      0 numeric readers, and the OGame reference describes it only narratively (a graviton
                      field able to destroy ships/moons → the Deathstar), so there is NO expected numeric
                      effect to implement. Observation (not an effect): the classic OGame cost of 300 000
                      energy cannot be expressed by LGI's research cost model (metal/crystal/deuterium only);
                      adopting it would be a product/schema decision, not a fix.

OPEN / INERT — REQUIRES AUDIT (0 code readers, contract not yet determined)
  (none — all 16 research definitions are now classified; check this block before reopening any of them)

AUDITED — PENDING PRODUCT DECISION (missing effect, no application point exists)
  astrophysics        Audited 2026-09-23; **CORRECTED 2026-09-30 — the "no colony-cap subsystem"
                      statement below was STALE and no longer holds.** LGI NOW HAS a colony-cap
                      subsystem: `calculate_max_colony_slots(player)` =
                      `1 + greatest(1, round(astro / 2))`, `check_colony_cap(player)` (owner-scoped,
                      returns allowed/reason/max_slots/current_planets/astrophysics_level), enforced at
                      BOTH dispatch (`start_colonize_fleet` → `COLONY_CAP_REACHED`) and arrival
                      (`resolve_colonize_arrival` → `check_colony_cap`), implemented in
                      `20260926210000_colony_cap_astrophysics` (migration
                      `20260930160000_planet_temperature_system` is unrelated). Verified LIVE
                      2026-09-30: astro 0 → max 2, astro 4 → max 3, astro 9 → max 6; a foreign session
                      reads `allowed=false, reason=PLAYER_NOT_OWNED_BY_AUTH_USER`. The certified
                      fixture is `supabase/tests/colony_cap.sql`. Astrophysics is
                      therefore NOT inert: it is a live, enforced mechanic. The original rule
                      (+1 colony slot per 2 levels) is the OGame reference and is honoured.
  computer_technology Audited 2026-09-23: 0 code readers, 0 player_research rows, root tech — but NOT inert:
                      it is a real unlock, `intergalactic_research_network` requires it at level ≥ 8. Its
                      documented effect (OGame snapshot: "Cada nivel … aumenta en uno el número máximo de
                      flotas"; LGI's own historical seed: "Increases the number of fleet missions that can be
                      controlled simultaneously") has NO application point: LGI has no fleet-slot cap at all —
                      the only slots are EXPEDITION slots, item-driven (`get_player_expedition_slots`,
                      `expedition_settings.bonus_expedition_slots`), and `start_fleet`/`start_fleet_mixed` only
                      enforce `EXPEDITION_SLOTS_FULL`. Implementing it would mean creating a fleet-slot
                      subsystem for every mission → PRODUCT DECISION, not a defect. Do not implement.
  intergalactic_research_network
                      Audited 2026-09-25 and CLOSED as an audit. LGI = inert: definition 240 000/400 000/
                      160 000 (cost factor 3, time factor 2, max NULL), prereqs computer 8 + hyperspace 8,
                      0 code readers, 0 consumers, 0 `player_research` rows, prerequisite of nothing, and the
                      canonical `calculate_research_time(id, level, universe)` has no planet/lab input.
                      OGameX DOES consume the level (own lab + the top `IRN` foreign labs of planets that meet
                      the technology's requirements → duration denominator), but LGI has no research-laboratory
                      subsystem and its duration contract is certified → `PRODUCT DECISION REQUIRED — STOP`,
                      do not implement. The pending decision is **whether LGI adopts/adapts the verified
                      OGameX model**, NOT how IRN should behave (rule: `OGameX AS DESIGN SOURCE — GAMEPLAY`).
                      Full detail, runtime trace and OGameX line numbers:
                      [`systems/README_RESEARCH.md`](systems/README_RESEARCH.md) §13 (canonical IRN record).

ALREADY IMPLEMENTED ELSEWHERE — do not re-audit (documented in their own READMEs)
  combustion_drive · impulse_drive · hyperspace_drive                     → fleet README §3 (speed + engine consumption)
  weapons_technology · shielding_technology · armour_technology           → combat README (attack / shield / hull)
  hyperspace_technology (cargo capacity) · espionage_technology (reports) → their domain READMEs
```
- Fleet return timing reuses the persisted outbound duration; it does not recalculate speed.
- ACS_HOLD is dispatched by ONE support dispatcher (`start_support_fleet`) through the canonical pipeline with
  `holding_fleet_speed`; `HOLDING` is a lifecycle state, never a player-facing mission, and `DEFEND` stays closed
  until the Combat Engine.
- ACS_HOLD support to a foreign planet requires an explicit, revocable, planet-scoped authorization granted by the
  destination owner; planet existence is never authorization, and no alliance/buddy system is invented.
- Identity onboarding is **email/password only** and is **LIVE** since 2026-09-21 (ledger
  `20260921073405_complete_email_identity_migration`): `public.provision_player(text,text)` exists
  (SECURITY DEFINER, `search_path = ''`, reuse-first/idempotent, EXECUTE only for `authenticated`), the
  `on_auth_user_created` trigger and `private.handle_new_auth_user()` are **dropped**, and
  `register_guest_player` is **dropped**. The canonical DEV identity is the email account
  `eab54987-af3a-4dba-bb7a-9530b64798b6` → `players.user_id` → **`DevPlayer`**
  (`aa1deb2d-3ed6-4350-922a-172d999b2af7`, HUMAN, `is_guest = false`), the only HUMAN player in LIVE.
  Verified end-to-end with a rolled-back authenticated session: `auth.uid()` resolved to the DEV email and
  `provision_player('ZZ-ShouldNotCreate')` returned the existing player without creating a second row.
  No claiming of existing (`user_id IS NULL`/AI/DevPlayer) players remains.
  Detail: [`README_IDENTITY_AND_ACCESS.md`](systems/README_IDENTITY_AND_ACCESS.md).
- Documentation detail is segregated; moving it to a specialized README is not deletion.
- **Research building prerequisites: MECHANISM IMPLEMENTED, content intentionally EMPTY (2026-09-25).**
  `research_building_prerequisites(research_id, building_id, required_level)` + shared helper
  `check_research_building_prerequisites(planet_id, research_id)`, consumed by BOTH authorities —
  `can_start_research` (payload + `prerequisites_met`, now with a `kind` discriminator) and `start_research`
  (rejection with `RESEARCH_REQUIREMENTS_NOT_MET`, zero mutation) — evaluated on the planet that starts the
  research (OGameX parity). Migration `20260925192948_research_building_prerequisites_mechanism`.
  **(SUPERSEDED 2026-09-26 — the laboratory and its 16 gates are SHIPPED, see the entry below; the "14" was an
  arithmetic slip.)** As recorded on 2026-09-25 the gates were INACTIVE: LGI had no research laboratory and
  activating them was a **PRODUCT DECISION**. Regression: `supabase/tests/research_building_prerequisites.sql`
  **21 PASS + 1 INFO LIVE (re-run 2026-09-27)**
  (incl. an equivalence proof over all 16 researches). Detail:
  [`systems/README_RESEARCH.md`](systems/README_RESEARCH.md) §14.
- **Expeditions END-TO-END (2026-09-25).** `20260925202506` replicó la configuración de expedición en el
  universo ACTIVO (`cf021ece`): los pesos que el propio proyecto ya había definido (mismos valores; provenance
  `20260912105222_restore_expedition_weights_after_timing_audit` + las migraciones de DM/comerciante/objetos),
  sin inventar ninguno. Endureció `use_expedition_item` (`auth.uid()` → `players.user_id` → jugador; EXECUTE
  `authenticated`; `FOR UPDATE` en el stack) y conectó `expedition_settings.bonus_expedition_slots`, de modo que
  los objetos premiados ya activan sus seis efectos (producción, almacén, investigación, flota, construcción,
  slots de expedición) con caducidad real. Se añadieron tres contratos de lectura owner-scoped
  (`get_player_expedition_reports`, `get_player_expedition_item_status`, `get_player_expedition_slot_status`)
  porque las tablas de expedición están cerradas al cliente por política, y la UI de Expediciones y Mensajes los
  consume (resultados distinguen recursos, naves, materia oscura, objetos, comerciante, combate, pérdidas,
  retraso, aceleración). Regresión: `supabase/tests/expedition_items_and_slots.sql` **22/22 PASS LIVE**,
  `fleet_cargo_lifecycle.sql` 18/18, `research_building_prerequisites.sql` 21/21. Detalle:
  [`systems/README_FLEET_ENGINE.md`](systems/README_FLEET_ENGINE.md) §26 y
  [`systems/README_ECONOMY.md`](systems/README_ECONOMY.md).
- Migration provenance is governed by the [Migration Provenance Gate](MIGRATION_PROVENANCE_GATE.md).
  `db push` remains **BLOCKED**, but the gate's stated reason was corrected on 2026-09-21 by direct
  measurement: the four LIVE-only versions `20260919055336`, `20260919061454`, `20260919062509` and
  `20260919070020` **do** retain full payloads in `supabase_migrations.schema_migrations.statements`
  (two of them are already byte-identical to local files: `20260919080000_propagate_combat_participants_v2`
  and `20260919090000_harden_start_ship_auth`). The surviving blocker is a **version-prefix drift**
  (`20260919060000/070000/080000/090000` locally vs the four ledger versions) plus the local-only files
  `20260919180000` and `20260920010000`. Never reconstruct lost SQL, create same-version placeholders,
  mark migrations reverted, or edit the migration ledger.
- Fleet Engine remains **OPEN — HISTORICAL GAP**. Local controlled convergence now has a bounded artifact
  for canonical mission-class routing in `start_fleet`/`start_fleet_mixed` and player-aware ship speed plus
  mission class in `start_colonize_fleet`; this is not LIVE parity. The fuel helper body,
  LIVE-only migrations, exact LIVE dispatcher payloads and expedition convergence remain blocked.

## 6. CLOSED

- Mission Modifiers / Fleet Engine audit is functionally closed in LIVE for:
  - mission classifier and PEACEFUL/WAR routing;
  - `start_fleet`, `start_fleet_mixed` and `start_colonize_fleet`;
  - propulsion and technology routing;
  - evolution ordering;
  - Lifeform and Item modifier ordering;
  - canonical travel-time pipeline;
  - fuel ordering and single fuel-reduction application;
  - movement lifecycle, return timing and duplicate-run protection.
- The three dispatchers converge on the same canonical pipeline. The mission-speed helper remains internal.
- Legacy fleet calculation routes were retired after consumer/body checks; no legacy bypass is part of an
  implemented mission path.
- Universe Evolution engine, monitor and production deployment validation are closed for their current scope.
- Ownership hardening and the current single-attacker combat participant propagation are closed for their
  certified scopes.
- **Fleet modifier pipeline CLOSED (2026-09-22, LIVE measured)**: the four dispatchers are the only callers of
  `calculate_fleet_travel_time` and `calculate_player_fleet_fuel_for_distance`; every canonical step occurs
  exactly once per dispatcher; `fuel_reduction` lives in one helper; **no double modifier and no bypass**.
  Detail: [`UNIVERSE_RATE_AND_FLEET_ENGINE_MONITOR.md`](UNIVERSE_RATE_AND_FLEET_ENGINE_MONITOR.md) §A.
- **Support authorization CLOSED (2026-09-22)**: `20260922052432_fix_support_authorization_conflict` repaired
  `grant_planet_support_authorization` (42702 ambiguous conflict target). `fleet_acs_hold_lifecycle.sql`
  **50/50** and `fleet_support_authorization_chain.sql` **13/13** now pass LIVE.
- **Research certification CLOSED (2026-09-21)** for the audited chain: availability (`can_start_research`
  is the single authoritative client contract), prerequisites (16 LIVE rows; SECDEF `can_research`),
  cost and time (single-sourced, verified to 4 decimals against LIVE), queue semantics, atomic
  single charge, ownership, persistent level (`player_research`) and the REAL production completion path
  (`process_universe_heartbeat → process_universe_clock → process_universe_tick → process_planet_tick →
  complete_research`). `complete_research` is idempotent since `20260921140916`; the client-facing
  `research_action_candidates` view was retired as a client contract by `20260921140925`; the lifecycle
  suite (27 gated + 12 contract assertions) is runnable and its fixture accepts `DevPlayer`.
  Detail: [`README_RESEARCH.md`](systems/README_RESEARCH.md).
- **Research Laboratory · 16 OGameX gates · IRN SHIPPED (2026-09-26, owner-approved)**: `20260926180000`
  adds the `research_lab` building (200/400/200, factor 2, PLANET-only), the 16 `research_lab` gates verbatim
  from OGameX `ResearchObjects`, `get_research_network_lab_level` and the laboratory-aware
  `calculate_research_time(player,planet,research,level)` overload. Consequence (deliberate): every technology
  now needs a Laboratory on the planet that starts it. The **2026-09-27 audit** fixed the fixture precondition
  that activation had invalidated in `research_lifecycle.sql` and `research_building_prerequisites.sql`, and
  re-verified the whole lifecycle LIVE (11/11: availability, prerequisites, resources, cost, queue, production
  completion, level increment, next level, ownership, NULL auth, idempotency). Detail:
  [`README_RESEARCH.md`](systems/README_RESEARCH.md) §16.
- **Research certification COMPLETE as FILES (2026-09-27)**: the three Research suites now run **verbatim against
  LIVE** through the project's Management-API query channel — `research_lab_and_irn.sql` **14 PASS + 1 INFO**
  (assertions 9b *"fewer planets than IRN"* and 9c *ownership* added: IRN 10 with only 2 eligible labs → 12, and a
  foreign player's lab 20 never joins the network), `research_building_prerequisites.sql` **21 PASS + 1 INFO**,
  `research_lifecycle.sql` **27 gated + 12 contract PASS** — zero residue (590 planets, 0 labs LIVE). Two
  **harness** defects found by the file run were fixed: the lifecycle fixture now reproduces the worker context
  (`auth.uid() IS NULL`) around `process_universe_tick` — the tick walks **the whole universe** and
  `calculate_planet_storage`'s ownership gate rejected every foreign planet, killing the suite before its report
  (production unaffected: the chain is postgres/service_role only) — and its contract assertion 3 now counts
  **both** prerequisite dimensions, because `can_start_research` has exposed the building dimension since
  `20260925192948`. **`researching while the Research Lab is upgrading`: ADAPTED as OGameX state/UI (2026-09-27,
  migration `20260927014725`)**: new owner-scoped read contract `get_player_research_lab_status()` (empire-wide
  `research_lab_upgrading` + `research_in_progress`, with the upgrading planet/target/finish) consumed by the
  Research and Buildings views to disable the action — **no new server gate**: `can_start_research`,
  `start_research` and `start_building` are untouched and still accept it, exactly like OGameX
  (`research-item.blade.php` `data-status="disabled"`; `ResearchController::addBuildRequest` checks vacation +
  CSRF only). Regression: `supabase/tests/research_lab_upgrading_status.sql` **10 PASS + 1 INFO LIVE**.
  **Enforcement de cola IMPLEMENTADO (2026-09-27, migración `20260927015502`)**: guard BEFORE INSERT en
  `building_queue` (`enforce_research_lab_research_interaction`) que rechaza ampliación/bajada del laboratorio con
  `BUILDING_BLOCKED_BY_ACTIVE_RESEARCH` antes de cobrar — equivalente LGI a la cancelación de OGameX
  (`BuildingQueueService` 207-210 y 398-401/416-421) —, declarado además en `evaluate_building_start_internal` y en
  `inspect_demolition` (bloqueo en bloque de cualquier demolición del laboratorio con investigación en curso).
  `complete_building` y los procesadores siguen intactos: un item ya en vuelo termina igual que en OGameX.
  Regresión: `supabase/tests/research_lab_upgrading_status.sql` **14 PASS + 1 INFO LIVE**. Detail:
  [`README_RESEARCH.md`](systems/README_RESEARCH.md) §16.
- **Defense certification CLOSED (2026-09-21)** for the CORE mechanic: definitions (8 LIVE rows), count-based cost
  (`calculate_defense_cost`), build time (base / shipyard level / universe construction rate × √E), prerequisites,
  availability (`can_build_defense`, now SECURITY DEFINER with an ownership gate), atomic `start_defense` charge on
  the shared shipyard+defense production line, planet-scoped queue, and completion via
  `process_defense_queue(planet)` from the planet tick. Two LIVE defects were fixed forward-only:
  `20260921161247_lock_down_process_defense_queue_until` (an internal SECURITY DEFINER processor was
  PUBLIC-executable with a caller-supplied time bound, so any client — including `anon` — could force-complete any
  planet's defense construction, bypassing build time) and `20260921161304_fix_can_build_defense_client_contract`
  (the availability contract was SECURITY INVOKER over client-unreadable objects and raised for the real client
  role). `supabase/tests/shipyard_defense_lifecycle.sql` is runnable again (LIVE-resolved fixture) and now carries
  15 assertions including three client-role ones — 15/15 PASS LIVE. Detail:
  [`README_DEFENSE_ENGINE.md`](systems/README_DEFENSE_ENGINE.md).
- **Shipyard client contract CLOSED (2026-09-22)** — `20260922050734_shipyard_availability_contract_definer`.
  `can_build_ship` was the last availability contract still declared SECURITY INVOKER while depending on
  `check_ship_requirements` (`postgres`/`service_role` only) and `calculate_ship_build_time` → `universes`
  (no client `SELECT`): through the real client role it raised `42501`, so the Shipyard view could never load
  authoritative availability. It also had **no identity gate**, unlike `can_build_defense` /
  `can_start_research`. Both defects were closed together (`SECURITY DEFINER` + `auth.uid()` +
  `PLAYER_NOT_OWNED`); the ACL now mirrors `can_build_defense` and **nothing was widened** (`universes`
  SELECT and `check_ship_requirements` EXECUTE remain closed). Frontend: `productionInfo` is the only source
  of cost/time/allowed/reason (no fallback to definition metadata), the button respects `allowed`, the
  bounded completion refresh (one `setTimeout` + `clearTimeout`) now covers Shipyard, and the dead `QUEUED`
  queue filter was removed there. Suite `shipyard_defense_lifecycle.sql` → **25/25 PASS LIVE** (the old
  "12/12" label undercounted 15 assertions). Browser certification is **NOT done** — checklist in
  [`README_SHIPYARD_DEFENSE.md`](systems/README_SHIPYARD_DEFENSE.md).
- **Combat Engine: PHASE 0 AUDIT COMPLETE (read-only, 2026-09-21) — OPEN, NOT certified.** The engine already
  exists and is production-reachable; the previous statement that "no combat formula exists yet" was a
  documentation error and is corrected here. Authoritative path:
  `pg_cron(run_fleet_worker, 1s) → process_fleet_movements → resolve_attack_arrival → resolve_combat →
  initialize_individual_combat_units → run_expedition_combat → process_combat_round_v2` (≤6 rounds, shots +
  rapidfire + per-target damage ledger + shield bounce/explosion) `→ sync_combat_battle_final_counts →
  apply_attack_loot → repair_defenses_after_combat → create_combat_debris → fleet RETURNING`; technologies enter
  only through the certified `get_combat_ship_*` / `get_combat_defense_*` readers (`+10 %` per level, snapshotted
  at battle creation); replay safety rests on `combat_battles.ux_combat_battles_one_per_fleet`, the fleet status
  gate and per-battle unique keys for rounds, debris and repairs. Eight legacy combat functions plus the
  `combat_unit_state` table are orphaned but still present in LIVE; they are inert, not a second architecture.
  **Phase 3 CLOSED (2026-09-21) — COMBAT BASE ENGINE CERTIFIED** for the single-attacker model
  (one attacking fleet vs one planet) plus the expedition combat branch, on the deployed chain
  `pg_cron(1s) → run_fleet_worker → process_fleet_movements → resolve_attack_arrival → resolve_combat →
  units → ≤6 rounds → losses → survivors → loot → repair → debris → RETURNING`. Certification is based on
  a read-only evidence matrix (deployed definitions + LIVE observation + re-run fixtures), **zero
  implementation changes**: authoritative entry proven (single chain, exactly three battle creators, entry
  points not client-callable), participant/unit ownership proven (every unit insert carries
  `participant_id`, `ENEMY` supported), canonical statistics proven (six readers with +10 %/level; no raw
  stat feeds units), round engine invariants proven (≤6 rounds, snapshots, one target per alive unit,
  rapidfire, shield bounce/absorption, 70 % explosion, shield regen, persistent hull, winner/draw),
  losses/loot/repair/debris proven, replay/idempotency proven, worker per-fleet isolation proven by
  fixture (production shows 1,765 healthy runs/30 min and 0 failures), and the authenticated battle-report
  contract proven (raw tables still closed). Regression: attack 12/12, expedition 10/10, report 7/7,
  worker 8/8, debris 5/5 (all LIVE), plus `tsc -b` and `npm run build`. **DG-07 decided: non-blocking** —
  the 1,342 orphan rows belong to 17 deleted battles, no reader touches those tables (the report contract
  does not either), and the `NOT VALID` FKs do reject new orphans (probe-proven), so no deletion or
  validation was performed. Certified scope excludes ACS/DEFEND/multi-fleet, seeded determinism, shield-dome
  rules and the alien-technology balance item (proven isolated to the expedition branch). No P0/P1/P2
  defect remains open.
  Detail: [`README_COMBAT_ENGINE.md`](systems/README_COMBAT_ENGINE.md) §14 (Phase 0), §15 (Phase 1),
  §16 (Phase 2) and §17 (Phase 3 certification evidence).
  **Phase 4A CLOSED (2026-09-21) — participant / battle identity foundation** (three migrations
  `20260922035055` unit/snapshot uniqueness, `20260922035147` target identity, `20260922035253` loss
  identity + unit initialisation): `combat_battles.fleet_id` is now explicitly documented as the
  *initiating* fleet and per-fleet replay key, both unit/snapshot unique keys are participant-aware
  (the silent snapshot drop is gone), `resolve_pending_target_damage` / `process_combat_round_v2` carry
  `participant_id` in the target identity, both loss readers return `participant_id`, and the initialiser
  iterates `ATTACKER`/`FLEET` participants. Two attacking fleets fielding the same ship type are now two
  distinct units end-to-end. Evidence: new collision fixture
  `supabase/tests/combat_participant_identity_collision.sql` **13/13 PASS** and the certified suites
  re-run **42/42 PASS** (attack 12, expedition 10, report 7, worker 8, debris 5), LIVE residue NONE, no
  formula/balance/gameplay/UI change, ACS and DEFEND still not implemented. Detail: §19.
- Lifeforms, Items, Auction, Merchant, Alliance and Officers remain future **UPDATE** features and must not be
  started; lifeform-specific combat effects stay deferred to a later engine version.

Evidence and detailed tests remain in
[`docs/systems/README_FLEET_ENGINE.md`](systems/README_FLEET_ENGINE.md), not in this file.

- **Expedition RETURN leg CLOSED (2026-10-01, `INDEPENDENT_GAP_CLOSURE`)** — CRITICAL gap, deterministic.
  `resolve_expedition_return(uuid)` RETURNS TABLE(..., `status text`), so `status` was **both** a PL/pgSQL
  OUT variable and a `fleet_movements` column; its final `UPDATE ... WHERE id = p_fleet_id AND status =
  'RETURNING'` was rejected on **every** execution with `ERROR 42702 column reference "status" is
  ambiguous` (a plan-time error, not a race). Because the worker downgrades any per-fleet error to
  `raise warning 'FLEET_RESOLUTION_FAILED'`, **100 % of expedition returns were dead**: the movement never
  left `RETURNING`, its ships (already debited at dispatch) were destroyed, and — since
  `get_player_fleet_slots` counts every movement not in `('COMPLETED','CANCELLED')` — each expedition
  permanently consumed a fleet slot (a total fleet lock at `computer_technology` 0). LIVE evidence: one
  movement stuck **13 h** with 5 `large_cargo`. Fixed by `20261001070000_fix_ambiguous_status_in_expedition_return.sql`
  (LIVE version `20261001193223`), an anchored splice that adds the table alias `AS fm` — exactly the
  convention of its four siblings `resolve_transport_arrival` / `resolve_deploy_arrival` /
  `resolve_colonize_arrival` / `resolve_espionage_arrival`, which all already aliased. The OUT parameter
  was deliberately **not** renamed (`status` is part of the published column list). A corpus-wide sweep
  of all 56 public RPCs found this to be the **only** function with an OUT-parameter/column collision;
  `recall_fleet` is safe precisely because its OUT parameters are `out_*`-prefixed. Regression
  `expedition_return_ambiguous_status_regression.sql` → **15/15 PASS**.
- **RECYCLE arrival CLOSED (2026-10-01, `INDEPENDENT_GAP_CLOSURE`)** — HIGH gap. `collect_debris` refuses a
  target with nothing left (`'No debris field at …'` when the row is gone — the first recycler drains the
  field and `collect_debris` itself DELETEs the row — and `'Debris field is empty'` at 0/0). The worker
  downgraded that to a WARNING, so a recycler whose field was emptied by another recycler retried
  **forever** in `OUTBOUND`: ships destroyed and a fleet slot consumed permanently. Reachable in ordinary
  play, not by exotic timing — `start_fleet_mixed` picks the RECYCLE target server-side (nearest field with
  `metal>0 OR crystal>0`) and does **not** reserve it. Measured before the fix, through the real worker:
  emptied field → `OUTBOUND`; deleted field → `OUTBOUND`. The semantics were **read, not invented**: OGameX
  `RecycleMission::processArrival()` harvests whatever the field holds (zero is legal) and ALWAYS calls
  `startReturn()`; LGI already applied that same rule to the structurally identical case in
  `resolve_colonize_arrival`. Fixed by `20261001060000_fix_stuck_recycle_fleet_empty_debris_field.sql`
  (LIVE version `20261001192015`): the RECYCLE branch of `process_fleet_movements` absorbs **exactly** those
  two outcomes as "collected 0" and follows the already certified success path; every other error is
  re-raised so a genuine defect stays observable. Regression
  `recycle_fleet_empty_field_regression.sql` → **19/19 PASS**, including the negative control (an unrelated
  refusal still aborts the fleet) and the arithmetic control (what leaves the field is exactly what
  reaches the origin planet).

## 7. OPEN

### OPEN — PARTIAL: ACS / HOLDING / DEFEND

Decision (2026-09-19): **ACS_HOLD Fase A implemented in the backend**; `DEFEND` remains closed.

**Boundary kept explicit (2026-09-22):** the ACS_HOLD **transport** is now reachable end-to-end (authorization
+ dispatch + hold lifecycle verified LIVE, 50/50 + 13/13). That is **not** ACS gameplay: ACS grouping,
multi-attacker settlement, per-fleet loot/survivors, late joins and ACS UI remain **NOT IMPLEMENTED**, and the
engine still creates **0** `DEFENDER/FLEET` participants and refuses to settle a battle it cannot attribute.
Never report `transport reachable` as `ACS implemented`.

**Combat product-gate package (2026-09-22)** — the decision record is `README_COMBAT_ENGINE` **§22**
(§21 holds the option analysis; §22 holds the decision, the settlement contract, the exact implementation
boundary and the future test plan). Status:

- `PG-08` survivor attribution → **per-participant** · `DECIDED — READY FOR IMPLEMENTATION`.
  Architecture-determined, not a free choice: pooling survivors would move ships between players, and
  `fleet_movement_ships` (`UNIQUE(fleet_id, ship_id)`, `CHECK(quantity > 0)`) is an owned asset of one
  player (§22.2). *Ratification pending.*
- `PG-09` loot-capacity source → **`DECIDED + IMPLEMENTED`** (2026-09-22, migration `20260922060013`). [CORRECTED 2026-09-28: the `UNRESOLVED PRODUCT DECISION` wording inherited from §22.6 is SUPERSEDED by README_COMBAT_ENGINE §24, which implemented it the same day. See §23.12 for the reconciliation.] Surviving vs original
  composition are both already persisted, so the architecture excludes neither; it is a balance rule.
- `PG-10` loot recipient / allocation → **`UNRESOLVED PRODUCT DECISION`** (§22.7). Entitlement and the
  deterministic allocation rule (plus rounding/remainder) are separate questions; LGI has no player-level
  resource pool, so loot is always carried by a fleet to that fleet's origin planet.
- `PG-17` defending-fleet lifecycle → **the hold contract is preserved** · `DECIDED — READY FOR
  IMPLEMENTATION` (§22.3): settlement writes a defending participant's survivors back to its own fleet and
  leaves `status` and `holding_until` untouched. *Ratification pending.* The **producer** contract (who may
  hold) stays a separate future mission.
- `PG-18` battle-header defender counters → **planet-scoped** · `DECIDED — READY FOR IMPLEMENTATION`
  (§22.3): adding a `participant_type='PLANET'` filter is the only option that keeps `defender_ships_before`
  (planet-only) coherent with `defender_ships_after` **and** preserves the certified report contract.
  *Ratification pending.*

**ACS SETTLEMENT IMPLEMENTED — 2026-09-22** (migration `20260922060013_acs_settlement_participant_model`,
forward-only, LIVE applied, repo file content-identical, **no schema change**). All five gates are now
implemented as decided: per-participant survivor attribution, battle-level settlement resolution
(participant lookup with the DG-10 fallback), loot capacity from the ORIGINAL combined attacker
composition, entitlement + proportional-to-surviving-capacity allocation, the defending-fleet hold
preserved, and planet-scoped defender counters. Details, the PG-10 rounding convention, the ACL evidence and
the intentional D11 test change: `README_COMBAT_ENGINE` **§24**.

- **ACS participant settlement replay residue (H3) → CLOSED / VERIFIED (2026-09-23).** LIVE applied the fix as the
  server-versioned migration `20260923095315_fix_participant_settlement_replay` (forward-only, one-shot), and the
  local repository file carries that exact ledger version. `resolve_attack_arrival(uuid)` now resolves the
  early-return path of a settled non-initiating participant through `combat_battle_participants.fleet_id` for
  `ATTACKER/FLEET` rows, keeping the historic `combat_battles.fleet_id` anchor as fallback, and it still **fails
  closed** (`Attack fleet % has no combat battle`) when no battle exists. The change is confined to that
  early-return block: no settlement, ACS grouping, late-join, recall, DEFEND or HOLDING semantics were touched, and
  the RPC surface was **not widened** (`anon` no EXECUTE · `authenticated` no EXECUTE · `service_role` EXECUTE ·
  SECURITY INVOKER · one signature, one overload). The migration applies the patch with an
  **EOL-agnostic, fail-closed substitution** (fragments canonicalised to LF, then matched to the body's own style
  so the stored LF line endings are preserved; an exactly-one-match guard precedes the replacement) — verified in
  LIVE. `supabase/tests/combat_acs_settlement.sql` was executed LIVE inside its `BEGIN … ROLLBACK` transaction:
  **19/19 PASS**, including **H3** (a non-initiating participant replay returns the existing battle) and **H2** (no
  second battle is created); the rollback left **zero residue** in the combat, fleet and temporary objects it
  touched. Detail: `README_COMBAT_ENGINE` **§24.7**.

  This closeout changes nothing else: ACS grouping/dispatch, the producer contract, late-join/withdrawal, DEFEND
  authorization and semantics, HOLDING duration, PG-09 loot capacity and PG-10 loot recipient/allocation remain
  **exactly as recorded above** (open gates/product decisions) — none of them is closed, reopened or altered here.

**Still NOT implemented:** a producer (nothing creates a `DEFENDER/FLEET` participant or joins a fleet to an
existing battle), ACS grouping/dispatch, DEFEND dispatch, withdrawal/late-join rules and the ACS/DEFEND UI.

**BUG / OPEN:** the exact OGameX `lootShare` arithmetic could not be read from this environment, so LGI uses
its own documented rounding convention (floor per participant per resource; the planet is debited only by what
was credited, so nothing is created or destroyed and the single-participant case is byte-identical to the
certified behaviour). The convention is isolated so a faithful OGameX adaptation can replace it later.

Implemented:

- single support dispatcher `start_support_fleet(...)` (`ACS_HOLD` only) on the canonical fleet pipeline with
  `holding_fleet_speed`;
- explicit, revocable destination-owner authorization (`planet_support_authorizations`) — no alliance/buddy system
  invented and no `planet exists → allowed` bypass;
- `holding_until` as an absolute UTC window, enforced as future and strictly after `arrives_at`;
- durable lifecycle `OUTBOUND → ARRIVED → HOLDING → RETURNING → COMPLETED` in the existing worker;
- per-request idempotency key preventing a duplicated dispatch from double-deducting ships/fuel;
- forward correction of the legacy constraints that silently blocked every support row (`README_FLEET_ENGINE` §22.1).

Not implemented and still open:

- `DEFEND` and ACS combat integration / multi-defender settlement → still **OPEN**; since Phase 4B the
  combat-side blocker is narrowed to multi-defender settlement plus the four blocking product decisions
  (survivor attribution, loot capacity, defending-fleet return, battle-header defender counters) —
  `README_COMBAT_ENGINE` §20.5/§20.13. `DEFENDER/FLEET` is now representable by the engine and settlement
  fails closed until those decisions exist;
- holding fuel → **product decision pending** (not invented);
- maximum holding duration → **product decision pending** (not hardcoded);
- support recall during outbound/holding;
- UI (the future selector is `ACS_HOLD` + `DEFEND`; DEFEND stays closed);
- browser certification of the ACS_HOLD flow. **The SQL test now runs and passes LIVE**: `fleet_acs_hold_lifecycle.sql` → 50/50, plus `fleet_support_authorization_chain.sql` → 13/13 (new).
- **BLOCKER CLOSED 2026-09-22** — `20260922052432_fix_support_authorization_conflict`.
  `grant_planet_support_authorization` raised `42702 :: column reference "destination_planet_id" is
  ambiguous`: the function's OUT-parameter names collided with its own
  `on conflict (destination_planet_id, guest_player_id)` target list, so **no support authorization could
  ever be created** and `start_support_fleet` always raised `SUPPORT_AUTHORIZATION_REQUIRED`. The whole
  ACS_HOLD dispatch was therefore unreachable end-to-end. The fix names the unique constraint
  (`on conflict on constraint planet_support_authorizations_destination_guest_key`), which was proven
  unambiguous by a rollback-safe A/B reproduction before applying it; signature, `SECURITY DEFINER`,
  `search_path`, ACL (no widening), every authorization check and the upsert semantics are unchanged.
  **Verified LIVE:** `fleet_acs_hold_lifecycle.sql` → **50/50 PASS** (previously unrunnable) and the new
  `fleet_support_authorization_chain.sql` → **13/13 PASS** (grant → authorized dispatch → movement →
  revoke → rejected). The `LOCAL_ONLY / NOT_DEPLOYED / BLOCKED`
  `20260919180000_fix_planet_support_authorization_ambiguity.sql` does **not** fix this defect (it
  re-declares the same ambiguous form); it stays blocked and untouched.
  **This does NOT mean ACS gameplay exists** — see the next bullet.

### CLOSED — precisión decimal en `collect_debris` (B1/B2/B3 certificadas)

Registrado el 2026-10-01 por `INDEPENDENT_GAP_CLOSURE` como OPEN menor. **CERRADO 2026-10-02.**

**Causa raíz (medida, no supuesta).** `debris_fields.metal`/`.crystal` son `numeric` **sin precisión
declarada**; las filas LIVE llevan escala 20. PostgreSQL trunca la división a `select_div_scale`
(16 dígitos significativos), así que `crystal / total` se recorta y al multiplicarlo de vuelta por la
capacidad **no reproduce el monto original**. El resto se quedaba en el campo como polvo POSITIVO, el
`DELETE ... WHERE metal <= 0 AND crystal <= 0` **nunca disparaba**, la fila sobrevivía y
`get_recyclable_debris_status()` respondía `available = true` sobre un campo vacío. Sobre el escenario
de auditoría (40000 M / 20000 C, capacidad 60000 — drenaje total): residuo `0.00000000000000020000`.
Simuladas **113 212** drenos completos (totales hasta 3.9e8): **99,95 %** dejaban residuo; peor
`|residuo| = 1.87002e-12`. **2e-17 NO es un umbral universal**: el polvo es lineal con el total.

**Solución aplicada — `20261002000000_collect_debris_exact_full_drain.sql`, DESPLEGADA EN LIVE.**
En el call-site de `collect_debris`, cuando la flota puede drenar el campo
(`v_remaining_capacity >= v_total_debris`) la respuesta exacta es «tomarlo todo», así que ahora se toma
**verbatim, sin división**: rama `CASE` nueva para metal y cristal. La rama de **recogida parcial es la
expresión ORIGINAL carácter por carácter** — verificado sobre **437 211** drenos parciales simulados:
**0 filas difieren, diferencia máxima exactamente 0**. La regla proporcional, la cota de capacidad y
los `LEAST` quedan intactos. Lado lectura: `get_recyclable_debris_status` usa `> 1e-9` en vez de `> 0`,
como guarda de filas anteriores al arreglo.

**Ledger:** fichero local `20261002000000`; LIVE registró la versión **`20261002004147`**. Es el
**drift de provenance ya documentado** (cada `apply_migration` registra su propia versión).
**No renombrar, no marcar revertida, no tocar el ledger.**

**Recogida parcial y reglas de reciclaje CONFIRMADAS INTACTAS:** `calculate_recycler_capacity`
(`235910c7dd6a3b31ec7ee712af2d24f1`) y `start_fleet_mixed` (`611d107dacf0e3869d162d11fb63fcf1`)
siguen **byte-idénticos**; el comportamiento del reciclador agotado de `20261001060000`
(`'Debris field is empty'` / `'No debris field at'`) sigue presente en el worker. Sin cambios de
fórmula, capacidades, ACL ni contrato.

### Other OPEN work

- **Combat Engine: CERTIFIED (2026-09-21) for the base engine** — one attacking fleet vs one planet
  (ATTACK) plus the expedition combat branch, on the deployed worker chain, with the authenticated
  battle-report contract. Phases 0 (audit), 1 (CB-01/CB-02/CB-05/CB-06), 2 (DG-01/CB-03/CB-04), 3
  (read-only certification evidence) and 4/4A are closed; DG-07 is decided as non-blocking historical residue.
  Five runnable combat suites are LIVE-verified: attack 12/12, expedition **11/11**, report 7/7, worker 8/8,
  debris 5/5 = **43/43** (the earlier "42/42" undercounted the expedition fixture — corrected in
  `README_COMBAT_ENGINE` §20.10), plus the Phase 4A collision fixture 13/13 and the new Phase 4B fixture 16/16.
  **Phase 4B — ACS/DEFEND architecture audit + DEFENDER/FLEET representation: CLOSED (2026-09-22).**
  Migration `20260922043604_defender_fleet_participant_representation` (no schema change was required):
  `initialize_individual_combat_units` now materialises every `DEFENDER/FLEET` participant with its own
  `participant_id` and its own owner technology context (the mirror of the Phase 4A attacker branch), and
  `resolve_attack_arrival` now **fails closed** (`MULTI_DEFENDER_SETTLEMENT_NOT_DEFINED`) instead of silently
  ignoring defending fleets. Both changes are inert today: no function creates a `DEFENDER/FLEET` participant
  (`resolve_combat`, `resolve_expedition_pirates`, `resolve_expedition_aliens` are the only participant
  producers). Still NOT IMPLEMENTED — all product decisions, not defects: ACS grouping/dispatch, DEFEND
  dispatch, multi-fleet settlement, per-fleet survivor and loot attribution, per-fleet report payload,
  ACS/DEFEND UI. Blocking product decisions: survivor attribution, loot-capacity attribution,
  defending-fleet return rule, battle-header defender counters (`README_COMBAT_ENGINE` §20.13:
  PG-08/PG-09/PG-17/PG-18).
  Detail: [`README_COMBAT_ENGINE.md`](systems/README_COMBAT_ENGINE.md) §14/§15/§16/§17/§19/§20; the operational
  summary is the combat bullet in §5.

- Guest decommission: **LIVE, PARTIAL — 2026-09-21**. The identity core is applied
  (`20260921073405_complete_email_identity_migration`): `provision_player` created, `on_auth_user_created`
  and `private.handle_new_auth_user()` dropped, `register_guest_player` dropped. Verified LIVE after the
  fact: **1** auth user (the DEV email), **0** anonymous users, **0** `is_guest = true` players, **0** AI
  players holding a `user_id`. Still OPEN: the **5** policies that still carry an `is_guest` branch
  (`building_queue_select_access`, `defense_queue_owner_read`, `planet_resources_select_access`,
  `player_research_select_access`, `research_queue_select_access`), the `enforce_player_write_access`
  guest branch, the `players.is_guest` column (0 rows true), and the
  `early_tester_registrations` / `player_achievements` product decision. The guest policy surface itself is
  **gone**: `*_select_guest` policies remaining in LIVE = **0**, and **no policy anywhere carries a
  hardcoded DEV UUID or the literal `DevPlayer`**.
  Guest-specific registration, authorization branches, guest RLS policies and `players.is_guest` remain
  candidates for removal or controlled reimplementation only where required by the final login/password
  architecture: do not delete guest infrastructure blindly — map all LIVE consumers and dependencies first,
  then remove/reimplement forward-only (`initialize_player_research` verification is CLOSED).
- **DevPlayer:** exactly **one** DevPlayer/HUMAN test account is intended to remain. `playerA` was selected
  for removal together with its child/parent ownership graph. Measured 2026-09-21: `DevPlayer`
  (`aa1deb2d-3ed6-4350-922a-172d999b2af7`) is the only HUMAN player and **`playerA` does not exist**
  (0 players match that name); the AI/user reassignments observed earlier were reconciled (released to
  `user_id = NULL`, not destroyed).
- **AI:** do not implement or redesign AI yet. Before the AI phase, compare the current AI schema/call graph
  with OGameX and other suitable OGame-like clones to identify the expected structure, schedulers, decision
  loops and required callers. If L.G.I. lacks the necessary code/callers, leave AI as a final-phase scope
  rather than inventing infrastructure prematurely.
- Identity cleanup detail (verified LIVE 2026-09-21). **Anonymous Auth:** 13 users → **0** (all deleted;
  no anonymous owner remains for any player). **Claimed AI empires:** 13 → **0** — the empires
  `AI-G1-S1-P2` … `AI-G1-S1-P14` were **released** (`players.user_id = NULL`), **not destroyed**: each
  still exists as an unowned AI with 1 homeworld and no gameplay investment (0 research, 0 buildings,
  0 ships, 0 queues). **AI owned by the DEV email account: none** — the email account owns only
  `DevPlayer`. **Unowned AI pool:** 370 players. Nothing was deleted by the identity closeout beyond the
  13 anonymous Auth users.
- **P0 REGRESSION — FIXED IN LIVE 2026-09-21.** Formerly `planet_buildings`, `planet_defenses`,
  `planet_ships`, `shipyard_queue`, `fleet_movements` and `fleet_movement_ships` carried **only** a
  `*_select_guest` policy (`pl.is_guest = true`), so once the DEV player became `is_guest = false` its
  owner session read **0 rows** of `planet_buildings` (2 exist), `planet_ships` (1 exists) and
  `shipyard_queue` (1 exists) — all three read by `src/App.tsx`. Applied as ledger version
  `20260921114105` (`20260921130000_restore_owner_select_policies_after_guest_rls_removal`, recovered
  verbatim as
  `supabase/migrations/20260921114105_20260921130000_restore_owner_select_policies_after_guest_rls_removal.sql`):
  the six guest policies were **replaced** by owner-scoped `<t>_select_access` policies derived from
  `auth.uid() → players.user_id → players.id → planet / fleet`. No `is_guest` branch, no anonymous
  access, no hardcoded player UUID, RLS still enabled on all six. Verified post-fix with rolled-back
  authenticated sessions: the DEV owner reads **2 / 1 / 1** (was 0 / 0 / 0); a stranger authenticated
  session and `anon` both read **0 rows** on all six. Caveat: `20260920120400_remove_guest_rls_surface.sql`
  still **drops** those policies without creating replacements and must not be applied alongside this fix.
- **`players_select_access` — HARDENED IN LIVE 2026-09-21.** It previously used four branches, two of them
  keyed on hardcoded data: `id = 'aa1deb2d-3ed6-4350-922a-172d999b2af7'::uuid` and
  `(is_guest = true) AND (username <> 'DevPlayer') AND (user_id IS NOT NULL)`. Measured before: `anon` and
  a stranger authenticated session both read the DevPlayer row (`devplayer_row_visible = 1`). Applied as
  ledger version `20260921125336` (`harden_players_select_access_ownership`, recovered verbatim as
  `supabase/migrations/20260921125336_harden_players_select_access_ownership.sql`): the policy is now
  `(player_type = 'AI') OR (user_id = (select auth.uid()))` — ownership purely from
  `auth.uid() → players.user_id`, the intentional AI-gallery read kept, no hardcoded UUID, no hardcoded
  username, no `is_guest` branch, RLS still enabled. The `is_guest` half was removed on evidence: 0 rows
  have `is_guest = true` and no surviving function can write `true` (`register_guest_player` is dropped;
  `reconcile_universe_ai_population` only writes `false`). Verified after: the DEV still reads its own
  player (`own_rows_visible = 1`, username `DevPlayer`); stranger and `anon` see **0** owned/HUMAN rows and
  can no longer read the DevPlayer row; no AI gained ownership (`AI with user_id = 0`). Consequence:
  `scripts/verify-identity.mjs` runs on the anon key, so its HUMAN-player assertions now report
  `0 humanos` (vacuously passing) while the planet-based assertions still cover 378 planets.
- **Audit result — guest authorization residue closed LIVE 2026-09-28.** The final catalog gate returns 0 public functions referencing `is_guest`, excluding only `register_guest_player` and `reconcile_universe_ai_population`; the guest-only policy surface is also absent. Historical migration provenance drift is documented separately.

**Coverage note.** Of the 148 client-callable functions in `public`, 28 are consumed by the frontend. The rest are
engine/cron/service-role contracts (`calculate_*`, `select_expedition_*`, workers) or helpers whose client-facing
behaviour is delivered inside the 28 contracts. No public function was found that should be wired to the UI and is not.

## GAP CLOSURE SWEEP (2026-09-26) — GAP A…I

Third implementation pass over the *residual* gameplay gaps of the current state. Each gap below is closed with LIVE
evidence or explicitly classified; nothing was committed or pushed. LIVE migration `20260926280000`. Per gap:
contract · frontend · ownership · LIVE verification · fixture · status.

```text
GAP A  resources / storage read contracts ................. CLOSED — IMPLEMENTED
  contract   get_current_planet_resources(uuid) and calculate_planet_storage(uuid) are now bounded SECURITY
             DEFINER contracts (owner postgres, pinned search_path) carrying the sibling identity gate:
             auth.uid() IS NOT NULL AND the planet is not owned by auth.uid() -> PLAYER_NOT_OWNED.
             ACL: authenticated + service_role only (anon lost EXECUTE). NO grant on public.universes;
             calculate_universe_rates / calculate_planet_production untouched (their P3 hygiene stays deferred).
  symptom    before: every client call aborted with an internal error —
             42501 permission denied for table universes
               calculate_planet_storage line 10 (planets JOIN universes)
               get_current_planet_resources line 40 -> calculate_planet_production line 36 ->
               calculate_universe_rates line 13 -> universes
             Reproduced LIVE as the DEV authenticated actor before the migration.
  frontend   no UI caller existed (it was broken API surface). The certified consumers can_build_ship /
             can_build_defense keep answering OK for the owner (verified LIVE after the change), and
             sync_current_planet_resources still settles the owner's planet.
  ownership  owner PASS · foreign authenticated actor PLAYER_NOT_OWNED · anon refused by the ACL ·
             service/worker context (auth.uid() IS NULL) UNCHANGED, so the fleet, combat, espionage, moon and
             merchant workers still settle FOREIGN planets.
  LIVE       supabase/tests/planet_resources_storage_read_contract.sql — 10 PASS + 1 INFO, LIVE 2026-09-26,
             rolled back, zero residue: independently recomputed storage expectation, client answer identical to
             the internal computation (no formula/rounding/projection drift), foreign + anon refusals, worker
             context preserved.
  note       the gate deliberately does NOT reproduce the flagged `is_guest = true` branch of the
             planet_resources RLS policy (guest bypasses stay closed).
GAP B  fleet mission surface (backend vs UI) .............. CLOSED — ALREADY IMPLEMENTED (verified, not rebuilt)
  contract   the seven certified dispatchers: start_fleet_mixed (TRANSPORT · DEPLOY · EXPEDITION · ATTACK ·
             ESPIONAGE · RECYCLE), start_colonize_fleet (COLONIZE), start_support_fleet (ACS_HOLD),
             start_moon_destruction (MOON_DESTRUCTION); DEFEND and HOLDING are listed but not dispatchable
             (COMBAT_SUPPORT_NOT_READY / HOLDING_IS_INTERNAL_STATE).
  frontend   src/FleetCommandPanel.tsx renders all of them from the deployed bodies, with origin selector,
             ship loading, load_fleet_cargo, recall_fleet, fleet slots and check_colony_cap; reachable from the
             FLOTA view (src/App.tsx). No mission is backend-only any more.
  ownership  server-side on every path (auth.uid() -> players.user_id -> planet/fleet); the client decides nothing.
  LIVE       13/13 browser read contracts answer for the authenticated owner (smoke test), and the COLONIZE
             control dispatch from a planet with the certified prerequisites is accepted.
  decision   **COLONIZE FROM A MOON = PRODUCT DECISION OPEN.** Measured LIVE: with an identical fixture
             (shipyard 4 + impulse_drive 3 + colony_ship) start_colonize_fleet is ACCEPTED from a moon — the
             dispatcher validates coordinates, origin ownership, target occupancy, colony cap, the colony ship,
             its prerequisites and the fuel, but NOT the origin kind; the origin selector offers moons. Classic
             OGame forbids it. Nothing was changed and no restriction was invented.

GAP C  expedition configuration ........................... CLOSED — CONFIGURATION ALREADY CORRECT (verified)
  contract   expedition_settings row for the ACTIVE universe (cf021ece): the eleven weights (35/35/7.5/2.75/25/
             0.2/3/1.5/7.5/0.4/0.5) and the four reward multipliers (1.0), so the
             'Invalid expedition weights for universe' guard cannot fire.
  LIVE       select_expedition_outcome(active universe, roll) resolves real outcomes LIVE (roll 5 -> SHIPS,
             roll 60 -> RESOURCES); the certified fixture expedition_items_and_slots.sql (22 assertions,
             including a real end-to-end resolution in the active universe) was NOT rewritten.
GAP D  expedition items ................................... CLOSED — PATH ALREADY IMPLEMENTED (verified LIVE)
  contract   expedition_item_definitions (8 active) -> resolve_expedition_item (service-only reward) ->
             player_expedition_items (persistence) -> use_expedition_item (owner-gated activation) ->
             expedition_item_uses (active effect + expiry) -> the certified consumers (production, storage,
             research/building time, fleet speed, expedition slots).
  ownership  use_expedition_item: auth.uid() -> players.user_id -> player (+ optional planet ownership);
             authenticated only (never anon); get_player_expedition_item_status is the client read contract.
  LIVE       probe 2026-09-26: owner activation of storage_boost_25 returned the effect with a real expiry,
             consumed the stack (0 left, inactive), wrote one use row, and moved the certified storage contract
             by exactly +25 % (100000 -> 125000); a foreign authenticated actor was refused with
             'Player does not belong to authenticated user' and nothing mutated. 0 stacks existed before (the
             ITEMS reward carries weight 0.5), which is why no player had ever used one.
GAP E  ranking (points + rank refresh) .................... CLOSED — ALREADY IMPLEMENTED (verified LIVE)
  contract   calculate_player_points (pure) -> recalculate_player_points / recalculate_universe_ranking
             -> run_ranking_worker + pg_cron 'lagranimplosion-ranking-refresh' (*/5, active) ->
             get_universe_ranking / get_universe_ranking_by_category (authenticated only).
  LIVE       DEV player: raw 14087.2 -> floor/1000 = 14 = stored points, rank 1; 585/585 players carry a rank;
             run_ranking_worker() returned (cf021ece, 585) inside a rolled-back transaction, so the refresh is
             operative and reproducible. Only one player owns assets, so the 584 zeros are the correct answer,
             not an inert system. UI: RankingPanel with the four categories.
GAP F  counter-espionage .................................. CLOSED — ALREADY IMPLEMENTED (verified, not touched)
  contract   resolve_espionage_arrival (the only write path, service-only) applies the OGameX chance formula,
             runs the real battle of the probes against the target's SHIPS through the certified combat engine,
             writes the losses back, creates debris, notifies the defender ('You were espied') and rolls
             replay-safely through fleet_event_random.
  LIVE       espionage_reports carries counter_espionage_chance / counter_espionage_triggered / probes_sent /
             probes_lost and the owner-scoped read contract returns all four next to the report payload; the
             producers are present in the resolver. The certified fixture counter_espionage.sql (13 PASS) was
             neither rewritten nor re-run.

GAP G  messaging surface .................................. CLOSED — ALREADY IMPLEMENTED (verified LIVE)
  contract   get_player_messages(limit, unread_only) + mark_message_read(id) (authenticated only), with the
             pointer-style message set (fleet status, combat, expedition, colony, espionage, counter-espionage);
             the browser groups them by category (COMBATE / EXPEDICIONES / ESPIONAJE / TRANSPORTE) and tracks
             read state.
  ownership  the recipient comes from the engine row, never from a client parameter.
  LIVE       probe 2026-09-26 (rolled back): the owner's inbox returned 1 of 2 probe rows (the foreign one stayed
             invisible), marking a FOREIGN message was refused with PLAYER_MESSAGE_NOT_FOUND_OR_NOT_OWNED and
             mutated nothing, and marking one's own message is idempotent (same stamp on replay).
GAP H  AI gameplay ........................................ CLOSED — execution contract + full policy implemented
  contract   ai_actor_begin / is_ai_actor_target / ai_actor_end (service_role only), the owner-authorised
             dispatchers they unlock, and ai_decide_and_act / run_ai_policy_worker (service_role only, pg_cron
             'lagranimplosion-ai-policy' */5, active).
  policy     REPLACED 2026-09-26 by the full gameplay policy (20260926290000 + 20260926291000 + the two
             forward-only fixes 20260926292000/293000): personalities, deterministic daily activity windows
             (3–6 h in 2–5 windows), planet specialisation, scored action families (building, research, shipyard,
             defence, espionage, attack, colonisation), personality-weighted cooldowns, espionage-driven
             targeting, combat-power estimation over the certified stat helpers, probabilistic attacks with a
             24 h protection for young AIs and colonisation (including from a moon). Documented in
             README_AI_ENGINE.md §7; 20/20 + 6/6 PASS LIVE.
  RULE       no second rule engine: every legality question is asked to the contract that owns it and every action
             is executed by the certified dispatcher inside the declared AI actor.
GAP I  remaining UI surface ............................... CLOSED — nothing missing
  evidence   every RPC the browser calls (34 names) exists in LIVE with `authenticated` EXECUTE and DEFINER
             security; the 13 read contracts answer for the owner; 28 RPC + 17 tables were audited one by one in
             the previous pass. Panels exist for fleets, expedition + items, moons and their services (phalanx,
             jump gate), messages + espionage + expedition reports, ranking (4 categories), demolition and
             support authorizations.
  OUT OF SCOPE  the wreck field / Space Dock is deliberately backend-only: every wreck-field contract
             (settle / repair / worker / level) is postgres+service_role and there is no client read contract, so
             a UI would require NEW client contracts on a CLOSED subsystem. Not opened here.
```

**Product decisions recorded by this sweep (no implementation):** COLONIZE from a moon (GAP B, measured LIVE as
currently accepted); the AI fleet step (GAP H); a wreck-field client surface (GAP I). **Residual, deliberately not
fixed:** `calculate_building_time`, `calculate_ship_build_time`, `calculate_defense_build_time`,
`calculate_research_time`, `calculate_lifeform_*_time`, `calculate_universe_evolution_*` and
`calculate_planet_production` remain PUBLIC EXECUTE + SECURITY INVOKER and therefore still raise `42501` on
`public.universes` when a client calls them directly — the same deferred P3 hygiene that
`20260922050734_shipyard_availability_contract_definer` declared, with no frontend caller and no new oracle created
by this sweep. `docs/systems/README_FLEET_ENGINE.md` carries the corrected browser-surface notes and
`docs/systems/README_ECONOMY.md` the durable detail of the GAP A contracts.

Validation of this sweep: `npx tsc -b` exit 0 · `npx vite build` exit 0 (worker + client) · `git diff --check`
clean · ESLint unchanged against the pre-existing baseline (10 problems, all in files untouched by this sweep) ·
LIVE history records `20260926280000` (repository file-name convention) · no commit, no push.

## GAMEPLAY COMPLETION PASS (2026-09-26) — verification + UI gaps

Fourth pass. The list of pending mechanics was re-checked against LIVE **without reopening any certified system**:
every item that was already closed was verified and consumed (read → trust → consume), and only two real UI gaps
plus one isolated product decision remained.

```text
VERIFIED — already implemented (no code touched)
  fleet slots       1 + computer_technology; the guard is a BEFORE INSERT trigger on fleet_movements, so it covers
                    every dispatch path. Measured LIVE: FLEET_SLOTS_FULL: 1/1 for EXPEDITION and for TRANSPORT
                    (0 free slots), and get_player_fleet_slots() reported max=1 / in_use=1 / available=0.
                    Fixture fleet_slots_enforcement.sql (certified) was not rewritten.
  recall            recall_fleet: owner-gated (auth.uid() -> fleet.player_id, or service with the player id),
                    OUTBOUND only before arrives_at (FLEET_RECALL_TOO_LATE), HOLDING anytime, everything else
                    FLEET_NOT_RECALLABLE, race-guarded UPDATE ... WHERE status = old (FLEET_RECALL_RACE_LOST, no
                    double execution). Measured LIVE: owner recall -> status RETURNING and one message row.
                    The UI's recallable set (OUTBOUND/HOLDING) matches the contract exactly.
  counter-espionage  OGameX chance formula + real probe battle through the certified combat engine, losses written
                    back, debris at the target, defender notified, replay-safe roll. espionage_reports carries
                    counter_espionage_chance/triggered/probes_sent/probes_lost and the owner read contract returns
                    them. Certified fixture (13 PASS) not re-run.
  espionage         mission end-to-end + reveal gating (ships 2 / defence 3 thresholds) already implemented; the
                    remaining level-gating of the payload is a documented PRODUCT DECISION, not a defect.
  messaging         producers LIVE: notify_fleet_status_change (arrival/return/holding/recall/debris),
                    notify_combat_participant (battle + attack received), notify_expedition_result,
                    notify_colony_established and the explicit espionage/counter-espionage producers. Read/mark
                    contracts are owner-scoped (verified in the previous pass: foreign mark refused, no mutation).
  colonization      flow complete (requirements, colony cap, occupancy, in-flight mission, planet creation, owner,
                    cargo seed, events, refusals). Only the moon-origin question stays OPEN as a product decision.
  moon              certified (creation, buildings, phalanx, jump gate, destruction, read contracts): untouched.
  fusion plant      VERIFIED LIVE with numbers: with the reactor isolated (mines and solar at 0) the net energy is
                    floor(30*L*(1.05+0.01*ET)^L) = 200 for L=5/ET=1, the burn is 10*L*1.1^L scaled by
                    (economy x production) = 80.5255 x 90.1724 = 7261/h (observed 7260.7) and with deuterium = 0
                    the reactor yields no energy and burns nothing (OGame fuel rule). One single economic engine:
                    the burn rides the authoritative production rate and the settlement recovers the base.
  ranking           points/rank/categories + refresh worker (cron */5) verified in the previous pass: 585/585 ranked.
  AI                ai_actor_begin/is_ai_actor_target/ai_actor_end + ai_decide_and_act/run_ai_policy_worker
                    (service_role, cron */5). Behaviour policy for buildings/research/colony is owner-authorised.

IMPLEMENTED — the two real UI gaps
  fleet UI gating   the launch button is now disabled by server-derived state: 0 free fleet slots, 0 free
                    expedition slots or a refused colony cap, each showing the server's own reason code
                    (FLEET_SLOTS_FULL / EXPEDITION_SLOTS_FULL / COLONY_CAP_REACHED). Graceful degradation: with a
                    contract unloaded nothing is blocked and the backend decides.
  cargo surface     the dispatch panel shows the origin body's available metal/crystal/deuterium, the selection's
                    advisory base capacity and the requested cargo (load_fleet_cargo remains the authority).

PRODUCT DECISION (isolated, no implementation)
  AI fleet step     OGameX has no player-AI dispatch policy (its only NPC code, the fleet generator, builds enemy
                    fleets for expeditions), so a target/composition/mission policy would have to be invented.
                    Declared as the next increment with its own mission fixture.

UNTOUCHED / OUT OF SCOPE
  Lifeforms (never entered this pass) · wreck field client surface (all contracts service_role) · the deferred P3
  ACL hygiene of the remaining PUBLIC INVOKER helpers (documented in the GAP A section).
```

Validation of this pass: `npx tsc -b` exit 0 · `npx vite build` exit 0 · ESLint unchanged (10 pre-existing problems,
none in the edited file) · `git diff --check` clean · all LIVE probes inside `BEGIN … ROLLBACK` with zero residue ·
no commit, no push.

## AI GAMEPLAY BEHAVIOUR (2026-09-26) — implementation pass

Third AI increment: the actor contract (first pass) and a first-cut policy (second pass) are now a full gameplay
policy. LIVE migrations `20260926290000` (model), `20260926291000` (policy + worker), `20260926292000` and
`20260926293000` (forward-only fixes found by LIVE testing). Nothing was committed or pushed.

```text
IMPLEMENTED + TESTED (LIVE, rolled back, zero residue)
  personality      persistent per AI player (INDUSTRIAL / SCIENTIST / MILITARY / PREDATOR) assigned once from
                   hash(player_id) and never re-rolled; ai_player_profiles with RLS + deny_direct_api_access.
  daily activity   3–6 h per UTC day in 2–5 windows, deterministic from hash(player_id + UTC date)
                   (ai_daily_activity / ai_is_active_at). Outside a window nothing is decided:
                   (none, null, 'AI_INACTIVE_WINDOW'). The 5-minute cron tick is unchanged.
  planet templates MINING_WORLD / RESEARCH_WORLD / MILITARY_WORLD / FLEET_BASE / EXPANSION_WORLD, biased by the
                   personality, with a deterministic per-planet variation (ai_planet_profiles).
  action scoring   score = weight × affordability × strategic need × random(0.80..1.20), where random is a
                   deterministic hash per (player, kind, tick) — `random()` is never used. Families: building,
                   research, shipyard, defence, espionage, attack, colonisation. The highest score wins and is
                   executed by the certified dispatcher; otherwise the tick returns AI_IDLE.
  cooldowns        building 10–35 · research 30–120 · production (shipyard/defence) 20–90 · fleet 20–90 ·
                   espionage 15–60 · attack 45–180 · colonisation 120–360 minutes, weighted by personality.
  espionage        probe candidates ranked with the certified distance helper plus jitter; the mission goes through
                   start_fleet_mixed(…, 'ESPIONAGE'); report data is read from the AI's own espionage_reports.
  combat power     reuses get_combat_{ship,defense}_{attack,shield,hull}; targets (unknown research) use the
                   definitions with the same hull/10 convention plus a documented 1.15 conservatism.
  attack policy    zones <0.75 / 0.75–0.95 / 0.95–1.25 / >1.25 mapped to probabilities scaled by personality
                   (PREDATOR 1.30 … INDUSTRIAL 0.50, ceiling 0.85) and then actually rolled each tick.
  24 h protection  an AI younger than 24 h never attacks anybody, whatever the target (result AI_PROTECTION_24H);
                   no target-side beginner protection exists (that would be a new product decision).
  colonisation     cap + colony ship + free coordinate + fuel + free fleet slot, deliberately low probability; also
                   FROM A MOON (OGameX has no origin-kind restriction, LGI already allowed it — certified).
  fleet doctrine   ai_unit_preference / ai_pick_unit: transports for INDUSTRIAL, probes for SCIENTIST, combat ships
                   for MILITARY, offensive ships + probes for PREDATOR; the certified can_* contract decides.
  anti-snowball    3–6 h/day + real inactivity + cooldowns + probabilities + 60 % budget + partial commitment.
  tests            supabase/tests/ai_behaviour_policy.sql 20 PASS (deterministic schedule; 60 generated days inside
                   3–6 h; active/inactive; persistent personality; templates; cooldown ranges; 24 h protection with
                   a legal human target; espionage dispatch; power equals the certified helper sum; probability
                   zones + a real attack; colonisation; colonisation from a moon; fleet slots; colony cap; inactive
                   window; worker) · supabase/tests/ai_player_policy.sql 6 PASS (budget validation, budget
                   invariant, actor refuses humans, worker batch, ACL of functions + profile tables, cron).
  untouched        fleet slots / recall / counter-espionage / espionage / messaging / colonisation / moon / fusion /
                   ranking contracts: read-only. No certified contract was reopened or modified.
  LIVE proof       the AI cannot skip requirements: an AI without shipyard 3 + espionage_technology 2 is refused by
                   start_fleet_mixed with SHIP_REQUIREMENT_FAILED.
  fixed forward    ai_ensure_player_profile OUT-parameter/column ambiguity (42702) · ai_composition_power
                   unknown-owner hull convention (10× overestimate of every defender's hull component) ·
                   run_ai_policy_worker population rotation (the batch used to stick to the same first 25 of 586
                   players whenever no action was taken, so most daily windows were never evaluated).
  OGameX           no player-AI policy exists (NPCFleetGeneratorService builds enemy expedition fleets), so the
                   policy is LGI's own and declared as such; ColonisationMission (target-side validity only) and
                   EspionageMission (reveal gates 2/1 ships, 3/2 defences, 5/3 buildings, 7/4 research) were read
                   and LGI already matches them.
  STILL OPEN       normalising/activating the 586 EXISTING AI empires (new AIs are born with the human initial
                   state and DORMANT — see the AI INITIAL BOOTSTRAP section below) · target-side beginner
                   protection for humans (new product decision) · espionage report building/research level
                   gating (LGI reports do not carry them) · browser certification of the fleet flow · deferred
                   P3 ACL hygiene of the remaining PUBLIC INVOKER helpers.
  OBSERVED LIVE    the cron worker rotates the AI population (124 ai_player_profiles rows, ALL DORMANT) and the
                   586 pre-existing AI planets still hold 0 resources/buildings because they were seeded before
                   the bootstrap fix: they are DORMANT and untouched.
```

Validation of this pass: `npx tsc -b` exit 0 · `npx vite build` exit 0 (worker + client) · `git diff --check`
clean · ESLint unchanged against the pre-existing baseline (10 problems, all in files untouched by this pass) ·
every LIVE probe inside `BEGIN … ROLLBACK` (the fixtures create no residue: the AI profile tables and every probe
row are rolled back) · no commit, no push. The cron worker keeps running the new policy unattended every 5
minutes, which is the intended production behaviour.

## AI INITIAL BOOTSTRAP + DORMANT STATE (2026-09-26)

Fourth AI increment. LIVE migrations `20260926295000_ai_dormant_state` and `20260926296000_shared_player_bootstrap`.
Nothing was committed or pushed. Detail: `docs/systems/README_AI_ENGINE.md` §8.

```text
IMPLEMENTED + TESTED (LIVE, rolled back, zero residue)
  parity           ONE bootstrap authority, `public.bootstrap_new_player_state(player_id, planet_id)`: a new AI now
                   receives EXACTLY the state a new human receives. The initial endowment is not re-declared
                   anywhere — it lives in the planet_resources schema defaults (metal 500, crystal 500,
                   deuterium 0, energy 0) and the helper inserts only the planet id, so there is no quantity to
                   copy. Initial research comes from the existing reuseable `initialize_player_research`
                   (16 x level 0). No AI bonus, no AI penalty, no AI-only quantities, no second initial economy.
  reuse (option B) `provision_player` (human) and `reconcile_universe_ai_population` (AI) BOTH delegate to that
                   helper and no longer contain any `insert into planet_resources`; both keep their signatures,
                   SECURITY DEFINER + search_path, returned columns and every other statement.
  DORMANT          `ai_player_profiles.status` text NOT NULL DEFAULT 'DORMANT' CHECK (DORMANT|ACTIVE) — a persistent,
                   explicit state, never inferred from empty resources/buildings/dates. The AI seeder creates the
                   profile at birth, so a new AI is DORMANT from the first moment.
  enforcement      `ai_decide_and_act` is now a gate that answers (none, null, 'AI_DORMANT') before any evaluation
                   (the certified policy body was preserved byte-for-byte as `ai_decide_and_act_core`, EXECUTE
                   revoked from every role), and `run_ai_policy_worker` walks ACTIVE players only while keeping
                   the `20260926294000` round-robin.
  ACTIVE unchanged an ACTIVE AI uses exactly the certified policy of the previous pass (proved by the regression
                   fixtures: 20/20 and 6/6 PASS).
  existing AIs     the 586 pre-existing AI empires were NOT activated, NOT normalised and NOT modified: they keep
                   0 resources/buildings and stay DORMANT. Normalising them is an OPEN product decision.
  activation seam  documented, deliberately NOT implemented as an API: a service-role statement
                   `UPDATE ai_player_profiles SET status='ACTIVE' WHERE player_id = <uuid>` (and the reverse).
                   No client RPC, no button, no automatic activation.
  tests            supabase/tests/ai_bootstrap_and_dormant.sql 14 PASS + 1 INFO (real human birth vs real AI birth
                   compared field by field; exact 500/500/0/0 + 16 research rows; DORMANT blocks building,
                   research, ships, defence, espionage, attack, colonisation and every fleet dispatch and consumes
                   no budget; ACTIVE keeps the policy; worker skips DORMANT / reaches ACTIVE / still rotates).
                   Regression: ai_behaviour_policy.sql 20 PASS · ai_player_policy.sql 6 PASS (both now activate
                   their tested AI explicitly — documented, strict necessity).
  LIVE residue     none: 0 ACTIVE profiles, 0 scratch universes/probe planets/temp auth users/temp tables, no new
                   fleet rows; the 124 ai_player_profiles rows created by the cron are all DORMANT.
  STILL OPEN       activating the AI empires (their NORMALIZATION is now done — see the AI NORMALIZATION +
                   BEGINNER PROTECTION section below) · espionage report building/research level gating ·
                   browser certification of the fleet flow · deferred P3 ACL hygiene.
```

Validation of this pass: `npx tsc -b` exit 0 · `npx vite build` exit 0 (no frontend change) · `git diff --check`
clean · ESLint unchanged against the pre-existing baseline (10 problems, all in files untouched) · every LIVE probe
inside `BEGIN … ROLLBACK` · both new migration ledger records repaired to the repository file-name convention and
verified byte-identical by md5 · no commit, no push.

## AI EMPIRE NORMALIZATION + BEGINNER PROTECTION (2026-09-26)

Fifth AI increment. LIVE migrations `20260926297000_ai_empire_normalization` and
`20260926298000_beginner_protection`. Nothing was committed or pushed. Detail: `README_AI_ENGINE.md` §9 and
`README_FLEET_ENGINE.md` §25.

```text
IMPLEMENTED + TESTED (LIVE; probes rolled back, plus the intended backfill of the AI empires)
  AI normalization  explicit, idempotent backfill `normalize_existing_ai_empires(universe, limit, dry_run)`: the
                    legacy zero state of an AI homeworld is replaced by the HUMAN bootstrap state (500/500/0/0 +
                    16 level-0 research rows) using `SET col = DEFAULT`, so the schema defaults remain the single
                    authority and no literal exists anywhere. Candidates are only untouched legacy empires;
                    anything with progress is skipped and counted. It never activates (status untouched), never
                    creates inventory and never changes identity/homeworld/position/personality. dry_run + limit
                    implement the required pre-mass protocol.
  LIVE result       dry run: 586 candidates, 2 already correct, 0 with progress. Full run: 586 normalised.
                    Rerun: 0 candidates / 588 already ok (idempotent). Post-state: 588/588 with 500/500/0/0 and
                    16 level-0 rows, 0 with buildings/ships/defences, 0 ACTIVE / 588 DORMANT, 0 AI queues and
                    0 AI fleet movements.
  Beginner prot.    FASE 2 audit: LGI had NO such rule (repo search + LIVE functions/columns = 0 hits). FASE 3:
                    OGameX @7c420bad has none either (AttackMission checks vacation mode and admin protection
                    only). Implemented with the LGI-owned 24 h window (the AI attacker gate's, anchored on
                    players.created_at — no formula invented): `get_player_attack_protection(player, at)` plus a
                    BEFORE INSERT trigger on fleet_movements raising TARGET_BEGINNER_PROTECTED for ATTACK
                    missions whose destination belongs to a human inside its first 24 h.
  Scope             blocked: ATTACK only. Allowed: espionage, transport, recycle, colonisation and ACS defend.
                    AI targets and the human attacker side are explicitly OUT (declared product decisions).
  tests             supabase/tests/ai_normalization_and_beginner_protection.sql 16 PASS + 1 INFO · regression
                    ai_behaviour_policy.sql 20 PASS · ai_player_policy.sql 6 PASS · ai_bootstrap_and_dormant.sql
                    (a real AI birth ≡ a real human birth) · all LIVE, rolled back.
  new-AI guarantee  exactly ONE birth path: `reconcile_universe_ai_population`, invoked by
                    `process_universe_heartbeat` every minute (service_role only); only it and `provision_player`
                    insert players. Its body has no metal/crystal/deuterium word and never inserts
                    planet_resources: it delegates to `bootstrap_new_player_state` + `ai_ensure_player_profile`.
                    Measured: 6 empires born across two forced reconciliations (3 + 3, batch-driven) and 30 born in
                    production within the last 24 h — every one exactly 500/500/0/0 + 16 level-0 rows + DORMANT,
                    with economics identical to a newborn human; 0 unbootstrapped anywhere. Fixture assertions
                    15/16 guard this permanently (recent newborns + the seeder body invariant).
  STILL OPEN        activating the AI empires · target-side protection for AI empires · attacker-side rule for
                    humans · points-based novice band · UI hint of the remaining protection time · browser
                    certification of the fleet flow (BLOCKED in this pass — see README_FLEET_ENGINE §27).
```

Validation of this pass: `npx tsc -b` exit 0 · `git diff --check` clean · ESLint unchanged against the
pre-existing baseline (10 problems, all in files untouched by this pass) · no frontend change, so no build was
required · every probe inside `BEGIN … ROLLBACK` except the authorised AI backfill · both new migration ledger
records repaired to the repository file-name convention and verified byte-identical by md5 · no commit, no push.

## ESPIONAGE GATING · BROWSER FLEET CERTIFICATION · P3 ACL (2026-09-27)

Sixth increment. LIVE migrations `20260926299000`, `20260926300000`, `20260926301000`; no commit, no push.
Detail: `README_FLEET_ENGINE.md` §26 (gating) and §27 (browser certification), `README_AI_ENGINE.md` §10 (ACL).

```text
ESPIONAGE GATING   LGI ALREADY had it, with the OGameX convention verbatim:
                   level_gap = max(0, target_esp - attacker_esp); remaining = max(0, probes - level_gap^2);
                   reveal_ships = remaining >= 2 or attacker_esp - 1 >= target_esp;
                   reveal_defenses = remaining >= 3 or attacker_esp - 2 >= target_esp
                   (= OGameX `canRevealData(…, 2, 1)` and `(…, 3, 2)`, extra probes = level_gap^2).
                   Authority: `resolve_espionage_arrival` (service_role only) stores the report ALREADY FILTERED
                   (`{}` when hidden). Reader: `get_player_espionage_reports` (authenticated only, owner-scoped).
                   `espionage_reports` denies direct client access (RLS deny policy).
                   resources = ungated (as in OGameX). buildings/research = NOT part of the LGI report at all (no
                   column, no reveal path, contract retired by 20260921140925) -> nothing to gate.
                   `energy` = the target's ship-attack aggregate (documented deviation from OGameX's planet
                   energy; pinned by the fixture, change DEFERRED).
                   tests: new supabase/tests/espionage_report_gating.sql 17 assertions (LIVE, rolled back).
BROWSER CERT       BLOCKED (never reported as PASS): no Playwright/Puppeteer/Cypress in package.json nor
                   node_modules, no browser driver, and no human session credential in .env.local (only
                   VITE_SUPABASE_URL + publishable key) -> a real UI session cannot be created without either
                   modifying the dependency tree, fabricating a JWT or mutating LIVE (all forbidden).
                   Delivered instead (labelled non-substitute): the static UI->RPC inventory (32 RPCs) and the
                   backend contracts the browser would drive.
P3 ACL             audited pg_proc / information_schema / pg_class / pg_default_acl. Root cause found: PUBLIC
                   (`=X`) EXECUTE — not the explicit `anon` entry — was what kept ~100 internal functions
                   anonymous-reachable, and `ALTER DEFAULT PRIVILEGES … REVOKE … FROM PUBLIC` does NOT remove the
                   implicit PUBLIC grant on functions. Final state: 0 anon-reachable functions outside the 32-name
                   client allow-list, no ACL-level PUBLIC grant left, `authenticated` preserved exactly (32 client
                   RPCs + the 115 internal helpers it already reached, 19 of them re-granted explicitly), 21
                   internal AI-engine views closed to clients, and a DDL event trigger that revokes PUBLIC on every
                   new function. DEFERRED: table grants (RLS already denies), supabase_admin default ACL.
                   tests: new supabase/tests/acl_surface_p3.sql 9 assertions (LIVE, rolled back).
AI SAFETY          unchanged: 0 ACTIVE / 588 DORMANT, 588/588 with 500/500/0/0 + 16 level-0 research rows, 0 AI
                   actions ever performed (`last_action_at` null everywhere), 0 AI queues/movements.
```

Validation of this pass: `git diff --check` clean · `npx tsc -b` exit 0 · no frontend file changed (no build
required) · every probe inside `BEGIN … ROLLBACK` · the three new migration ledger records repaired to the
repository file-name convention and verified byte-identical by md5 · no commit, no push.

## QUEUE CANCELLATION UI — IMPLEMENTATION (2026-09-27)

Fifth pass. The gap closed was not a missing mechanic but a **certified mechanic with no consumer**: the
cancellation contract was LIVE and certified since 2026-09-26 and no file in `src/` ever called it. Nothing was
reopened: the two RPCs, their refund policy and every other certified subsystem are untouched, and no migration
was added.

```text
GAP                 cancel_building / cancel_research (certified, `supabase/tests/queue_cancellation.sql` 13 PASS)
                    had NO frontend caller: the only "cancel" in src/** was a JS `cancelled` flag, and neither
                    function existed in database.types.ts, so typed code could not call them at all.
IMPLEMENTATION      src/App.tsx — CANCELAR control on the active-queue row of EDIFICIOS / INVESTIGACIÓN
                    (`renderDefinitionMenu`), calling the certified RPC with `p_queue_id` ONLY (ownership stays
                    server-side) and rendering the refund the SERVER returns (no price recomputed in React),
                    then refreshPlanet() + loadView(). Offered exactly for BUILDING / RESEARCHING — the only
                    non-terminal status each queue admits — and never for hangar/defensa (OGameX
                    `UnitQueueService`: unit-queue objects cannot be canceled). `building_queue.is_downgrade` is
                    selected too, so a demolition row is labelled and refunded with the demolition cost.
TYPES               src/lib/database.types.ts — `cancel_building` / `cancel_research` added (absent before) and
                    `building_queue.Row/Insert/Update` gained `is_downgrade` (column LIVE since 20260926160000).
TESTS               supabase/tests/queue_cancellation_ui_contract.sql — 13 PASS + 2 INFO LIVE, rolled back,
                    residue 0: call shape (one uuid argument; authenticated EXECUTE, anon never), the exact
                    return column list declared in database.types.ts, UI precondition vs the schema status
                    CHECK, COMPLETED/CANCELLED refused with zero mutation, exact refunds (metal_mine L1
                    60/15/0; energy_technology L1 0/800/400) and the DEMOLITION refund (90 vs 60 upgrade at
                    ion 0).
RACE (LIVE probe)   CANCELAR pressed when the item is already due: refused with
                    `BUILDING_QUEUE_NOT_CANCELLABLE: COMPLETED` and the refusal unwinds the tick (status stays
                    BUILDING, level stays 0, no refund) — a row can never be refunded AND granted.
FIXTURE LESSON      a baseline AT the storage cap (homeworld `calculate_planet_storage` = 100 000) is clamped
                    by the authoritative tick inside the cancel, which first made assertion 11 read the clamp
                    instead of the refund; the fixture now derives the baseline from the storage contract.
OBSERVATION         `building_queue_status_check` admits BUILDING/COMPLETED/CANCELLED only, so the buildings
                    view's `status IN (BUILDING, QUEUED)` filter is inert. Left untouched and recorded.
CLOSED NOT TOUCHED  Research Lab + IRN, Research Lab upgrading, ACS/ACS_HOLD, fleet engine, combat, wreck
                    field / Space Dock, moon engine, identity/guest/ownership, universe evolution, lifeforms.
                    No backend contract, resolver, worker or formula was modified.
PRODUCT DECISIONS   none taken. The refund is OGameX's (100 %, no penalty); the shipyard/defence queues stay
                    non-cancellable by OGameX parity; a wreck-field client surface stays a product decision
                    (not opened).
VALIDATION          git diff --check clean (only pre-existing LF→CRLF advisories) · npx tsc -b exit 0 ·
                    npm run build completed both environments (the Vite reporter writes to stderr, which
                    PowerShell surfaces as a non-zero exit) and the emitted bundle contains `cancel_building` ·
                    every LIVE probe inside BEGIN … ROLLBACK · no commit, no push.
```

## EXPEDITION MERCHANT (`GainMerchantTrade`) — IMPLEMENTATION (2026-09-27)

Sixth pass. The cycle closed was an **expedition reward that could not be used**: the outcome existed, the state
was persisted, the report announced it, and no actor could consume it. No rule was invented and no certified
subsystem was reopened.

```text
GAP                 MERCHANT outcome (OGameX `ExpeditionOutcomeType::GainMerchantTrade`, weight 0.4 in the active
                    universe) → `resolve_expedition_arrival` → `resolve_expedition_merchant` writes/IMPROVES the
                    active row of `player_expedition_merchants` → report + message. Then nothing: the table is
                    closed to the client (`deny_direct_api_access`), `execute_expedition_merchant_trade` is
                    EXECUTE service_role only with ZERO callers in pg_proc, the Worker has no RPC path and no
                    Edge Function exists. The offer stayed `active` forever.
IMPLEMENTATION      20260927024948_expedition_merchant_trade_contract:
                      get_player_expedition_merchant()   read contract, owner-scoped, one row always
                                                         (`has_merchant`, `offered_resource`, three rates)
                      trade_with_expedition_merchant()   identity auth.uid() → players.user_id (no client player
                                                         id), owned+alive body verified, RULE delegated in full to
                                                         the already-LIVE internal function; returns
                                                         sold/bought/bought_resource/remaining_merchant
                    ACL: authenticated + service_role, never anon, never PUBLIC. The internal function stays
                    service_role-only so the AI actor keeps passing its own p_player_id.
UI                  src/GameplayEnginePanel.tsx — `ExpeditionMerchantPanel`, mounted in the Expeditions view:
                    shows what the merchant gives and the rates, offers only the other two resources as payment,
                    and prints the server's answer (no price recomputed in React, no player id sent).
TYPES               src/lib/database.types.ts — both contracts added (they were absent, so typed code could not
                    call them).
TESTS               supabase/tests/expedition_merchant_trade.sql — 15 PASS + 2 INFO LIVE, ROLLBACK, residue 0
                    (ACL; no session; no offer; foreign body; authenticated stranger; owner read; exact 100
                    crystal → 150 metal at 3/2/1; one trade per merchant; no double reward; wrong resource;
                    insufficient resources; storage clamp 1000 → sold 20 / bought 10 without overflowing;
                    per-actor isolation; invalid arguments).
EVIDENCE OF GAP     `has_function_privilege('authenticated','execute_expedition_merchant_trade(...)')` = false,
                    zero callers found by scanning `pg_get_functiondef` of every public function, the
                    `deny_direct_api_access` policy on `player_expedition_merchants`, and 0 rows of any client
                    path to it (no `supabase.rpc` reference in `src/**`).
SCOPE BOUNDARY      only the EXPEDITION variant is exposed. The general merchant, the shop and the premium
                    economy (Dark Matter spending) stay OUT OF SCOPE / product decision — untouched.
CLOSED NOT TOUCHED  no certified contract was modified: the internal trade function, the expedition resolver,
                    the worker, the weights, the fleet engine, combat, espionage, wreck field, moon engine,
                    identity and universe evolution are byte-identical. No existing migration was edited.
VALIDATION          npx tsc -b exit 0 · npm run build completed both environments · git diff --check clean ·
                    LIVE probes inside BEGIN … ROLLBACK · merchant table left at 0 rows · no commit, no push.
```

## ECONOMY / BUILD-TIME TRANSPARENCY + DEBRIS VISIBILITY — IMPLEMENTATION (2026-09-27)

Seventh pass. Two client-facing holes closed, both measured LIVE as the real `authenticated` role (never
inferred), neither requiring a product decision, and neither reopening a CLOSED system.

```text
GAP A   The UI could not show the real construction time, production, energy or storage. Evidence: for
        `authenticated`, `calculate_planet_production`, `calculate_planet_energy_balance`,
        `calculate_building_time`, `calculate_research_time`, `calculate_ship_build_time`,
        `get_planet_economic_rates` and `get_planet_rate_snapshot` all answered "permission denied for table
        universes" (SECURITY INVOKER helpers reading `public.universes`, which has no table grant); while
        `can_start_research` / `can_build_ship` / `can_build_defense` / `can_start_demolition` return their
        server-computed time. So the Buildings view was the only one stuck on the definition's "TIEMPO BASE",
        and the settlement clamps at the storage capacity (measured 100 000 on the homeworld) with nothing
        telling the player.
FIX A   20260927035324_planet_economy_read_contracts — `get_planet_economy_overview(planet)` (production/h,
        energy balance/h, storage capacities) and `get_planet_building_preview(planet)` (current/target level
        from the certified `evaluate_building_start_internal`, REAL duration composed exactly as
        `start_building` composes it — `calculate_building_time` ÷ the active `building_speed_percent` item —
        and the next level's energy delta/h). Both SECURITY DEFINER, identity `auth.uid()` → `players.user_id`,
        own non-destroyed planet or 0 rows, EXECUTE authenticated + service_role only. `public.universes` was
        NOT opened: the restriction recorded in README_ECONOMY §"Access restriction affecting the client" still
        holds and the fixture proves the direct helpers stay denied.
        UI: buildings cards show the real TIEMPO (fallback labelled "(base)") and ENERGÍA/h; the active-body
        panel shows METAL/CRISTAL/DEUTERIO/ENERGÍA with their per-hour rates, ENERGÍA PROD/CONS and
        ALMACÉN M/C/D.
GAP B   Debris was invisible everywhere: `debris_fields` carries `deny_direct_api_access` and no contract
        exposed it, while the RECYCLE mission works by having the SERVER choose the nearest field — so the
        player recycled blind (3 debris rows exist LIVE).
FIX B   20260927035703_universe_debris_read_contract — `get_universe_debris(universe, galaxy, system)` →
        (out_position, out_metal, out_crystal, out_updated_at); the universe is VALIDATED against the identity
        (0 rows otherwise) and only fields with metal > 0 or crystal > 0 are announced. The table stays closed
        (producers and the collector remain internal). UI: the galaxy view shows each slot's debris and a
        "N CAMPOS DE RESTOS" counter.
TESTS   supabase/tests/planet_economy_read_contracts.sql 15 PASS + 2 INFO (incl. exact equality with the three
        certified helpers, agreement with `can_start_building`'s target_level, the item-bonus shrink
        19.3184s → 17.5622s, and a foreign planet returning 0 rows WITHOUT the delegated helper's
        `PLAYER_NOT_OWNED` exception). universe_debris_read_contract.sql 10 PASS + 1 INFO (incl. "the table is
        still unreadable as `authenticated`"). Both LIVE, ROLLBACK, residue 0.
LESSON  found by LIVE testing, not by reading: with a SQL body the planner folded the STABLE helper whose
        argument propagated to the query parameter, so my owner guard never ran and a foreign planet raised
        `PLAYER_NOT_OWNED` instead of returning 0 rows. Both contracts were rewritten as plpgsql with explicit
        identity/ownership guards before anything was certified.
AUTONOMOUS DECISION (LGI + OGameX did not determine it): energy is exposed as INFORMATION and never as a gate,
        because `start_building` / `evaluate_building_start_internal` contain no energy check at all; and a
        coordinate-targeted RECYCLE from the galaxy view was NOT invented (`start_fleet_mixed` has no
        coordinate parameters and the certified contract picks the nearest field).
VALIDATION  npx tsc -b exit 0 · npm run build completed both environments and the emitted bundle contains the
        three new RPCs · git diff --check clean · LIVE probes inside BEGIN … ROLLBACK · debris table back to its
        original 3 rows (0 in the active universe), 0 item uses · no commit, no push.
```

# CLOUD STATE RECONCILIATION — 2026-09-28

## Scope

Direct audit of GitHub `main` and Supabase LIVE. This document is the durable cloud-state record; `docs/PROJECT_CONTEXT_PROMPT.md` remains the compact operational index.

## GitHub

- Repository: `Developer-0134565/LaGranImplosi-n`
- Branch audited: `main`
- HEAD at audit: `8942b90ed506ff9317abf2418d3b9b22c8065b08`
- Latest CI for this HEAD: successful.
- Migration files present in `supabase/migrations`: 379.

## Supabase LIVE

- Project: La Gran Implosión
- Project id: `evtfsbntvuqmahiskekd`
- Status: `ACTIVE_HEALTHY`
- Latest applied migration: `20260927140000`
- Applied migration rows: 377.
- Public tables: 74.
- Public functions: 338.
- Cron jobs: 6.
- Public RLS tables: 69.

## Migration provenance

The 379 repository filenames and 377 LIVE ledger rows do NOT form a one-to-one filename/version match.

Repository-only version prefixes observed:

```
20260919060000
20260919070000
20260919080000
20260919090000
20260919180000
20260920010000
20260920120400
20260920120800
20260926240000
```

LIVE-only version prefixes observed:

```
20260919055336
20260919061454
20260919062509
20260919070020
20260921133525
20260926130600
20260926133901
```

## AUTONOMOUS GAP SWEEP — 2026-09-28

The previous 2026-09-27 items for espionage buildings/research gating and P3 ACL cleanup are CLOSED and must not be reopened as pending work. The fleet browser certification remains ENVIRONMENT BLOCKED only: the route is defined, but no browser driver + human DEV credential are available, so no result is simulated.

New verified gameplay gap closed LIVE in this pass:
- AI target beginner protection: the existing human 24-hour beginner-protection contract was already wired into the ATTACK insert trigger, but deliberately returned NOT_HUMAN_TARGET for AI empires. The approved project rule is to reuse the same existing beginner protection for AI targets. LIVE migration 20260928032301_extend_beginner_protection_to_ai_targets removes the human-only branch while preserving the same 24-hour window and TARGET_BEGINNER_PROTECTED enforcement. LIVE verification: 33 AI empires currently inside the 24-hour window are protected; 592 older AI empires are expired/unprotected; the human protection path remains intact.
- AI activation remains product-gated: all 625 AI profiles are currently DORMANT; the worker/dispatcher remains inert until explicit activation. No activation was performed.

Local frontend validation after the UI Designer CSS repair: npx tsc -b PASS, npm run build PASS; the only git diff --check output was the existing LF→CRLF warning for public/assets/ogamex/objects/manifest.json.

Next technical sweep should not repeat espionage gating or P3 ACL. Candidate open areas remain the documented economy/product-decision items, moon polishing decisions, and the browser certification environment blocker.
  UI (v1)            PDA Shell v1 (2026-09-28) — nueva SUPERFICIE modular en `src/screens/pda/PdaShell.tsx`
                     + `src/styles/pda.css`, montada como vista `pda` en la navegación. Módulos: OVERVIEW
                     (funcional, sólo lee estado ya en memoria, 0 llamadas nuevas), MESSAGES,
                     NOTIFICATIONS, IA ASSISTANT y MINI-GAMES (los cuatro son PLACEHOLDERS).
                     Messages NO se migra: la bandeja existente sigue siendo la única fuente de verdad.
                      [SUPERSEDIDO por la entrada 'PDA Messages v1' de mas abajo: a fecha de ese
                      registro MESSAGES deja de ser placeholder. Se conserva el texto original de PDA Shell
                      v1 sin reescribirlo.]
                     La IA está DESCONECTADA (sin proveedor, sin fetch, sin claves); su requisito
                     owner-scoped (auth.uid() → players.user_id → players.id) queda documentado, no
                     implementado. 0 migraciones, 0 RPC, 0 cambios de gameplay. Ver
                     docs/systems/README_UI_DESIGNER.md §9.
### PDA Messages v1 (2026-09-28) — CLOSED / IMPLEMENTED

Estado canónico de la PDA:

```
PDA
├── OVERVIEW        🟢 CLOSED / IMPLEMENTED
├── MESSAGES        🟢 CLOSED / IMPLEMENTED   <- esta misión
├── NOTIFICATIONS   🟡 OPEN / FUTURE
├── IA ASSISTANT    🟡 OFFLINE / FUTURE
└── MINI-GAMES      🟡 STRUCTURE READY (Galaga canvas, sin juego)
```

MESSAGES ya **no** es un placeholder. La PDA es ahora la superficie principal de mensajes.

Arquitectura final:

```
PDA
└── MESSAGES
    └── PdaMessages            (contenedor / presentational slot)
        └── existing inbox slot (montado desde App.tsx)
            ├── PlayerInboxPanel      (existente, sin modificar)
            ├── BattleReportsPanel
            ├── EspionageReportsPanel
            └── existing renderMessages()
```

`PdaMessages` es únicamente un contenedor. **No posee** RPC propio, loading propio, read state propio,
ni segundo sistema de mensajes. La vista `messages` abre la PDA con `initialModule="MESSAGES"`.

**Source of truth (sin duplicación):**

* Existe **una sola instancia de inbox** en toda la aplicación (`App.tsx`).
* `PlayerInboxPanel` sigue siendo la **autoridad funcional** del inbox.
* `get_player_messages` sigue siendo la **única** RPC de lectura (contador unread, LEÍDO/NUEVO, orden,
  límite 50, owner scoping).
* `mark_message_read` sigue siendo la **única** autoridad para marcar lectura (idempotente).
* Ambos contratos backend permanecen **sin modificaciones**. No se creó un segundo inbox.

**Seguridad / ownership** — la autoridad permanece en servidor:

```
auth.uid()
    ↓
players.user_id
    ↓
players.id
    ↓
recipient_player_id
```

El `playerId` que React pasa a `PlayerInboxPanel` actúa **sólo** como guardia/prop de cliente (evita
consultar sin sesión). **NO constituye autoridad de seguridad**: el servidor la impone e ignora
cualquier identificador de jugador que llegue del cliente. No hubo `service_role`, ni `player_id`
arbitrario aceptado por el servidor, ni bypass de ownership, ni cambio de RLS/ACL, ni migración backend.

**Validación certificada:**

```
npx tsc -b          PASS / 0 errors
npx vite build      PASS / 0 errors
git diff --check    PASS / 0 errors

supabase/tests/pda_messages.sql    12 PASS / 0 FAIL
```

El fixture usa `BEGIN ... ROLLBACK` y **no deja datos LIVE**. Verificó: unread counting, mark-read,
persistencia de `read_at`, idempotencia, aislamiento cross-owner, el error
`PLAYER_MESSAGE_NOT_FOUND_OR_NOT_OWNED`, no-session → 0 rows, ACL intacta
(`authenticated` + `service_role`; `anon` denegado), y `player_messages` permanece cerrada a acceso
directo del cliente. Post-run verificado: `probe users = 0`, `probe players = 0`.

**Limitación de navegador (NO es un PASS):**

```
BROWSER: ENVIRONMENT BLOCKED
```

Motivo: no hay browser driver disponible ni credencial DEV. Por tanto **NO** está browser-certificado:

```
PDA → MESSAGES → message visible → unread → mark read → counter update
```

La certificación actual es: compilación, build, autoridad backend/server y wiring estructural. La
comprobación visual/manual del flujo React queda **pendiente**.

**Documentación ya realizada (ambos cambios aditivos, sin reescribir historia previa):**

* §10 en `docs/systems/README_UI_DESIGNER.md`
* esta entrada en `docs/PROJECT_CONTEXT_PROMPT.md`

**Correcciones de proceso (NO son bugs del producto):** durante la validación se detectaron y
corrigieron dos falsas alarmas del propio proceso de comprobación: (1) un grep `'%pda%'` sobre el SQL
de los contratos producía falso positivo porque la palabra "update" contiene el substring "pda"; (2) el
fixture tenía inicialmente un cierre doble de bloque, corregido y re-verificado. Además, un trailing
blank line introducido accidentalmente en `App.tsx` fue corregido y `git diff --check` quedó limpio.

**Scope protection** — PDA Messages v1 **NO** modificó: Supabase migrations, RPCs, economía, reward
formulas, ACL, AI provider, AI gameplay, ningún engine, ni Notifications, ni IA Assistant, ni
Mini-Games, ni PG-09, ni PG-10. Todos ellos permanecen fuera de esta misión.

Siguientes candidatos separados (NO expandir esta misión): Notifications, IA Assistant, Mini-Games.
### PG-09 — LOOT CAPACITY (2026-09-28) — ANALYSIS ONLY, NO CODE CHANGED

Scope note: this mission was briefed as "expedition loot capacity", but the repository's canonical
`PG-09` is the **ACS/combat loot-capacity attribution** (`README_COMBAT_ENGINE` §20 table, §22.1). Both
readings were analysed; neither required a code change, and **no new rule was invented**.

```text
Canonical PG-09 (ACS/combat, apply_attack_loot):  IMPLEMENTED TECHNICALLY — no product decision open
  capacity = sum(cargo_capacity) of the ORIGINAL round-1 composition of every ATTACKER/FLEET
  participant (so the ceiling never depends on who survived). 6/6 structural checks re-verified LIVE
  2026-09-28. Certified by supabase/tests/combat_acs_settlement.sql (19/19, incl. E1 = 36700 oracle).
  PG-10 is a SEPARATE and also-implemented gate (allocation proportional to SURVIVING capacity).
  Status correction: PROJECT_CONTEXT said "UNRESOLVED PRODUCT DECISION"; that was superseded the same
  day by README_COMBAT_ENGINE §24 (migration 20260922060013). The index line is now corrected and the
  contradiction is reconciled in README_COMBAT_ENGINE §23.12.

Expedition loot path (the briefed chain), for the record — ALREADY CERTIFIED, untouched:
  resolve_expedition_arrival -> calculate_expedition_resource_budget
      final = LEAST(base_resource_find * reward_multiplier, cargo_capacity)
  capacity = sum(quantity x ship_definitions.cargo_capacity) of the expedition fleet
  the find is ADDED to the fleet's existing cargo; expedition_results keeps recording ONLY the find
  loot <= cargo : reward == transported == persisted == reported   (no overflow branch)
  loot >  cargo : the find is CLAMPED to the hold; the excess is discarded, and
                  (scaled_resource_find, cargo_capacity) are both exposed by
                  get_player_expedition_reports so the UI can explain the clamp
  multi-resource: expeditions award a SINGLE resource type (select_expedition_resource_type ->
                  METAL|CRYSTAL|DEUTERIUM, with a 1 / 2/3 / 1/3 split), so there is no
                  multi-resource overflow to resolve on this path; the metal->crystal->deuterium
                  cascade belongs to the COMBAT path (apply_attack_loot), not to expeditions
  replay       : fleet_cargo_lifecycle EXPEDITION-4 proves re-resolution is rejected and the find is
                  never added twice
  ownership    : every calculation is server-side; the client never decides loot, capacity,
                  transported amount or allocation
  LIVE probe 2026-09-28: 10 PASS / 0 FAIL, rollback, residue 0
                  (scaled_find=15984, cargo_capacity=25000 -> NO_OVERFLOW; CLAMPED and UNCLAMPED
                   contract payloads both verified verbatim; other player 0 rows; no session 0 rows)
```

**Nothing was implemented and no migration was created**, because the evidence shows both readings are
already complete. The one genuinely open residue is the §24.2 OGameX **rounding convention** for
per-fleet `lootShare` — a documented LGI convention isolated to three `floor(...)` expressions, not a
missing gate. It is listed below as the next candidate; no winner was selected and no alternative rule
was proposed.
### BROWSER CERTIFICATION — FLEET FLOW (2026-09-28) — DIAGNÓSTICO CORREGIDO

Result: **ENVIRONMENT BLOCKED**, pero por un motivo MUCHO más estrecho que el registrado hasta ahora.

```text
LO QUE LAS MISIONES PREVIAS DECÍAN:  "no driver installed (playwright/puppeteer/cypress absent)"
LO QUE ES CIERTO AHORA:               el DRIVER FUNCIONA. Ya existe en el proyecto, con 0 dependencias.

Evidencia medida 2026-09-28:
  node scripts/ui-engine-certify.mjs  ->  exit 0, 27/27 PASS
  navegador real: Microsoft Edge headless vía CDP (protocolo DevTools) usando sólo WebSocket/fetch nativos
  binario: C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe  (Chrome también presente)
  capturas reales en %TEMP%\lgi-ui-certify (incluye 04-login.png = superficie real de login renderizada)
  superficie comprobada: 24 Fleet (deck + bundle) y 27 login real, sin errores de consola
```

Por tanto `playwright|puppeteer|cypress` ausentes de `package.json` **NO** implican falta de driver: ese runner
usa CDP directamente y no necesita ninguna de ellas. Instalar Playwright sería redundante (§4.A ya resuelto).

**ÚNICO BLOQUEO REAL: credencial humana DEV.** `.env.local` sólo contiene `VITE_SUPABASE_URL`,
`VITE_SUPABASE_PUBLISHABLE_KEY` y `SUPABASE_SERVICE_ROLE_KEY`; no hay cuenta de test. El runner actual
comprueba la superficie SIN sesión y deliberadamente no toca Supabase.

Lo que NO se hizo a propósito (regla dura de la misión):
  · NO se inventó un usuario ni se fijó una contraseña.
  · NO se usó `service_role` como sustituto de login de jugador.
  · NO se convirtió una sesión SQL privilegiada en una "certificación browser".
  · NO se llamó a ningún RPC para simular la interacción del navegador.

Para desbloquear hace falta, y sólo una de estas dos:
  A) que el dueño facilite una cuenta DEV humano (email/password), que se use SÓLO en runtime del runner
     y NUNCA se escriba en el repo; o
  B) un mecanismo de sesión reutilizable ya previsto por el proyecto (hoy no existe).

Con la credencial, el runner existente ya cubre login/viewports/login-surface; faltaría extenderlo con el
recorrido de flota (origen -> destino -> naves -> misión -> dispatch -> fila en fleet_movements ->
transición de estado -> retorno) y los negativos (ownership, flota inválida, misión inválida, doble envío).

Estado del árbol: sin cambios de código. Residuo LIVE 0 (0 fleet_movements, 0 mensajes, 0 usuarios de prueba).

### BROWSER CERTIFICATION — FLEET FLOW (2026-09-29) — CLOSED 🟢

El diagnóstico de 2026-09-28 queda **superado**: la credencial DEV se facilitó y la certificación se
ejecutó de verdad. Detalle completo en `README_FLEET_ENGINE.md` §33.

```text
BROWSER: Microsoft Edge headless, driver CDP nativo (0 dependencias)
RUNNER:  scripts/fleet-browser-certify.mjs
LOGIN:   credencial DEV real vía el formulario real, sin bypass
FLOW:    9/9 PASS — login · vista Flotas · origen 1:1:1 · misión ATTACK
         · 1× light_fighter · destino 1:1:4 · LANZAR · dispatch
```

Evidencia LIVE de lo que persistió el servidor y luego procesó el worker real
(`deuteria-fleet-worker`, cron de 1 s, activo):

```text
fleet_movements        ATTACK · OUTBOUND · 1:1:1 → 1:1:4 · fuel_consumed 1
fleet_movement_ships   light_fighter × 1
planet_ships           1 → 0 al despachar, y 0 → 1 al volver
ciclo                  OUTBOUND → llegada+combate → RETURNING → COMPLETED
slots                  liberados (0 flotas activas)
```

Negativos, todos rechazados por el **servidor**:

```text
N2  ERROR: Selecciona al menos una nave.
N3  ERROR: El destino debe ser distinto del planeta de origen.
N3  ESPIONAGE_MISSION_REQUIRES_PROBES: only espionage_probe may be sent…
N4  el clic inválido no creó fila: al final existía exactamente 1 flota
N1  auth.uid() → players.user_id en start_fleet (SECURITY DEFINER): un
    player_id de cliente sólo se acepta si resuelve al usuario autenticado
```

**0 cambios en el código de producto.** No se tocó `start_fleet`, ni el worker, ni ninguna regla de
combustible, distancia o slots. Lo único añadido fue el runner de certificación y la documentación.

Dos defectos eran del **arnés de prueba**, no del producto, y quedan documentados en §33.5: el paso 9
buscaba la palabra "LANZAR" en el `body` (que el propio botón contiene) y el paso 6 escribía las
coordenadas sin releerlas. Ambos daban PASS sin que saliera ninguna flota. El runner actual lee el
aviso/`ERROR` del servidor y relee el DOM.

Lo que sigue **sin** certificarse: la cuenta DEV tiene un único `light_fighter`, así que no se
ejercitaron ACS/HOLD, DEPLOY ni composición multi-nave, y la llegada/retorno se observaron por base de
datos en lugar de mirando la cuenta atrás en la UI. Son límites de cobertura de esa cuenta, no defectos
abiertos.
### MINI-GAMES — Galaga: estructura base, SIN juego (2026-09-28)

* `src/screens/pda/games/GalagaCanvas.tsx` monta un `<canvas>` real con su `useRef` y sus dimensiones;
  `games/galaga/constants.ts` (solo 480x640) y `games/galaga/types.ts` (marcador de "aún no
  implementado"). `MINI-GAMES` lo monta dentro del marco PDA.
* **NO hay juego**: sin `ctx.*`, sin `requestAnimationFrame` ni game loop, sin jugador, enemigos,
  disparos, movimiento, colisiones, vidas, score, oleadas, partículas, sonido, IA, física, controles,
  persistencia, Supabase ni leaderboard. Tampoco se definieron los tipos del juego: elegir esas
  formas sería inventar la mecánica, que es lo que el usuario va a construir.
* **0 dependencias nuevas, 0 migraciones, 0 RPC, 0 tablas.** Único CSS añadido: `.pda-galaga-canvas`
  en el `pda.css` existente (borde, fondo, `max-width`); sin sprites ni imágenes.
* Verificado: `npx tsc -b` 0 · `npx vite build` 0 · `npx eslint src/screens/pda` 0 · `git diff --check` 0.
* Límite: **BROWSER ENVIRONMENT BLOCKED** (sin driver ni credencial DEV) — el lienzo montado no está
  certificado visualmente.

## FRONTEND GIGA AUDIT (2026-09-29) — 4 gaps técnicos CERRADOS, 0 migraciones, 0 RPC

Barrido de TODO `src/**` (143 ficheros) contra el catálogo LIVE. Sin cambios de contrato, sin
mecánicas, sin producto. Todo lo corregido es **presentación/estado de cliente**; el servidor sigue
siendo la autoridad en las cuatro superficies tocadas.

```text
SYNC GATE  main · HEAD 3669e27 · origin/main 75bbc48 (1 commit detrás, 0 delante, SIN divergencia;
            el commit remoto es sólo docs/MARCIANITOS_GALAGA_CONTEXT.md, sin solape con el trabajo
            local). 17 modificados + 14 untracked preexistentes PRESERVADOS, 5 stashes intactos.
            NO se ejecutó pull/push/commit/merge/rebase/reset/clean/checkout/restore/stash-*.

CONTRATOS  44 RPC del frontend verificadas contra pg_proc/proargnames: TODAS existen y TODOS los
           argumentos coinciden. Única omisión: `p_until` de `sync_current_planet_resources`, que
           tiene DEFAULT. ⇒ CERO deriva de contrato. Ownership: 0 fugas; las 3 funciones con ACL
           `anon` (can_start_building, sync_current_planet_resources,
           get_universe_evolution_monitor_public) derivan el jugador de auth.uid() internamente.

GAP F1 — ERRORES DE SUPABASE SILENCIADOS (10 sitios) · CERRADO
  bug     `const {data}=await supabase...` sin `error`: un fallo se pintaba idéntico a "vacío".
          Peor caso: `refreshPlanet` (App.tsx) — tras CUALQUIER mutación un fallo dejaba los
          recursos congelados sin aviso, y `ProtectionStatusPanel` ocultaba el panel entero, de modo
          que "no protegido" y "no se pudo comprobar" eran indistinguibles.
  fix     Se captura y se propaga `error` en los 10 sitios. Los de cola/definiciones lanzan y lo
          muestra el `catch` de `loadView`; `refreshPlanet` y onboarding muestran el mensaje real;
          `ProtectionStatusPanel` distingue SIN PROTECCIÓN / NO VERIFICADA + mensaje.
  valid   Re-barrido automático: 10 → 0 sitios sin comprobar. tsc 0 · eslint 0 errores · build 0.

GAP F2 — CARRERA ENTRE RESPUESTAS DE loadView · CERRADO
  bug     loadView spans 6+ `await` y escribe 11 setters compartidos SIN guard de generación.
          Cambiar de planeta/vista deprisa dejaba la cola, definiciones y recursos del planeta
          ANTERIOR sobre el estado fresco del nuevo.
  fix     Token monotónico `loadViewGeneration`; cada invocación captura su generación y aborta
          antes de escribir si hay una más nueva. `catch`/`finally` también se silencian si van
          atrasados, para no apagar el spinner de la carga vigente.
  valid   tsc 0 · build 0. `loadMessages` recibe la generación por el mismo motivo.

GAP F3 — DOBLE SUBMIT DE MUTACIONES DE COLA · CERRADO
  bug     `busyId` es estado de React: dos clics en el MISMO tick (dos definiciones distintas) se
          resuelven antes del re-render, así que `start_building/research/ship/defense` podía
          dispararse dos veces en paralelo.
  fix     Cerrojo sincrónico `actionInFlight` (useRef) + `try/finally` que lo libera siempre.
          No replica ninguna regla: sólo evita la carrera de cliente.
  valid   tsc 0 · build 0.

GAP F4 — BOTONES DE CIERRE SIN NOMBRE ACCESIBLE · CERRADO
  bug     Los "×" de aviso/error (App.tsx, GalaxyView.tsx) eran botones SIN etiqueta: un lector de
          pantalla los anunciaba como "botón" a secas.
  fix     aria-label="Descartar aviso" / "Descartar error" (3 botones).
  valid   tsc 0 · build 0.

ENCODING  `scripts/repair-encoding.mjs --scan`: 600 ficheros, 3 dañados — los 3 son migraciones
          SQL (backend), NINGUNO en `src/`. Verificado byte a byte: `src/` tiene 0 caracteres
          mojibake. El texto que se ve como "ó" en consola PowerShell es artefacto de la
          codificación de la terminal, NO del fichero.

SEGURIDAD 0 secretos en el bundle. Sólo `VITE_SUPABASE_URL` + `VITE_SUPABASE_PUBLISHABLE_KEY`
          (clave publicable, pensada para el bundle por diseño). Sin service_role, sin JWT, sin PAT,
          sin contraseñas en src/. localStorage sólo guarda preferencias de UI (fuentes, plantilla,
          configuración del Designer, cuerpo activo) — ningún secreto.

BROWSER   `scripts/ui-engine-certify.mjs` → **27/27 PASS**, consola limpia, sin overflow horizontal
          en 8 viewports (360/390/430/768/1024/1280/1440/1920). Incluye responsive, UI Designer,
          persistencia, drag&drop y la superficie real de Login sin sesión.
          `scripts/fleet-browser-certify.mjs` → **ENVIRONMENT BLOCKED**: sin `DEV_EMAIL`/`DEV_PASSWORD`
          en el entorno. NO se simuló login ni se falsificó sesión (exit 2, por diseño). La
          certificación de flotas 9/9 del 2026-09-29 sigue siendo la última evidencia válida.

TESTS     `npx tsc -b` 0 · `npm run build` 0 (bundle 819.93 kB) · `npx eslint src` 0 errores
          (5 warnings react-hooks preexistentes, ninguno nuevo) · `git diff --check` 0.

CERRADO Y NO TOCADO  Research Lab (16 gates), Espionage, P3 ACL, Guest ownership, Economy,
  Fleet contracts y sus 4 dispatchers, Combat engine, Expeditions, Moons, UI Designer 27/27,
  Galaga canvas, y los 5 stashes. Ninguna regla de negocio, fórmula, coste, tiempo, slot, loot ni
  permiso se modificó: esta auditoría no cambió ni una línea de backend.

DECISIONES DE PRODUCTO (NO implementadas) — ver sección PRODUCT DECISIONS del informe.
```

* Criterio: **Cline prepara el lienzo, el usuario construye el juego.** Ver
  `docs/systems/README_UI_DESIGNER.md` §11.

---

# CERTIFICACIÓN END-TO-END GIGANTESCA EXTRA (2026-09-29)

Auditoría de certificación *no destructiva* recorriendo la cadena completa
`Browser → React → Supabase client → Auth → RLS/ACL → RPC → PostgreSQL → workers/cron → estado → Browser`.
No reaudita los gaps ya cerrados: prueba que la cadena **no se rompe**.

## Resultado por área (medido, no heredado)

```text
SYNC GATE     branch=main  HEAD=3669e27  origin/main=75bbc48  merge-base=3669e27
              ahead=0  behind=1  · 18 modified · 0 staged · 29 untracked · 5 stashes
              (behind=1 = commit de SOLO docs, no de código)

CONTRATOS     49 RPCs derivadas mecánicamente de src/** (scripts/contract-inventory.mjs):
              49/49 existen en pg_proc y son authenticated-EXECUTE. 0 cables rotos.
              23 tablas leídas por el cliente: 23/23 con RLS activa.

IDOR LECTURA  15 categorías de datos privados de B, rol `authenticated` con el JWT real
              de A  ->  0 filas en las 15.

IDOR ESCRITURA directa  -> bloqueada a nivel GRANT (ni llega a RLS):
              UPDATE planet_resources/planet_buildings/planets/player_messages/
              fleet_movements/player_research = 0 filas
              INSERT planet_ships/planet_resources/player_messages/building_queue =
              permission denied

IDOR vía RPC  Los 4 dispatchers + cola + carga + recall + soporte + comercio + salto/falanx
              + destrucción lunar: 37/37 rechazados con motivo autoritativo. Ninguno aceptó
              un ID del jugador B ni de un IA.

NEGATIVOS     41/41 rechazados: qty 0, negativa, NaN, Infinity, decimal, 1e18, NULL,
              UUID inexistente, id de sistema, destino propio/inexistente/NULL, composing
              vacío o negativo, misión inválida, moon_destruction contra planeta,
              ESPIONAGE con cazas, RECYCLE con cazas. Todos con mensaje autoritativo.

FLEET E2E     dispatch TRANSPORT -> OUTBOUND + combustible + slot ocupado
              -> worker (llegada) -> COMPLETED -> 20/20 naves devueltas -> slot liberado
              -> worker reejecutado: IDEMPOTENTE.
              recall_fleet: OUTBOUND -> RETURNING con returns_at calculado.

WORKERS       6 jobs pg_cron activos; 60 min = 3.666 ejecuciones, 0 fallos.
              fleet 3.524 · heartbeat 60 · ai-policy 12 · ranking 12 · wreck 6.
              universe_process_health.consecutive_failures = 0.

BROWSER REAL   ui-engine-certify.mjs (CDP nativo, sin Playwright/Puppeteer): 27/27 PASS,
              0 errores de consola. Viewports 320→2560: 12/12 sin overflow, 0 errores.
              Autenticado: ENVIRONMENT BLOCKED (sin DEV_EMAIL/DEV_PASSWORD).

REGRESION     tsc -b 0 · vite build 0 (819.93 kB / 204.36 kB gzip) · eslint 0 errores
              (5 warnings react-hooks preexistentes) · git diff --check 0.

ENCODING      src/** + docs/** + scripts/**: 0 mojibake.

DRIFT         4 migraciones del repo sin fila LIVE, pero TODAS verificadas presentes en el
              cuerpo real de las funciones. El drift es de NOMBRE, no funcional.
              No se tocó el ledger.
```

## Falsos positivos descartados contra la fuente de verdad (§57)

```text
"service_role en el bundle"   → texto de UI del asistente IA. 0 claves. FALSO POSITIVO.
"mojibake en src/**"          → terminal PowerShell, verificado a nivel de bytes. FALSO POSITIVO.
"3 SECURITY DEFINER para anon"→ can_start_building / sync_current_planet_resources /
                                get_universe_evolution_monitor_public devuelven
                                AUTHENTICATION_REQUIRED sin sesión. FALSO POSITIVO.
"HOLD/COLONIZE no son misiones"→ van por start_support_fleet / start_colonize_fleet
                                (contratos propios). FALSO POSITIVO.
"el worker ignora la flota"    → INVALID_RESOURCE_TIMESTAMP: artefacto del time-travel del
                                propio test (last_calculated_at > arrives_at falsificado).
                                Con reloj coherente el ciclo cierra. FALSO POSITIVO.
"provision_player acepta admin"→ sin sesión devuelve AUTHENTICATION_REQUIRED. Con sesión sí
                                lo acepta, pero el username NO es autoridad (0 usos en
                                funciones SECURITY DEFINER). LOW, no crítico.
```

## Bloqueos de entorno (NO bugs)

```text
DEV_EMAIL / DEV_PASSWORD ausentes → la certificación browser AUTENTICADA no es ejecutable.
  fleet-browser-certify.mjs lo detecta y termina con exit 2. NO se simuló login, NO se usó
  service_role como usuario, NO se capturó ninguna credencial.

Fixture LIVE muy escaso → 1 humano, 656 IA, 0 lunas, 0 defensas, 0 movimientos activos,
  0 resultados de expedición. Las vistas Moon / Defense / Combat / Expedition no tienen
  datos LIVE con los que ejercitar render ni ciclo completo. Los CONTRATOS de esas vistas sí
  quedaron certificados por sus fixtures SQL y por la matriz de ownership de esta misión.
```

---

# CIERRE DE BLOCKERS + CERTIFICACIÓN BROWSER AUTENTICADA E2E — 2026-09-29 (2ª vuelta)

Misión de eliminación de incertidumbre, no de cambios. Resultado: **ningún cambio de código**.
Los dos blockers siguen abiertos y están **re-certificados con evidencia medida**, no
supuestos. Se mantiene `CERTIFIED WITH DOCUMENTED BLOCKERS`.

## Sync gate (re-comprobado, no asumido)

```text
branch          main
HEAD            3669e27e4e9d9f44c68f12244e7a4e4154127b0f
origin/main     75bbc48e2b55dc8439ab17e52e254218b96ef8aa
merge-base      3669e27 (= HEAD)  →  ahead 0 / behind 1
modified        18      staged 0      untracked 29      deleted 0
stashes         5 (intactos, ninguno popped ni dropped)
```

Idéntico al baseline declarado. NO se ejecutó pull/push/commit/merge/rebase/reset/clean/
stash pop/stash drop. El working tree conserva el trabajo preexistente tal cual.

## BLOCKER A ~~— navegador autenticado: sigue siendo ENVIRONMENT BLOCKED~~ → **RESUELTO 2026-10-03**

> **SUPERADO (2026-10-03).** Este blocker ya **no** está activo: las credenciales DEV existen
> (`credentials.txt`, local y gitignored), Edge está disponible, y la certificación corrió **9/9 PASS**
> con E2E, ownership, cleanup y **residue 0**. Ver §"GAMEPLAY GAP STATUS — CANONICAL" al inicio.
> Se conserva el texto original como registro histórico.

```text
process.env.DEV_EMAIL     ABSENT
process.env.DEV_PASSWORD  ABSENT
.env.local                 contiene SOLO VITE_SUPABASE_URL, VITE_SUPABASE_PUBLISHABLE_KEY,
                           SUPABASE_SERVICE_ROLE_KEY — ninguna variable DEV_*
```

`node scripts/fleet-browser-certify.mjs` → `ENVIRONMENT BLOCKED — DEV CREDENTIAL UNAVAILABLE`,
exit 2. **Comportamiento correcto**: el runner falla cerrado y no simula nada.

Estado real de identidad en Supabase (verificado, no supuesto):

```text

## BLOCKER B — falta de datos LIVE: re-confirmado, con alcance medido

Censo LIVE medido en esta vuelta (no heredado del informe anterior):

```text
players 672 = 1 humano (DevPlayer) + 671 IA
planetas 672, lunas 0, defensas 0, defense_queue 0
expedition_results 0, espionage_reports 0, planet_support_authorizations 0
debris_fields 3 (otros universos), combat_battles 1, fleet_movements 1 (COMPLETED)
player_messages 6

Para la sesión real de DevPlayer (claims JWT reales, mismo contrato que el frontend):
  economy overview    → 1 fila  (metal/h 0, energy_balance_per_hour -24.2, cap 100000)
  battle reports      → 1 informe
  mensajes            → 4 (Battle report, Fleet arrived, Fleet returned, Fleet returning)
  transport movements → 0
  lunas 0 · defensas 0 · debris available=false (0 campos)
  fleet slots 1 · slots expedición 1 · protección 1 fila · autorizaciones ACS 0
```

⇒ Moon, Defense, Expedition, Espionage, ACS, Debris y Combat **siguen sin datos LIVE** para
el jugador de certificación. Se mantiene la distinción:

```text
CONTRACT CERTIFIED
BROWSER DATA CERTIFICATION BLOCKED
```

## Regresión §9 confirmada en LIVE (determinista, con peso real)

El bug de la energía no era cosmético. Para el planeta real de DevPlayer:

```text
get_planet_economy_overview(...).energy_balance_per_hour = -24.2000000000000000
planet_resources.energy                                  =  0.0000
```

La columna legacy rendería **0** mientras el estado autoritativo es **−24.2/h** (déficit).
La corrección de `PdaShell.tsx` y del Overview es sustantiva y está viva.

## Falso positivo del advisor de RLS — DESECHADO con evidencia

El advisor marcó `rls_disabled` como CRITICAL sobre 5 tablas. Comprobado tabla por tabla:

```text
building_research_prerequisites   RLS=off  anon/authenticated: SELECT/INSERT/UPDATE/DELETE = false
moon_creation_rolls               RLS=off  idem
moon_destruction_attempts         RLS=off  idem
planet_wreck_fields               RLS=off  idem
planet_wreck_field_ships          RLS=off  idem
```

**No son explotables**: no hay ninguna expansive hacia `anon` ni `authenticated`, luego la
ausencia de RLS no cambia el resultado observable. Contrasta con el precedente del propio
proyecto (`20260921044659_enable_rls_on_internal_engine_tables.sql`), que sí habilitó RLS
como segunda barrera. Queda como **deuda de defensa en profundidad**, no como vulnerabilidad.
NO se aplicó la remediación: exige decisión humana (habilitar RLS sin políticas bloquearía el
acceso, y estas tablas son deliberadamente backend-only).

## Drift de migraciones — preexistente, NO tocado

`node scripts/migration-drift-report.mjs` (exit 0) confirma el hallazgo ya documentado:

```text
ventana >= 20260926000000: repo 77 · LIVE 80 · coincidencia exacta 73
4 archivos del repo con MISMO nombre y VERSIÓN distinta de la fila LIVE
  add_player_transport_movements_read_contract  repo 20260928131500 → LIVE 20260928131919
  enforce_espionage_probe_composition_rule      repo 20260928150000 → LIVE 20260928153854
  add_my_attack_protection_read_contract        repo 20260928210000 → LIVE 20260928163608
  add_recyclable_debris_status_contract         repo 20260928220000 → LIVE 20260928184455
```

El drift es de NOMBRE, no funcional. NO se renombró ningún archivo (§34 + §2): el working tree
tiene 29 untracked que deben preservarse y el renombrado corresponde al cierre de la
certificación anterior, no a esta misión.

## Superficie de rutas (enumerada del código, §8)

`type View` en `src/App.tsx:26` — 11 vistas autenticadas, más la superficie pública:

## Certificaciones ejecutadas en esta vuelta

```text
ui-engine-certify.mjs   27/27 PASS · 0 errores de consola · 8 viewports sin overflow
                        (360/390/430/768/1024/1280/1440/1920) · designer's 6 plantillas ·
                        persistencia en localStorage + reload · drag&drop real ·
                        superficie real de Login sin sesión
fleet-browser-certify   ENVIRONMENT BLOCKED (exit 2, por diseño)
contract-inventory.mjs  exit 0 · 49 RPC / 18 tablas
migration-drift-report  exit 0 · ver arriba
```

Sin instalar Playwright/Puppeteer/Cypress: se reutilizó la certificación CDP nativa de Edge.

## Regresión final (§40)

```text
npx tsc -b            0 errores
npm run build         0 errores · 819.93 kB / 204.36 kB gzip (sin cambio)
npx eslint src        0 errores · 5 warnings react-hooks preexistentes (App.tsx ×4, GalaxyView ×1)
git diff --check      0
```

Nota de método: `npm run build` reporta exit 1 si se invoca desde PowerShell porque el aviso
de chunk >500 kB se escribe en **stderr** y PowerShell lo convierte en `NativeCommandError`.
Ejecutado vía `cmd /c` devuelve **0**. El bundle no está roto: es un artefacto del shell.
Tamaño idéntico al certificado el 2026-09-29 ⇒ sin regresión de performance.

## Clasificación final de esta vuelta

```text
AUTHENTICATED BROWSER = ~~ENVIRONMENT BLOCKED~~ **CLOSED 2026-10-03** (9/9 + E2E + residue 0; credenciales disponibles)
DEFENSE / EXPEDITION / MOON / COMBAT / ACS / DEBRIS
                        = BROWSER BLOCKED BY LIVE DATA (0 filas reales)
BUGS NUEVOS DETERMINISTAS = 0
CAMBIOS DE CÓDIGO          = 0
DEUDA DETECTADA            = 1 (RLS defense-in-depth, decisión humana) + drift de nombres preexistente
```

**No se pasó de `CERTIFIED WITH DOCUMENTED BLOCKERS` a `CERTIFIED`** porque la evidencia real
no lo permite: faltan credenciales y faltan datos. Lo que sí se logró es **reducir la
incertidumbre**: el estado del entorno y el de los datos están ahora medidos, no supuestos.


```text
overview · buildings · research · shipyard · defense · fleet
galaxy · expedition · moon · messages · pda
(+ '/' = Login sin sesión; '#ui-designer' = banco del UI Engine)
```

`scripts/contract-inventory.mjs` deriva mecánicamente la superficie: **49 RPC** y **18 tablas**
consumidas por `src/`. Ninguna ruta inventada.

`energyBalancePerHour` es la fuente visual y `planet_resources.energy` NO vuelve a pintarse
(`grep 'planet_resources(energy)'` → 0 resultados en `src/`).

## Seguridad — smoke regression (§38), con sesión real

```text
IDOR        get_planet_economy_overview(planeta AJENO) → 0 filas, sin valor filtrado  BLOQUEADO
            (el planeta ajeno es un planeta IA real, no fabricado)
Sin sesión  las mismas SECURITY DEFINER devuelven 0 filas → fail closed
ACL cliente create_player_message sin EXECUTE para anon/authenticated   OK
            anon no ejecuta ningún RPC de lectura del juego             OK
            anon SÍ ejecuta can_start_building (lectura, ya auditado)  INFO
```

**Las 100+ pruebas NO se repitieron** (no lo exige la misión): smoke únicamente.
Sin degradación respecto a la auditoría anterior.

auth.users                12   (11 is_anonymous = true, 1 con email)
players con user_id        1   →  DevPlayer
```

Existe exactamente **una** cuenta de email y su contraseña es desconocida. No se inventó, no
se reseteó, no se usó `service_role` como jugador y no se capturó ninguna credencial.
**La certificación browser autenticada sigue sin ser ejecutable.** El 9/9 de Fleet del
2026-09-29 permanece como última evidencia válida; no se sustituyó por una simulación.

---

# GAP — EL INVENTARIO DE CONTRATOS DEL CLIENTE ERA INCOMPLETO (2026-09-29, 3ª vuelta)

Misión "siguiente gap de gameplay". Resultado: **no se encontró ningún gap de gameplay
implementable** (CASO C, ver §"Lo que se descartó"), pero sí un defecto real, determinista y con
consecuencia sobre la seguridad de un bucle jugable. **CLOSED**.

## Qué estaba incompleto

`scripts/contract-inventory.mjs` es la herramienta que deriva mecánicamente qué contratos llama
el navegador. Su evidencia se usa literalmente para decidir que un contrato **no tiene llamador
de cliente** y por tanto puede perder el `EXECUTE` de `authenticated`. Sólo buscaba literales:

```js
/\.rpc\(\s*['"]([a-z0-9_]+)['"]/g
```

Pero `src/App.tsx:138` despacha los cuatro contratos de producción a través de una **variable**:

```js
const rpc = type==='building' ? 'start_building'
           : type==='research' ? 'start_research'
           : type==='ship'     ? 'start_ship'
           :                     'start_defense';
const { error:e } = await supabase.rpc(rpc, args);   // <- `rpc` es variable, no literal
```

`supabase.rpc(rpc, args)` no casa con el patrón ⇒ los cuatro nombres **no aparecían**.

## Por qué es un GAP real (y no cosmético)

Medido antes del arreglo:

```text
node scripts/contract-inventory.mjs --names-only   ->  48 nombres
  start_building    reported=False     start_research  reported=False
  start_ship        reported=False     start_defense   reported=False
  can_start_building reported=True     start_demolition reported=True   (control: literales)
```

Estos cuatro son los dispatchers de **edificios, investigación, hangar y defensas**. Un falso
negativo aquí no es un detalle de inventario: es exactamente el predicado que las migraciones P3
usan para revocar. La migración LIVE `20260929014633` lo dice sin rodeos:

> "NO CLIENT CALLER. The UI inventory is derived mechanically by `scripts/contract-inventory.mjs`
> … None of these four appears."

Es decir, **la justificación mecánica de una revocación de ACL descansaba sobre un inventario que
no era una sobre-aproximación sino una sub-aproximación**. El mismo método aplicado a
`start_ship`/`start_defense`/`start_building`/`start_research` los declararía "sin llamador" y
permitiría revocar `authenticated` sobre ellos, rompiendo de forma permanente los cuatro bucles
de producción para todo jugador **sin tocar una línea de `src/`**.

Comprobado LIVE antes de tocar nada (los cuatro siguen con `authenticated EXECUTE = true`: el
juego está intacto hoy y el riesgo es latente, no un incidente):

```text
start_building true · start_research true · start_ship true · start_defense true
```

## Fix

`scripts/contract-inventory.mjs` resuelve ahora el despacho indirecto. Decisión deliberada: la
resolución es una **sobre-aproximación**. Sobre-informar sólo puede hacer una revocación futura
más conservadora (sentido seguro); sub-informar es el sentido peligroso. Los literales que sólo
se **comparan** (`type==='building'`) se descartan, para que los nombres añadidos signifiquen algo
en vez de contaminar el inventario con palabras discriminantes de UI.

```text
antes 48 nombres   despues 52 nombres
nuevos: start_building · start_research · start_ship · start_defense   (y nada mas)
```

## Test de regresión

Guarda la invariante dentro de la propia herramienta, sin base de datos ni red:

```bash
npm run cert:contracts     # -> node scripts/contract-inventory.mjs --assert-client-dispatchers
```

Aserta los cuatro dispatchers **y** un control positivo (`can_start_building`,
`can_start_research`, `can_build_ship`, `can_build_defense`) más la ausencia de operandos de
comparación filtrados. **Control negativo ejecutado**: revirtiendo el fix en una copia temporal
fuera del repo, la guarda falla con

```text
FAIL  client dispatchers not in the inventory: start_building, start_research, start_ship, start_defense
exit 1
```

La guarda **no es vacua**: detecta exactamente la regresión que cierra.

## La revocación ya aplicada sigue siendo válida

Due diligence: el inventario corregido **no invalida** `20260929014633`. Los cuatro nombres que
esa migración revocó siguen ausentes del inventario corregido (y sus `EXECUTE` siguen en `false`):

```text
can_recycle_debris · get_expedition_ship_candidates
get_active_expedition_item_effect · check_defense_requirements  -> present=False, auth_exec=false
```

La decisión de ACL era correcta por otra vía (esos cuatro no tienen llamador de cliente); lo que
era insostenible era **la evidencia** que la sostenía. Nota: el encabezado de esa migración dice
"47 nombres" y la herramienta hoy da 52; la diferencia son los cuatro dispatchers más los nombres
añadidos por `GameplayEnginePanel`/`GalaxyView`/`useFleetDispatch` desde entonces.
**No se editó la migración ya aplicada** (es procedencia); la corrección vive en la herramienta.

## Lo que se descartó como gap de gameplay (CASO C, con evidencia)

Se inspeccionó el ciclo completo antes de concluir. **No hay gap de gameplay implementable**:

| Área | Resultado de la inspección |
|---|---|
| start_ship / start_defense | **Falsa alarma descartada**: `App.tsx:138` sí los llama (vía variable). Las vistas no eran read-only |
| `calculate_building_production_delta` | Ya REPARADO 2026-09-26 + fixture `building_production_delta_contract.sql`; la entrada del mapa OGameX está desfasada |
| Procesadores de investigación "huérfanos" | Deliberadamente internos (`service_role`); el autoritativo es `process_planet_tick` |
| Scheduler de ranking | **Existe** y activo: cron `lagranimplosion-ranking-refresh` `*/5 * * * *`; 10 filas por categoría |
| Tick de economía | **Vivo**: `last_calculated_at` con 32 s de antigüedad, heartbeat activo |
| Colas | Ninguna fila BUILDING atascada; las COMPLETED están correctamente filtradas por la UI |
| `get_player_transport_movements` → 0 filas | **Correcto**: el único movimiento vivo es `ATTACK`, no `TRANSPORT` |
| Misiones de flota | Las 7 de `start_fleet_mixed` (ATTACK, TRANSPORT, DEPLOY, ESPIONAGE, RECYCLE, EXPEDITION, MOON_DESTRUCTION) están cableadas en `fleetContracts.ts`, incluido RECYCLE con su filtro de `recycler` y su pre-chequeo `get_recyclable_debris_status` |
| Bootstrap de jugador nuevo | Cerrado: `bootstrap_new_player_state` + `ai_bootstrap_and_dormant.sql` |

Lo que sigue abierto (**no implementado, y NO se implementa aquí**) ya está clasificado como
decisión de producto en `docs/reference/README_OGAMEX_LGI_MAP.md`: `fusion_plant`, `crawler` y su
tope, lifeforms, alloys, y el resto de la lista NEXT CANDIDATES.

## Verificación

```text
npm run cert:contracts   0  PASS (52 nombres, 4 dispatchers detectados, sin operands)
control negativo         1  FAIL correcto (guarda no vacua)
npx tsc -b               0
npm run build            0  819.93 kB / 204.36 kB gzip  (IDENTICO: cero impacto en produccion)
npx eslint src           0 errores · 5 warnings react-hooks preexistentes
git diff --check         0
node scripts/migration-drift-report.mjs   0  (drift de nombres preexistente, sin tocar)
```

Sin migración nueva, sin RPC, sin worker y sin cambio en `src/**`: el defecto estaba en la
instrumentación de certificación, y arreglarla no altera el juego.

---

# FUSION PLANT + CRAWLER (2026-09-29, 4ª vuelta) — NO GAP en el motor · 1 GAP de visibilidad CERRADO

Misión: implementar los dos bloques económicos "con decisión de producto tomada". Resultado
honesto, medido contra LIVE y no contra el inventario documental:

```text
Fusion Plant   → NO GAP. YA IMPLEMENTADO y CERTIFICADO desde 2026-09-26.
Crawler        → NO GAP en el motor. YA IMPLEMENTADO y CERTIFICADO desde 2026-09-26.
                 ⇒ pero SÍ había un gap real: su tope y su bono no eran visibles para el jugador.
```

## El punto de partida era FALSO (y por eso se verificó LIVE antes de tocar nada)

El brief daba por hecho que había que implementar ambas. No era así. `fusion_plant` y `crawler`
ya existían en LIVE con definición, prerrequisitos, fórmulas y fixture propia:

```text
20260926140000_fusion_plant_and_crawler_definitions.sql   definiciones + prerrequisitos
20260926140200_fusion_crawler_economy_integration.sql     integración en la economía
supabase/tests/fusion_and_crawler.sql                     fixture transaccional dedicada
```

**Causa del error de partida:** la documentación era internamente contradictoria. La misma tabla
"Real state now" del mapa ya decía IMPLEMENTED (líneas 524-525) mientras las líneas 143, 145 y 264
seguían diciendo `PRODUCT DECISION (fusion_plant)` / `TECHNICAL GAP (crawler)` / "contrato completo
pero no implementado", y `PROJECT_CONTEXT_PROMPT.md` §"STILL OPEN" los listaba como pendientes. Se
corrigieron esas entradas **sin borrar la procedencia histórica** (NEXT CANDIDATES se conserva como
registro; la clasificación remite a la tabla autoritativa).

## Re-certificación LIVE de lo que ya existía
Ejecutada **verbatim** contra LIVE, con su propio ROLLBACK: `fusion_and_crawler` → **10 PASS + 1 INFO**.
Residuo 0 verificado (fusion 0 · crawlers 0 · lunas 0 · edificios del humano `crystal_mine=2,
shipyard=1` · naves 1 · cola intacta).

```text
 1 fusion_plant definition + deuterium_synthesizer 5 + energy_technology 3   PASS
 2 crawler definition (planet only) + 4 prerrequisitos                      PASS
 3 fusion 5 con energy_technology 3 suma EXACTAMENTE 220 energía            PASS
 4 el reactor quema 10*L*1.1^L base por hora                               PASS
 5 tanque vacío detiene el reactor: ni energía ni consumo                   PASS
 6 100 crawlers = +0.02 % cada uno (ratio 1.019277)                         PASS
 7 1000 crawlers se topan en 240 unidades efectivas (ratio 1.047550)       PASS
 8 energía del crawler (50/efectiva) estrangula la producción              PASS
 9 el crawler no se puede encolar en una luna                              PASS
10 los almacenes siguen siendo legales en luna (paridad OGameX)             PASS
```

## GAP real cerrado: el tope y el bono del crawler no eran visibles

`calculate_planet_production` ya aplicaba, en servidor, `efectivas = least(cantidad, (suma de
niveles de mina) × 8)`, `bono = 0.0002 × efectivas` y `energía = 50 × efectivas`. **Ningún contrato
lo exponía y ninguna UI lo mostraba**: el hangar sólo pintaba el número bruto de `planet_ships`. Un
jugador con 1 000 crawlers en un planeta topado a 240 no tenía forma de saber que 760 unidades no
hacían nada. Es un "el resultado existe y no se refleja al jugador", no una mecánica ausente.

```text
supabase/migrations/20260929040000_crawler_status_read_contract.sql   NUEVO  (aplicado a LIVE)
supabase/tests/crawler_status_contract.sql                           NUEVO  7 PASS
src/App.tsx                                                          hangar: TOPE / EFECTIVAS / BONO / ENERGÍA-h
src/lib/database.types.ts                                            tipo del RPC
```

**No se inventó ninguna regla.** El contrato `get_planet_crawler_status(uuid)` copia literalmente
las expresiones de `calculate_planet_production`, y la economía certificada **NO se modificó**. Para
que la duplicación no se convierta en una segunda fuente de verdad, la fixture compara el contrato
CONTRA la economía: con 1 000 crawlers, el contrato dice 240 efectivas y la producción debe comportarse
como si fueran 240 (`ratio 1.047550`, idéntico al de la fixture histórica). Si alguien cambia el
tope en un solo sitio, la fixture falla.

El cliente **no calcula nada**: no envía tope, ni bono, ni cantidad efectiva. Sólo recibe hechos.

```text
crawler_status_contract   1 ACL (authenticated sí, anon/PUBLIC no)         PASS
                          2 propietario: 100/240/100/2.0000/5000           PASS
                          3 sin sesión → 0 filas                            PASS
                          4 planeta ajeno → 0 filas (no un valor)           PASS
                          5 uuid inventado → 0 filas                        PASS
                          6 1000 → tope 240 y la ECONOMÍA coincide          PASS
                          7 sin crawlers: bono 0, energía 0, tope sigue     PASS
```

## Seguridad / ownership

`auth.uid() → players.user_id → planeta propio`; un planeta ajeno devuelve **cero filas**, nunca un
valor ni un error (misma forma fail-closed que `get_planet_economy_overview`). `SECURITY DEFINER`
con `search_path` fijado, `EXECUTE` sólo para `authenticated`. Sin bypass: el contrato es de sólo
lectura y no participa del settlement.

## Orden de aplicación de la economía (auditado, no asumido)

```text
base de minas/planta  ->  + bono crawler (0.0002 · efectivas, dentro de la base de la mina)
                      ->  × economy_rate × production_rate del universo
                      ->  × (1 + bonuses de objetos/vidaformos)
                      ->  × production_factor (energía: min(1, producción/consumo))
                      ->  × factor de plasma
deuterio: … - consumo del reactor (10·L·1.1^L, dentro del mismo rate del universo)
energía:  planta solar  +  reactor (30·L·(1.05+0.01·ET)^L, sólo si hay deuterio)
```

## OGameX

```text
OGameX   reactor: energía 30·L·(1.05+0.01·ET)^L, consumo 10·L·1.1^L;
         crawler: +0.02 % por unidad, tope por niveles de mina, 50 de energía por unidad.
LGI      Idénticas, con DOS divergencias ya inscritas en la migración 20260926140200:
         (a) el reactor se detiene sin deuterio (regla OGame clásica; el código de OGameX la
             aplicaría sin condición y daría energía gratis);
         (b) el consumo se escala por `economy_rate × production_rate` del universo, porque el
             devengo de LGI escala TODA la producción/hora por esos factores.
```

Límite de esta verificación: el fichero de definiciones que la documentación histórica citaba
(`application/Settings/BuildingObjects.php`) **ya no existe** en `main` de `lanedirt/OGameX` (404; el
repo reestructurado no tiene `app/Settings`). Se sondeó la estructura por la API del repo. La paridad
se afirma contra la **variante clásica documentada** —que es la que aporta el brief y la que ya
estaba inscrita en la migración—, no contra un fichero upstream que no se pudo localizar. No se
inventó nada para tapar ese hueco: no hacía falta, porque no hubo que implementar.

## Regresión

`fusion_and_crawler` re-ejecutada **después** de la migración nueva → **10/10 PASS**, sin cambios.
Economía, Research, Shipyard, Defence, Fleet, Espionage, Luna, Mensajes y AI **no se tocaron**
(cero migraciones sobre funciones certificadas; el único DDL es una función de lectura nueva).

## Verificación de la vuelta

```text
fusion_and_crawler        10 PASS + 1 INFO   LIVE, rollback, residuo 0
crawler_status_contract    7 PASS            LIVE, rollback
fusion_and_crawler (tras) 10 PASS           regresión, sin cambios
npx tsc -b                 0
npm run build              0   820.54 kB / 204.47 kB gzip (+0.61 / +0.11 kB por la UI)
npx eslint src             0 errores · 5 warnings react-hooks preexistentes
git diff --check           0
contract inventory         53 RPC (antes 52) · el nuevo detectado · guarda de dispatchers PASS
```

Browser: **ENVIRONMENT BLOCKED** (`DEV_EMAIL`/`DEV_PASSWORD` siguen ausentes). No se simuló sesión
ni se usó `service_role` como jugador. La evidencia es SQL/LIVE, y así se declara.

  IMPLEMENTADO (2026-09-30, segunda vuelta) - MISSILE UI
    superficie  src/MissileControlPanel.tsx (nuevo) montado en la vista `defense` de App.tsx con el mismo
                envoltorio que `buildings` usa con BuildingDemolitionPanel. Muestra silo (nivel, usados/capacidad,
                libres), ABM/IPM (en tenida / en cola / coste / estado), lanza IPM por coordenadas y lista los
                movimientos MISSILE_ATTACK. Sin selector de prioridad (D3), sin escrituras directas, sin
                tratar el IPM como nave, sin heuristicas de ownership.
    permisos    20260930231000 - UN GRANT: `authenticated` gana EXECUTE en `start_missile_attack`, que se habia
                creado sin el y por tanto era inaccesible desde el navegador. Es el unico hueco de backend
                que la UI necesita. Los helpers de solo lectura SIGUEN CERRADOS al cliente a proposito:
                abrirlos saltaria el RLS owner-scoped de planet_buildings.
    produccion  sin cambios: start_defense/can_build_defense ya eran ejecutables por el cliente y
                ui_defense_definitions/ui_building_definitions devuelven SETOF, asi que ya exponen el silo
                y las columnas nuevas sin contrato nuevo.
    tests      supabase/tests/missile_ui_surface.sql - 5 PASS (postura de seguridad; NO duplica el resto).
                `npm run cert:contracts` PASS con `start_missile_attack src/MissileControlPanel.tsx`.
    browser    PASS 11/11 (2026-09-30) con `scripts/missile-browser-certify.mjs` (Edge headless + CDP, sin
                dependencias). Login real, vista de defensas, panel del silo, ABM/IPM en catálogo,
                capacidad coherente, SIN selector de prioridad, producción real por la UI, resolución
                de objetivo ajeno y LANZAMIENTO real (`1 IPM en vuelo hacia AI World G1:S1:P3`).
                Verificado en BD: MISSILE_ATTACK, target_priority 0, 0 filas en fleet_movement_ships,
                vuelo 30 s, IPM consumido 1->0, COMPLETED sin vuelta, 1 informe atacante + 1 defensor.
                El estado del jugador DEV se restauró por completo (residuo 0). Detalle en
                README_MISSILE_SYSTEM.md §16.7 (histórico). La re-certificación de navegador NO se repitió en la
misión de cierre 2026-10-02 y se registra honestamente como `NOT RUN` — ver §5 MISSILE SYSTEM
y README §18.10.
---

# INDEPENDENT TECHNICAL GAP CLOSURE — 2026-10-01

Misión de **auditoría dirigida + cierre de GAPs técnicos independientes**. No se implementó ninguna
mecánica nueva. Evidencia primaria completa:
[`docs/audits/INDEPENDENT_GAP_CLOSURE_2026-10-01.md`](audits/INDEPENDENT_GAP_CLOSURE_2026-10-01.md)
(este bloque es sólo el índice operativo; el detalle vive en ese informe).

## SYNC GATE de la misión

```text
branch          main
HEAD            3669e27e4e9d9f44c68f12244e7a4e4154127b0f   (sin cambios)
origin/main     75bbc48e2b55dc8439ab17e52e254218b96ef8aa
merge-base      3669e27 (= HEAD)  → SIN DIVERGENCIA
ahead/behind    0 / 1   (el commit remoto toca sólo un doc nuevo → sin colisión)
staged 0 · deleted 0 · stashes 5 (intactos, ninguno aplicado ni descartado)
```

Sin `pull` · `push` · `commit` · `merge` · `rebase` · `reset` · `clean` · `checkout` · `restore` ·
`stash pop/drop` · `db push` · `migration repair`. Ninguna credencial leída ni revelada.

## Qué se corrigió (resumen; el detalle está en §6 CLOSED)

| # | Severidad | Defecto | Migración | Regresión |
|---|---|---|---|---|
| 1 | **CRÍTICA** | `resolve_expedition_return` referenciaba `status` sin cualificar (OUT param vs columna) → `ERROR 42702` en el **100 %** de los retornos de expedición | `20261001070000_fix_ambiguous_status_in_expedition_return.sql` (LIVE `20261001193223`) | **15/15 PASS** |
| 2 | **ALTA** | `collect_debris` rechaza un campo agotado/borrado y el worker lo degrada a WARNING → el reciclador queda `OUTBOUND` para siempre (naves + slot perdidos) | `20261001060000_fix_stuck_recycle_fleet_empty_debris_field.sql` (LIVE `20261001192015`) | **19/19 PASS** |

Ambos arreglos son **un único call-site** cada uno, hechos con splice anclado sobre
`pg_get_functiondef()` (misma técnica que `20260930240000` / `20260930241000` / `20261001030000` /
`20261001040000`), con bloque de postcondiciones que **aborta la migración** si el estado no es el
esperado. Cuerpos que **no** debían cambiar verificados por `md5(prosrc)`: `collect_debris`,
`start_fleet_mixed`, `calculate_recycler_capacity`, `get_player_fleet_slots`.

**Ledger:** los ficheros locales llevan prefijo `20261001060000` / `20261001070000` pero LIVE registró
versiones `20261001192015` / `20261001193223`. Es el **drift de provenance ya documentado** (cada
`apply_migration` registra su propia versión). **No renombrar, no marcar revertida, no tocar el ledger.**

## Reparaciones de certificación

- `fleet_stuck_return_arrival_regression.sql` tenía `rollback;` **en mitad del cuerpo**: el fichero
  abortaba con `42703 column "v_dst" does not exist` y sus aserciones **4–13 eran código muerto**
  (nunca se ejecutaron); el bloque de resumen además corría antes del `rollback`, así que sólo contaba
  3 filas. Con agravante: lo posterior al `rollback` habría corrido en **autocommit** contra LIVE.
  Reparado moviendo el bloque al final → **13/13 PASS** (antes sólo 3 ejecutables). Se corrigió
  además una aserción que comparaba `count(*) = 5` sobre un conteo de **filas**, contradiciendo su
  propio comentario («credited exactly once»).
- `recyclable_debris_status.sql` y `fleet_worker_contract.sql` comparaban **totales absolutos** donde su
  propia convención documentada exige **deltas** antes/después; en LIVE fallaban por datos ajenos al
  contrato, no por defectos del motor → **12/12** y **6/6 PASS**.
- Dos fixtures nuevas: `recycle_fleet_empty_field_regression.sql`, `expedition_return_ambiguous_status_regression.sql`.

**Total de la vuelta: 19 + 15 + 13 + 9 + 8 + 12 + 6 = 82 assertions, todas PASS.**

## Estado de validación

```text
tsc -b                 PASS
eslint src             PASS  (0 errores)
npm run build          PASS
cert:contracts         PASS  (56 RPC / dispatchers verificados, guard de dispatchers indirectos OK)

LIVE, residuo tras la misión
  movimientos no terminales    0
  shipyard / defense / building / research queues   0 en las cuatro
  planet_wreck_field_battles   0
  campos de escombros drenados con residuo < 1e-9   0
```

**El movimiento LIVE atascado (GAP 1) se resolvió solo** en el siguiente tick del worker de 1 s tras
aterrizar el arreglo: recuperó sus 5 `large_cargo` + 125 000 metal al planeta origen y liberó su slot
de flota. No se ejecutó ninguna otra escritura fuera de ROLLBACK.

**Browser:** esta misión **no ejecutó** ninguna certificación de navegador nueva. Toda la evidencia es
SQL/LIVE. No hay que declararla.

## Áreas auditadas sin GAP nuevo

Economía y liquidación · las cuatro colas · combate, botín e idempotencia · espionaje · ACS/HOLDING ·
identidad, ownership, RLS y ACL · workers, cron y heartbeat · prerrequisitos y catálogos · mensajería ·
consistencia frontend↔backend. Ningún sistema previamente certificado se ha reabierto.

OGameX (`main` @ `2649076`) consultado literalmente: `RecycleMission.php` y `Abstracts/GameMission.php`.
`OGameX: no new relevant difference` en el resto de áreas.

## Decisiones de producto — SIN CAMBIOS en esta misión

Colonias (rangos OGameX + resultado aleatorio persistido) · DEFEND/ACS (ciclo completo vía
`planet_support_authorizations`) · Friends/Buddies · Alliances/Guilds · Late-join · normalización de
los 729 perfiles antiguos de IA · activación de IA (todas `DORMANT`) · protección de principiantes
para ataques de IA · **escudo** (seguye siendo **decisión de producto** para una misión posterior;
**NO está implementada**).

La regla del **MANDATORY SYNC GATE** (repetirlo literal en cada prompt de agente y re-ejecutarlo al
iniciar cada sesión) permanece vigente e inalterada.

---

## SOCIAL FOUNDATIONS + DEFEND INTEGRATION (2026-10-02) — AUDIT + FUNDATIONS, NOTHING DEPLOYED

Three forward-only migrations were written **locally only**. **No migration was applied to LIVE, no
`db push`, no commit, no push, and no production function was modified.**

### SYNC GATE (identical to the previous mission; nothing changed)

```text
ruta/rama     C:\Users\Missingn0\LaGranImplosi-n   main
HEAD          3669e27e4e9d9f44c68f12244e7a4e4154127b0f   (= merge-base)
origin/main   75bbc48e2b55dc8439ab17e52e254218b96ef8aa
ahead/behind  0 / 1   (remote-only: docs: add Marcianitos learning context — docs only, no collision)
modified 22 · untracked 81 · stashes 5 (untouched)
```

No pull/merge/rebase/reset/clean/stash-pop/commit/push. `credentials.txt` never read.

### 2. AUDIT OF THE EXISTING SYSTEM (measured on LIVE 2026-10-02)

| Block | Status | Evidence |
|---|---|---|
| Friends/Buddies | **NOT_IMPLEMENTED** | 0 tables, 0 functions matching `buddy\|friend\|alliance\|guild` |
| Alliances/Guilds | **NOT_IMPLEMENTED** | same query: 0 rows |
| ACS planet authorization | **IMPLEMENTED** | `planet_support_authorizations` + `grant/revoke/get_player_support_authorizations` |
| Support dispatcher | **IMPLEMENTED for `ACS_HOLD`** | `start_support_fleet(...)`, idempotent, fuel/ship debit atomic |
| DEFEND dispatch | **DEFINITION_ONLY** | step 2 of `start_support_fleet` raises `COMBAT_SUPPORT_NOT_READY` |
| DEFEND combat | **NOT_IMPLEMENTED** | see §6 below |
| `holding_until` / `HOLDING` | **IMPLEMENTED** | `fleet_movements_holding_until_check`, `..._after_arrival_check` |

**Reused, never duplicated:** identity always resolves through `players.user_id = auth.uid()`
(new helper `current_player_id()` wraps that one chain); the social tables follow the certified
`planet_support_authorizations` precedent — **no direct grants to `authenticated`/`anon`**, reachable
only through `SECURITY DEFINER` RPCs; authorization helpers follow the
`grant_planet_support_authorization` ownership style.

### 3. OGAMEX REFERENCE (read verbatim, `lanedirt/OGameX` @ `2649076`)

- `app/Models/BuddyRequest.php` — `sender_user_id`, `receiver_user_id`, `status` (0 pending / 1
  accepted / 2 rejected), `message`, `viewed`.
- `app/Services/BuddyService.php` — `areBuddies()` matches the pair in **either** orientation;
  `sendRequest()` refuses sender === receiver; removing a buddy is **symmetric** (either side).
- `app/Models/Alliance.php`, `AllianceMember.php`, `AllianceRank.php`, `AllianceApplication.php`,
  `app/Services/AllianceService.php` — tag 3–8, name 3–30, tag unique; **founder inserted as a member
  with `rank_id = NULL`** holding **ALL** permissions; one alliance per user; `leaveAlliance()`
  refuses for the founder. Rank vocabulary is exactly `AllianceRank::PERMISSION_*`.
- `app/GameMissions/AcsDefendMission.php` — the decisive rule:
  `if (!$isBuddy && !$isAllianceMember) return new MissionPossibleStatus(false, 'You can only send
  ACS Defend missions to buddies or alliance members!')`, plus `checkOwnPlanet()`, destroyed-target
  and vacation checks.

**Adaptations documented:** OGameX keys everything on `user_id`; LGI uses **player id** everywhere, so
every foreign key is `players(id)`. Statuses became `text` (not smallint) for readability. Buddy is
**one row per unordered pair** (unique over `least/greatest`), so duplicates are impossible in
storage. Buddy and alliance stay **separate** models: being buddies never implies membership.

### 4–5. WHAT WAS BUILT (local files, NOT deployed)

- `20261003000000_social_foundations_buddies.sql` — `player_buddies` + `current_player_id()`,
  `send_buddy_request`, `respond_buddy_request`, `cancel_buddy_request`, `remove_buddy`,
  `list_buddies`, `players_are_buddies`.
- `20261003010000_social_foundations_alliances.sql` — `player_alliances`, `player_alliance_ranks`,
  `player_alliance_members`, `player_alliance_applications` + `alliance_member_permission`,
  `create_alliance`, `apply_to_alliance`, `respond_alliance_application`, `leave_alliance`,
  `dissolve_alliance`, `create_alliance_rank`, `set_alliance_member_rank`, `list_alliance_members`,
  `players_in_same_alliance`.
- `20261003020000_defend_social_authorization.sql` — `can_defend_player`,
  `defend_dispatch_readiness`. **Does not touch** `start_support_fleet`, `resolve_combat`,
  `resolve_attack_arrival`, the settlement or the worker.
- `supabase/tests/social_foundations_buddies.sql` — 48-assertion fixture.

Identity: **every** RPC resolves the caller from `auth.uid()`; no social RPC accepts a caller id
(assertion 21 proves it from `pg_get_function_arguments`).

### 6. DEFEND — REAL STATE: `PARTIALLY_IMPLEMENTED`

Schema ready, authorization **ready**, dispatch and combat **blocked**:

- `fleet_movements_mission_type_check` admits `DEFEND`; the `holding_until` constraints are in force.
- `start_support_fleet` step 2 refuses: `COMBAT_SUPPORT_NOT_READY`.
- **Measured blocker:** `resolve_combat` never mentions `HOLDING`/`holding_until`. It creates exactly
  two participants — `('ATTACKER','FLEET',p_fleet_id,…)` and
  `('DEFENDER','PLANET',null,destination_planet_id,…)` — and `get_planet_defender_ship_count` sums only
  `public.planet_ships`. **A fleet in HOLDING would never join the battle.** Closing that gap *is* the
  already-selected multi-fleet combat redesign, so it is left isolated and untouched.
- `defend_dispatch_readiness()` derives its answer from the deployed bodies, so it cannot claim a
  readiness the engine lacks. **No partial solution was invented.**

Planet-scoped `planet_support_authorizations` and player-scoped social authorization **both** remain;
neither replaces the other, and `start_support_fleet` keeps its own check untouched.

### 9. VERIFICATION (executed against REAL deployed objects, inside ROLLBACK)

Buddies **16/16 PASS**; alliances **33/33 PASS** (29 + 4 retests); DEFEND authorization **10/10 PASS**.
Every negative assertion checks a **specific error code**, and each control asserts its own
precondition first. Two defects were **found by execution and fixed**: (a) a CHECK constraint
containing a subquery, which PostgreSQL forbids — replaced by a `BEFORE INSERT/UPDATE` trigger;
(b) `players_in_same_alliance` silently depended on a founder membership row — hardened to test
`founder_player_id` on **both** sides.

### 11. REMAINING GAPS

- **DEFEND dispatch + combat** depend on the multi-fleet redesign (separate mission).
- **Late-join** remains a distinct phase, untouched.
- **No frontend**: no services, hooks or UI were written (no TypeScript changed, so no `tsc`/`build`).
- Alliance wars, bonuses, diplomacy, circular messaging, depot/terraformer: **deliberately absent**.
- Browser E2E: **not claimed**; only SQL was executed.

**Product decisions preserved:** DEFEND still to be implemented; OGameX authorization rules adopted
where compatible; social foundations delivered; multi-fleet redesign and late-join untouched; shield
loss on attacking/spying another player untouched; `ACS_HOLD` behaviour unmodified.

---

## SOCIAL FRONTEND + BROWSER INTEGRATION (2026-10-02) — CAPA TS/HOOKS/UI, NAVEGACIÓN, E2E BLOCKED

Capa frontend construida **contra los contratos de las tres migraciones sociales**. **Ningún deploy,
ninguna migración, ningún commit, ningún push.** Sin cambios de identidad, ownership, economía,
flotas, combate ni worker; el flujo de DEFEND sigue intacto y bloqueado.

### SYNC GATE (idéntico al inicio y al final)

```text
rama main · HEAD 3669e27e4e9d9f44c68f12244e7a4e4154127b0f (= merge-base)
origin/main 75bbc48e2b55dc8439ab17e52e254218b96ef8aa · ahead/behind 0/1
modified 22 · untracked 81 → 89 · stashes 5 (intactos)
```

### BLOQUEO RAÍZ DE LA CERTIFICACIÓN BROWSER (medido, no supuesto)

Los contratos sociales **NO están desplegados**: LIVE tiene **0 tablas sociales y 0 RPC sociales**
(`to_regclass('public.player_buddies')` → NULL; el contador de RPC probed devuelve 0). El ledger
sigue en **431 filas, última `20261002004147`**, la misma de antes de esta misión. Son ficheros
locales **untracked**.

Consecuencias honestas, sin maquillar:

- **Browser E2E: `BLOCKED`** por dos causas independientes:
  1. Los RPC no existen → cualquier flujo social devolvería error en el servidor, no el
     comportamiento real.
  2. El arnés existente (`scripts/*-browser-certify.mjs`) exige `DEV_EMAIL`/`DEV_PASSWORD`; no están
     definidos en el entorno, y su propio script **rechaza simular el login**. El arnés además es de
     **una sola identidad**, insuficiente para los dos flujos cruzados que pide la misión.
- **Ningún escenario se declara PASS por inspección estática.**

### Archivos nuevos

- `src/lib/social.ts` — servicio tipado. Centraliza los **18 RPC**; sin `any`, sin casts ciegos; los
  errores conservan `code` en `SocialRpcError`. No envía `playerId` de llamante en ninguna mutación
  (el backend lo resuelve con `auth.uid()`), no toca las tablas sociales directamente (sólo `rpc`) y
  reutiliza el cliente Supabase existente (no crea un segundo).
- `src/lib/useSocial.ts` — `useBuddies`, `useAlliance`, `useDefendReadiness`. Estados
  `loading/ready/error` explícitos, `isEmpty` sólo cuando la carga **terminó bien**, invalidación por
  refresco desde el servidor, guardia monótono contra carreras, y `busy` que impide llamadas dobles.
- `src/screens/social/` — `SocialScreen.tsx`, `SocialModules.tsx`, `socialRegistry.ts`, `index.ts`.
- `src/styles/social.css` — sólo layout/estados con tokens `--lgi-*`.

### Integración en la navegación

`App.tsx`: import, `View` gana `'social'`, un item `SOCIAL` en `navItems` y la rama
`if(view==='social')return <SocialScreen playerId={playerId}/>`. **No se tocó** Classic, Command,
Tactical, ni el flujo de login/guest.

### Contratos consumidos y bloqueos de contrato

Se consumen los 18 RPC de las migraciones. **Tres flujos NO se ofrecen en la UI porque ningún
contrato los respalda** (no se crean RPC nuevos):

| Flujo pedido | Estado | Causa |
|---|---|---|
| Buscar jugador para enviar solicitud | **BLOQUEADO** | no existe RPC de búsqueda; el formulario pide el UUID exacto |
| Ver solicitudes de ingreso recibidas | **BLOQUEADO** | no existe RPC que las liste; `respondApplication` sí existe |
| Ver mis propias solicitudes de ingreso | **BLOQUEADO** | no existe RPC equivalente |
| Descubrir «mi alianza» sin conocer el id | **BLOQUEADO** | `list_alliance_members` exige `alliance_id`; el estado se declara desconocido en vez de adivinarse |

### Validación estática

```text
npx tsc -b                       PASS
npx eslint (ficheros afectados)  PASS
npm run build                    PASS (exit 0; aviso de chunk >500kB preexistente)
git diff --check                 0 hallazgos
```

Se corrigió un defecto real detectado por el lint: `setState` síncrono dentro de los efectos. Los
hooks se reescribieron para escribir estado **sólo tras el `await`** (como ya hacía
`useFleetDispatch`) y `useSocial.ts` se añadió al allow-list existente de `react-hooks/set-state-in-effect`
en `eslint.config.js`, **junto a la justificación**, no como `--disable` silencioso.

### Estado de certificación browser

| Escenario | Resultado |
|---|---|
| 1–12 (flujos cruzados de amistad y alianza) | **BLOCKED** — RPC no desplegados + sin credenciales DEV |
| Sin alianza / sin amigos / duplicados / no autorizado / errores / refresco | **BLOCKED** — misma causa |

**Límites del alcance respetados:** sin rediseño multi-flota, sin DEFEND dispatch/combat, sin
late-join, sin guerras/diplomacia/bonificaciones/mensajería, sin migraciones ni reglas nuevas. No se
ha reabierto ningún sistema certificado.

---

## REPARACIÓN DEL CORPUS DE RECICLAJE Y CERTIFICACIÓN FINAL (2026-10-02) — COMPLETADA

`20261002000000_collect_debris_exact_full_drain` está **DESPLEGADA EN LIVE** (versión registrada
`20261002004147`). Esta misión **no desplegó SQL, no creó migraciones, no ejecutó `db push` y no
tocó datos LIVE**: reparó exclusivamente tres defectos del corpus de pruebas y certificó B1/B2/B3.

### SYNC GATE (inicial y final, sin cambios)

```text
ruta/rama        C:\Users\Missingn0\LaGranImplosi-n   main
HEAD             3669e27e4e9d9f44c68f12244e7a4e4154127b0f   (= merge-base)
origin/main      75bbc48e2b55dc8439ab17e52e254218b96ef8aa
ahead/behind     0 / 1  (remoto: docs: add Marcianitos learning context — solo docs, sin colisión)
modified         22      untracked 81      stashes 5 (intactos)
```

Ninguna operación Git de escritura: sin pull/merge/rebase/reset/clean/stash/commit/push.

### Los tres defectos y su causa

- **R1-12 — PIN MD5 OBSOLETO** (`recycle_fleet_empty_field_regression.sql`). Fijaba
  `md5(prosrc) = 4e63662301c7d89b3b07b720ec4d7627`, el valor **anterior** a la migración. Al desplegar
  esta el motor era correcto y la aserción fallaba igual; el pin ataba la fixture a una release
  histórica. **Medido:** LIVE = `e1b44f438fa1da026a182a0068e20c70`.
  **Corrección (semántica, no un número nuevo):** el pin rígido se sustituyó por una comprobación del
  **código** (comentarios y espacios normalizados) que exige rama de drenaje total exacta para ambos
  recursos, rama parcial con la **fórmula original literal**, la cota de capacidad, las **tres**
  negativas, los `GREATEST`, el `DELETE` de la fila drenada y el `RETURN QUERY`. No se referencia
  ningún MD5 de ninguna versión anterior, y sigue fallando ruidosamente si se rompe cualquier garantía.
- **R1-9 — PRECONDICIÓN PERDIDA** (mismo fichero). La sección C drena el campo por completo y, desde
  esta migración, `collect_debris` **borra la fila**. El `UPDATE` de control afectaba a **0 filas**, así
  que el «control de negativa» en realidad ejecutaba el caso de campo **borrado** — uno de los errores
  que el arreglo absorbe — en vez de «no lleva reciclador». **Medido:** 0 filas en 1:1:16 y la flota
  terminaba `COMPLETED` donde debía abortar.
  **Corrección:** el campo de control se crea **explícitamente** con `INSERT` (5000/5000, no residuo
  decimal ni fila agotada mantenida viva), y se asertan **dos** precondiciones nuevas: que el `INSERT`
  tocó **exactamente 1** fila y que la preparación afecta **exactamente 1** fila. El control negativo
  real se ejecuta igual y la flota queda **verificada en `OUTBOUND`**. Se conserva el control de campo
  inexistente (aserción 5). Sin tocar `collect_debris` ni el worker. La fixture ya no depende de que
  sobreviva una fila agotada.
- **R2-11 — FALSO POSITIVO POR COMENTARIO** (`recyclable_debris_status.sql`). La aserción 11 buscaba
  la subcadena `get_recyclable_debris_status` en `prosrc`; la migración añadió un comentario
  **explicativo** dentro de `collect_debris` que nombra el contrato, y el search lo leyó como
  dependencia. **Corrección:** se eliminan comentarios (`--`, `/* */`) y se exige ausencia de una
  **llamada** (`identificador` + `(`). **No** es «borrar toda aparición y dar PASS»: la misma
  transformación se aserta en **meta-control anti-vacuidad** que **SÍ detecta** una llamada real y
  **NO** detecta una mención en comentario, así que el chequeo no puede pasar por construcción.

### Resultados finales (LIVE, cada fixture por separado, todas con `ROLLBACK`)

| Fixture | Resultado |
|---|---|
| `collect_debris_numeric_residue_regression.sql` | **13 PASS + 1 INFO, 0 FAIL** (A1–A10 + B1/B2/B3; el INFO es el `SUMMARY`) |
| `recycle_fleet_empty_field_regression.sql` | **21 PASS, 0 FAIL** |
| `recyclable_debris_status.sql` | **12 PASS + 2 INFO, 0 FAIL** |

**Convenciones de recuento (documentadas, sin ocultar ninguna aserción).** El primer fixture reporta
`13 PASS + 1 INFO`: las 13 aserciones ejecutables más una fila `INFO` de resumen, que por diseño del
propio fixture **nunca** cuenta como PASS — sus grupos B reportan `PENDING`, no `PASS`, si la migración
no estuviera desplegada. Al estar desplegada, B1/B2/B3 sí ejecutan y PASS. La aserción 9 de
`recyclable_debris_status` está numerada `7b` en el original: son **12** aserciones, no 13. El recuento
de `recycle_fleet_empty_field_regression` sube de 19 a **21** **por las dos precondiciones nuevas que
exige R1-9**; las 19 previas siguen todas presentes.

### Regresión cruzada y delimitación

Orden **adverso** (la fixture que drena y borra la fila corre **primera**, luego el contrato de
status, luego la de residuo) para demostrar que ninguna depende de estado residual: **6/6 PASS**.
Controles transaccionales: `begin;` … `ROLLBACK;` en las tres, temp tables creadas y descartadas
dentro de la transacción, sin DDL persistente. **Residuo en LIVE: 0** — `debris_fields`
4 filas / `188906.96095076400679120000` M / `86393.03904923599320880000` C **idénticos al baseline**;
`fleet_movements` 7, `players` 757, `planets` 758, sin movimientos a medias, slots 0 → 0.

### Integridad de LIVE (antes/después, idénticos)

`md5(prosrc)` sin cambios en **ninguna** función: `collect_debris` `e1b44f43…`,
`get_recyclable_debris_status` `b834a324…`, `calculate_recycler_capacity` `235910c7…`,
`start_fleet_mixed` `611d107d…`, `get_player_fleet_slots` `119b1100…`,
`process_fleet_movements` `16e875ac…`, `process_universe_tick` `c1d9ea7a…`,
`can_recycle_debris` `fc677303…`. `search_path` inalterado, **cero cambios de ACL**, cero migraciones
nuevas (431 filas en el ledger, última `20261002004147`, la misma de antes de esta misión).

**La certificación del reciclaje queda COMPLETADA.** Recogida parcial, capacidades, ACL, permisos y
comportamiento del reciclaje **intactos**. No se tocó runtime, frontend ni otros sistemas
certificados.
