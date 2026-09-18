# FUNCTIONAL AUDIT — LA GRAN IMPLOSIÓN

> Living functional map of the project: what exists, what is deployed, what is connected, what is
> verified and what is missing. Baseline: **2026-09-18** (HEAD `ea677f0`).
>
> Operational status lives in [`../PROJECT_CONTEXT_PROMPT.md`](../PROJECT_CONTEXT_PROMPT.md).
> This document keeps the durable detail of the audit.

## Method

Three states are always distinguished and never merged:

```text
EXISTS IN REPO        (migrations / dump / code)
DEPLOYED IN SUPABASE  (verified live with pg_proc / information_schema / cron.job)
CONNECTED TO FRONTEND (the app actually calls it)
```

Anything that could not be checked is marked `UNKNOWN`. Data was read read-only through the project's
Supabase MCP `execute_sql`.

## Git baseline

```text
branch: main · HEAD: ea677f0 · origin/main: ea677f0 (0/0)
working tree at audit time: identity/ownership work staged+unstaged (not committed)
```

## Inventory

```text
public tables (live): 64   (dump 2026-09-16: 63 → one later addition, identity UNKNOWN)
public functions (live): 231 (dump: 220 → later migrations: monitor + fleet worker + hardening)
pg_cron: installed, 2 active jobs
src/: App.tsx (whole game UI) · GalaxyView · TemplateChrome · LoginPage · lib/{supabase,identity,
      database.types,universeEvolutionMonitor} · components/monitor/UniverseEvolutionMonitor · 24 CSS
supabase/: 29 migrations + tests/buildings_lifecycle.sql + engine docs
docs/: PROJECT_CONTEXT + memory/architecture/systems/reference/tools + production baseline
scripts/: verify-identity.mjs · verify-buildings.mjs · backup-supabase.ps1
```

## Domain map

| Domain | Exists | Backend | Deployed | Frontend | Connected | Real data | Tests | Status |
|---|---|---|---|---|---|---|---|---|
| Identity / Player ownership | YES | YES | YES | YES | YES | YES (2 humans) | YES | CLOSED (ownership hardening applied 2026-09-18, verified) |
| Planets | YES | YES | YES | YES | YES | YES (238) | PARTIAL | YES |
| Resources / Economy | YES | YES | YES | YES | YES | YES | PARTIAL | PARTIAL (divergent helpers) |
| Buildings | YES | YES | YES | YES | YES | YES (15 completed) | YES | PARTIAL (browser test pending) |
| Building queues | YES | YES | YES | YES | YES | YES (0 active / 15 COMPLETED) | YES | YES |
| Research | YES | YES | YES | YES | YES | YES (16 defs, 14 levels, 10 queue rows) | **YES** (`research_lifecycle.sql` 24/24 PASS) | **AUDITED + LIFECYCLE TESTED** — UI cost/time pending ([`README_RESEARCH.md`](README_RESEARCH.md)) |
| Research queues | YES | YES | YES | YES | YES | YES (10 COMPLETED) | NO | YES |
| Shipyard | YES | YES | YES | YES | YES | YES (9 ships, 17 queue rows) | NO | PARTIAL (same UI gap) |
| Defence | YES | YES | YES | YES | YES | YES (5 defences, queues empty) | NO | PARTIAL (same UI gap) |
| Fleet | YES | YES | YES | YES | YES | YES (54 movements) | NO | PARTIAL (no mission view) |
| Fleet missions | YES | YES | YES | YES | YES | YES (4 mission types used) | NO | PARTIAL |
| Combat | YES | YES | YES | NO | NO (reports only) | YES (11 battles) | NO | PARTIAL (backend without UI) |
| Expeditions | YES | YES | YES | YES | YES | YES (32 results) | NO | PARTIAL |
| Lifeforms | YES | YES | YES | **NO** | NO | YES (2 planet_lifeforms) | NO | PARTIAL (backend without UI) |
| Universe / Galaxy / Systems | YES | YES | YES | YES (map) | YES | YES (101 galaxies) | PARTIAL | YES |
| Universe Evolution | YES | YES | YES | YES (monitor) | YES | YES (active) | PARTIAL | YES (hardening items open) |
| AI planets | YES | YES | YES | NO (map only) | PARTIAL | YES (234 AI / 233 planets) | NO | YES |
| Messages / events | PARTIAL | YES (`player_messages`, 0 rows) | YES | YES (derived feed) | PARTIAL | YES (derived reports) | NO | PARTIAL |
| Auth / guest session | YES | YES (`register_guest_player`) | YES | YES (`identity.ts`) | YES | YES | YES | YES |
| Frontend navigation / views | YES | n/a | n/a | YES (9 views) | YES | YES | NO | PARTIAL (placeholder modules) |
| Scheduling / workers | YES | YES | YES (2 pg_cron jobs active) | n/a | n/a | YES | NO | YES |
| Evolution monitor | YES | YES (public + private RPC) | YES | YES | YES | YES | PARTIAL | YES |
| CI / build pipeline | YES (`.github/workflows`) | n/a | PARTIAL | n/a | n/a | UNKNOWN | NO | PARTIAL |
| Unit test framework | **NO** | n/a | n/a | n/a | n/a | n/a | NO | NO |
| Production deployment | YES (Cloudflare worker) | n/a | YES (monitor version 18/09) | YES | UNKNOWN | UNKNOWN | NO | PARTIAL |

## Core chains

```text
IDENTITY (complete in the frontend; server-side hardening pending)
  ensureSession/signInAnonymously (main.tsx → lib/identity.ts)
   → auth.getUser() → players.user_id → players.id
   → planets.eq(player_id) → activePlanet (own homeworld)
   → planet_resources of the active planet
  Own RPC: register_guest_player (SECURITY DEFINER, anonymous JWT required, idempotent)
  Server level: migration 20260918030000 (ownership) was APPLIED on 2026-09-18 — no guest bypass remains.

BUILDINGS (complete and verified)
  building_definitions → building_prerequisites (empty) → calculate_building_cost/time
  → can_start_building (authoritative contract) → start_building → building_queue
  → process_building_queue[_for_planet|_for_universe] → complete_building
  → planet_buildings (PK planet_id+building_id) → calculate_planet_production
  Frontend: Buildings view consumes the engine contract (cost/level/availability) + queue
  Time: started_at/finishes_at, settled by heartbeat/catch-up
  Test: buildings_lifecycle.sql (13/13 PASS, executed live, no residue)

RESEARCH (backend complete, UI partial)
  research_definitions/prerequisites → calculate_research_cost/time → can_research
  → start_research (player row lock) → research_queue → process_research_queue[_for_player|_for_universe]
  → complete_research → player_research
  Frontend: generic menu (level + BASE cost + BASE time); no can_research / authoritative cost
  Test: NONE

SHIPYARD / DEFENCE (backend complete, UI partial)
  definitions + prerequisites → calculate_*_cost/build_time → can_build_ship/defense
  → start_ship/start_defense → shipyard_queue/defense_queue (start after previous queue)
  → process_shipyard_queue/process_defense_queue → planet_ships/planet_defenses
  Frontend: generic menu (no authoritative cost/time). Test: NONE

FLEET (backend complete, UI partial)
  planet_ships → start_fleet (+ start_fleet_mixed / start_colonize_fleet)
  → fleet_movements (+ fleet_movement_ships) → process_fleet_movements / run_fleet_worker (pg_cron 1 s)
  → resolve_* (14 functions) → arrival/return, fuel, distance model (20000 / 2700+95 / 1000+5)
  Frontend: dispatch from the galaxy view + fleet list; no mission-resolution view. Test: NONE

COMBAT (backend complete, no UI)
  9 combat_* tables · process_combat_round_v2 · calculate_combat_damage/rapidfire/repairs
  → combat_battles (11) · debris_fields (3) → recycler (can_recycle_debris)
  Frontend: only reads battles for the message feed; no simulator and no battle report view.

UNIVERSE (complete and alive)
  universes (per-universe evolution parameters) → universe_clock (last_tick/next_tick/interval/is_processing)
  → universe_expansion_state (next_galaxy_roll_at, special_galaxy_*) → universe_population_state
  → universe_galaxies (101) → planets (system/position)
  Processes: process_universe_clock / process_universe_tick / process_universe_heartbeat (cron 1 min)
```

## Universe Evolution — live verification (2026-09-18 07:17 UTC)

```text
Persistent clock:  YES — universe_clock (active universe cf021ece): last_tick 07:17:00,
                   next_tick 07:18:00, tick_interval_seconds 60, is_processing false.
                   Universe "TEST - Universe 1" (86900cbc) is inactive with a frozen clock.
Scheduling:        YES — universe_clock.next_tick_at · universe_expansion_state.next_galaxy_roll_at
                   · universe_population_state.next_reconciliation_at
Advancer:          YES — pg_cron active: universe-heartbeat → process_universe_heartbeat() (60 s)
                   · deuteria-fleet-worker → run_fleet_worker() (1 s)
Catch-up:          YES — process_universe_clock + migration 20260916014916 (catch-up v2, batching cap 10 000)
Expansion:         YES — process_universe_system_expansion + process_universe_tick
                   (base 28800 s, exponent 0.75, 8 × G^0.75 h, initial_galaxies 100) → 101 galaxies / 214 systems
Special galaxies:  YES — process_universe_galaxy_roll (interval 43200 s, probability 0.01,
                   special base 3600 s, growth 1.05, initial systems 10) → 1 special galaxy live
AI population:     YES — reconcile_universe_ai_population (target 0.075, tolerance 0.0025, batch 100,
                   reconciliation every 300 s) → 233 AI planets / 3210 positions ≈ 7.26 %
Legacy/duplicate:  none for evolution itself. Residue: inactive TEST universe with frozen clock,
                   `process_planet_tick_local` (documented "do not use" shortcut), and the
                   migration-history caveat recorded in the monitor document.
```

## Mock / hardcoded data

```text
Frontend: no mock/dummy/fake/test data (0 hits). `Math.random` only as visitor-id fallback in identity.ts.
Legitimate fixtures: supabase/tests/buildings_lifecycle.sql.
Declared placeholder UI (not fake data, simply not implemented): TemplateChrome →
  showModuleNotice(): Wiki · Herramientas · Población · Comida · Materia oscura · Encuestas · Amigos ·
  Estadísticas/Destacados/Récords/Guerras/Simulador/Escáner (these navigate to existing views).
Hardcoded identity exception: RLS `players_select_access` and `planet_resources_select_access` embed the
  DevPlayer UUID (aa1deb2d-…) as a development exception.
Tables without a known consumer: player_messages (mailbox, 0 rows), dashboard_widgets, player_notes.
```

## RPC / functions (231 deployed · 220 in the 2026-09-16 dump)

| RPC | Origin | Responsibility | Called by | Connected | Deployed | Test |
|---|---|---|---|---|---|---|
| `register_guest_player` | migration 20260915210651 | guest sign-up (player+homeworld+resources+tester) | identity.ts | YES | YES | indirect |
| `can_start_building` | dump | cost/level/availability contract | App.tsx (Buildings) | YES | YES | YES |
| `start_building` | dump (ownership pending) | validate, charge, enqueue | App.tsx `action()` | YES | YES | YES |
| `complete_building` | dump | persist level (state/time/level guards) | process_building_queue* | internal | YES | YES |
| `process_building_queue[_for_planet/_for_universe]` | dump | complete due rows (SKIP LOCKED) | process_planet_tick / catch-up | internal | YES | YES |
| `sync_current_planet_resources` | migration 20260915050000 | settle resources + events | App.tsx | YES | YES | YES |
| `start_research` / `complete_research` / `process_research_queue*` | dump (+20260913094500) | research lifecycle | App.tsx / internal | YES | YES | NO |
| `start_ship` / `process_shipyard_queue` / `can_build_ship` | dump | shipyard | App.tsx / internal | YES | YES | NO |
| `start_defense` / `process_defense_queue` / `can_build_defense` | dump | defence | App.tsx / internal | YES | YES | NO |
| `start_fleet` / `start_fleet_mixed` / `start_colonize_fleet` | dump (+20260913100000, 051000) | fleet dispatch | GalaxyView / (mixed+colonize without UI) | YES / NO / NO | YES | NO |
| `process_fleet_movements` / `run_fleet_worker` | dump / 16-09 migrations | arrivals/returns/resolution | pg_cron (1 s) | n/a | YES | NO |
| `start_lifeform_building` / `start_lifeform_research` / `process_lifeform_tick` | dump | lifeforms | no frontend | NO | YES | NO |
| `process_universe_heartbeat` / `_clock` / `_tick` / `_galaxy_roll` / `_system_expansion` | dump + 20260916* | universe engine | pg_cron (1 min) | n/a | YES | PARTIAL |
| `reconcile_universe_ai_population` | dump | AI population | heartbeat | n/a | YES | PARTIAL |
| `get_universe_evolution_monitor_public` | migration 20260918020100 | public monitor | UniverseEvolutionMonitor.tsx | YES | YES | PARTIAL |
| `calculate_*` (66) · `get_*` (24) · `resolve_*` (14) · `ui_*` (6) · `project_*` (2) | dump | formulas / queries / UI views | mixed | PARTIAL | YES | NO |

## Duplicate systems

```text
Building cost/time: calculate_building_cost/time (authoritative) vs project_building_production /
  calculate_building_production_delta (divergent projection, no consumers)      → POSSIBLE DUPLICATE
Resources: update_planet_resources (LEGACY, marked in a COMMENT) vs update_planet_resources_until(_raw) /
  process_planet_tick vs process_planet_tick_local                              → POSSIBLE DUPLICATE (layers)
Building completion: complete_building + 3 process_building_queue* wrappers + catch-up completing
  events directly                                                               → POSSIBLE DUPLICATE (documented)
Fleet: start_fleet vs start_fleet_mixed vs start_colonize_fleet                 → POSSIBLE DUPLICATE
Clock/tick: process_universe_clock vs process_universe_tick vs process_universe_heartbeat → POSSIBLE DUPLICATE
Messages: player_messages (player↔player mailbox, no UI, 0 rows) vs the derived report feed in App.tsx
  (combat_battles / expedition_results / espionage_reports / fleet_movements)   → POSSIBLE DUPLICATE
Identity: NO duplicate — a single model (players.user_id) after removing the frontend heuristics.
```

## Functional gaps (classified by functional dependency, not by preference)

```text
CRITICAL (other parts depend on it)
- (CLOSED 2026-09-18) Ownership migration 20260918030000: applied to Supabase LIVE and verified — the six
  RPCs no longer accept a guest `p_player_id` without a matching `auth.uid()` (legitimate owner ALLOWED,
  foreign owner REJECTED, null uid REJECTED, no state mutation; buildings 13/13 PASS after the change).
  Kept here as the audit's historical finding, now resolved.
- Migration state vs live database: the monitor objects (20260918020000–020300) exist live while the CLI
  migration history did not list them (noted in the monitor document) → risk when replaying with the CLI.

HIGH (important system incomplete)
- Research / Shipyard / Defence without audit or tests: the backend exists but execution, persistence and
  concurrency have never been validated (only Buildings has been).
- Research/Shipyard/Defence UI shows BASE cost/time computed in the client (same defect class already
  fixed for Buildings with can_start_building).
- Construction certification still needs the user's browser functional test (project rule).
- `universes` has no SELECT grant for anon/authenticated, so the client cannot use the authoritative
  rate/production/time helpers (this is why the UI shows "TIEMPO BASE").

MEDIUM (partial / not integrated)
- Combat: full engine, no UI (no simulator, no battle report); only appears in the message feed.
- Fleet: no mission lifecycle view (arrival, loot, return) beyond the fleet list.
- Lifeforms: complete backend, zero UI integration (no view, no menu entry).
- Expeditions: functional but without a dedicated results/items view (mixed into the message feed).
- No test framework (`npm test` does not exist); lint fails with 3 pre-existing errors
  (App.tsx escapes ×2, main.tsx react-refresh).
- `player_messages` unused and without UI (PvP mail declared but not integrated).

LOW
- Placeholder chrome modules (Wiki, tools, population, food, dark matter, polls, friends).
- `calculate_building_production_delta` broken and `project_building_production` divergent (no consumers).
- Tables without known UI (dashboard_widgets, player_notes); inactive TEST universe with a frozen clock.
- Production deployment of the current HEAD: UNKNOWN (the docs record the monitor deployment of 18/09).
```

## Test coverage

| Test | What it checks | Last known state | Runnable now |
|---|---|---|---|
| `supabase/tests/buildings_lifecycle.sql` | 13 assertions: cost contract, resources, invalid building, start+deduction, queue, single active queue, processing, persistence, double completion (N→N+2), target-level guard, production after level-up, ownership | **13/13 PASS** (executed live, no residue) | YES (transactional; SQL editor or MCP `execute_sql`) |
| `scripts/verify-identity.mjs` | identity chain + data invariants (read-only) | PASS (13 PASS · 1 SKIP · 0 FAIL) | YES |
| `scripts/verify-buildings.mjs` | definitions, authoritative cost, `can_start_building` contract, queue/level invariants | PASS (7 PASS · 1 SKIP) | YES |
| `scripts/backup-supabase.ps1` | logical backup (schema/data/roles) | not executed in this phase | YES with supabase CLI + Docker |
| `npm run build` (tsc -b + vite build) | compilation | PASS | YES |
| `npm run lint` | eslint | FAIL (3 pre-existing errors) | YES |
| `npm test` | — | no script | NO |
| `.github/workflows` | CI defined in repo | UNKNOWN (no observed run) | UNKNOWN |

## OGameX reference map

The first-pass map already exists in [`../reference/OGAMEX_LGI_MAP.md`](../reference/OGAMEX_LGI_MAP.md)
with open targets A–E (fleet dispatch convergence OPEN/HIGH, mission lifecycle convergence OPEN/HIGH,
combat boundary OPEN/MEDIUM, background processing OPEN/MEDIUM, economy OPEN/MEDIUM). Correspondences
confirmed against the current code:

```text
Buildings       → OGame building queue            Research       → OGame research queue
Shipyard        → OGame shipyard (chains queues)  Defence        → OGame defense queue
Fleet missions  → OGame fleet movement            Combat         → OGame combat rounds
Expeditions     → OGame expeditions               Lifeforms      → OGame lifeforms (no UI yet)
Workers/jobs    → OGame task scheduling (pg_cron + process_* / run_fleet_worker)
Events          → compared as state transitions (queue rows + finishes_at)
Planets/Universe→ OGame planets & universe (universes / universe_galaxies / universe_clock)
```

## Next audit target

```text
Ownership hardening is DONE (2026-09-18). Next: the Research audit (same chain shape as Buildings, still
without audit or tests), then Shipyard and Defence.
Reason: those three share the exact chain already certified for Buildings, so the same audit method
(definitions → prerequisites → cost/time → queue → completion → state → tests) applies directly.
```

## Maintenance

Update this document when a domain audit changes its status, when a new domain appears, or when a
capability moves between EXISTS → DEPLOYED → CONNECTED → VERIFIED. Keep the operational summary in
[`../PROJECT_CONTEXT_PROMPT.md`](../PROJECT_CONTEXT_PROMPT.md) and the domain detail here.



