# PROJECT CONTEXT — LA GRAN IMPLOSIÓN

> **Purpose:** compact operational memory to continue development safely across sessions.
>
> This file is the project's **operational control panel**, not its encyclopedia. Durable technical
> knowledge lives in specialized READMEs and living monitors (see the index at the end).

---

## 1. What L.G.I. is

La Gran Implosión is an OGame-like browser game: **React 19 / TypeScript / Vite** on the frontend and
**Supabase/PostgreSQL** as the authoritative game backend, served through a **Cloudflare Worker**
(`worker/`). It may use genre concepts while keeping its own mechanics, architecture and
universe-evolution model; OGameX is a reference, never a dependency or an authority over L.G.I. rules.

```text
src/       presentation / client integration
worker/    Cloudflare HTTP + assets boundary
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
PROJECT_CONTEXT_PROMPT.md
        ↓
OGAMEX REFERENCE / PATTERN ANALYSIS
        ↓
OLD SESSION CONVERSATIONS / ASSUMPTIONS
```

Canonical: Supabase is the backend authority · GitHub is the code/history authority · the game is
`Player → active Planet → Universe` · a capability is not "done" because a function exists (execution,
persistence, transitions, idempotency, concurrency, integration, documentation and the user's browser
validation also matter) · durable detail is segregated, never deleted.

## 3. Canonical architecture

Layers are validated in this order:

```text
1. BASIC GAME ENGINE      construction / research / fleet / transport / attack / combat
2. TEMPORAL LAYER         persistent clock / workers / events / catch-up / downtime recovery
3. UNIVERSE EVOLUTION     evolving rates / expansion / special galaxies / AI population
```

Identity contract (single model since 2026-09-18):

```text
anonymous session (supabase.auth.signInAnonymously)
   ↓ auth.uid()
players.user_id → players.id
   ↓ planets.player_id
activePlanet (own homeworld) → planet_resources.planet_id
```

Global planet heuristics ("first guest / first homeworld / first planet") and any client-provided
`player_id` without an ownership check are **not allowed**. Detail:
[`systems/README_IDENTITY_AND_ACCESS.md`](systems/README_IDENTITY_AND_ACCESS.md).

## 4. CURRENT STATUS

Baseline: HEAD `ea677f0` = origin/main (`ea677f0`); the working tree also holds local
documentation/identity work that must not be lost.

### CLOSED

```text
Buildings lifecycle functional verification    13/13 PASS (transactional test, no residue)
Frontend identity chain                        anonymous session → players.user_id → planets.player_id
Guest identity registration                    register_guest_player (anonymous JWT) + onboarding
Initial functional audit                       2026-09-18, see systems/README_FUNCTIONAL_AUDIT.md
Universe Evolution base engine                 clock, catch-up, expansion, rolls, AI, heartbeat, monitor
Ownership hardening (CRITICAL #1)              migration 20260918030000 APPLIED to Supabase LIVE
                                               2026-09-18 and verified (pg_get_functiondef + functional
                                               ownership tests + buildings 13/13 regression)
```

### OPEN — CRITICAL

```text
(none)
```

### OPEN — HIGH

```text
Research audit: DONE + lifecycle test 24/24 PASS (systems/README_RESEARCH.md §12) — UI cost/time still pending
Research client contract: DEFECT confirmado y reproducible en LIVE (can_research/check_research_requirements
  SECURITY INVOKER sobre research_prerequisites con RLS restrictiva; sin bypass de gameplay; test instrumentado,
  decisión de arquitectura pendiente — systems/README_RESEARCH.md §1b/§12.1)
Fleet engine sweep: canonical pipeline CONVERGED (classes PEACEFUL/WAR/HOLDING, test 22/22 PASS); OPEN:
  ACS_HOLD/HOLDING/DEFEND not dispatchable (class + holding_fleet_speed prepared) — systems/README_FLEET_ENGINE.md §8/§10
Shipyard audit/tests
Defence audit/tests
Browser certification of Buildings (user-run functional test)
Migration history watch: inverse drift CLOSED — 39 local files · REAL_DIVERGENCE 0 · AMBIGUOUS 0 ·
  LOCAL - LIVE = EMPTY (16 files re-labelled to the LIVE version, 3 obsolete local artefacts preserved,
  2 payloads recovered verbatim). Remaining: 221 ledger rows with no local file (next mission) and 2
  out-of-band monitor ACLs that need a forward migration; still no `supabase db push` / `migration repair`
  from this copy (docs/MIGRATION_INVERSE_DRIFT_AUDIT.md · docs/MIGRATION_DRIFT_RECONCILIATION.md)
```

### OPEN — MEDIUM

```text
Combat UI
Fleet mission lifecycle UI
Lifeforms UI
Expedition result UI
player_messages integration
```

### OPEN — LOW

```text
placeholder modules (chrome notices)
legacy/projection cleanup   (calculate_building_production_delta is BROKEN with no consumers)
unused tables               (dashboard_widgets, player_notes, player_messages)
lint cleanup                (3 pre-existing errors)
```

## 5. Functional map (compact)

```text
Identity    CLOSED / verified (ownership hardening applied)   Planets    YES        Economy  PARTIAL
Buildings   VERIFIED (browser test pending)  Research   AUDITED / tests pending
Shipyard    PARTIAL / no tests               Defence    PARTIAL / no tests
Fleet       PARTIAL                          Combat     PARTIAL / backend without UI
Expeditions PARTIAL                          Lifeforms  PARTIAL / backend without UI
Universe    YES                              Evolution  YES / ACTIVE
AI planets  YES                              Messages   PARTIAL
Auth/Guest  YES                              Frontend   PARTIAL
Scheduling  YES (pg_cron active)
```

Full table (exists · backend · deployed · frontend · connected · real data · tests · status), core
chains per domain, RPC inventory, duplicates and gaps:
[`systems/README_FUNCTIONAL_AUDIT.md`](systems/README_FUNCTIONAL_AUDIT.md).
Economy layers (authoritative / projection / legacy) and the broken helper:
[`systems/README_ECONOMY.md`](systems/README_ECONOMY.md).

## 6. Universe Evolution — exists, deployed, connected and active

Do **not** redesign it. Live (2026-09-18): `universe_clock` ticking every 60 s, `universe_expansion_state`
and `universe_population_state` present, `pg_cron` running `universe-heartbeat` (60 s) and
`deuteria-fleet-worker` (1 s), catch-up v2, normal expansion `8 × G^0.75` hours for G1–G100, special
galaxy roll every 12 h at 1 % (10 initial systems, separate growth), AI population reconciliation to a
≈7.5 % target with tolerance, persistent timestamps and downtime catch-up. Observed live: 101 galaxies,
233 AI planets ≈ 7.26 %.

Rules: [`systems/README_UNIVERSE_EVOLUTION.md`](systems/README_UNIVERSE_EVOLUTION.md) ·
monitor: [`systems/README_UNIVERSE_EVOLUTION_MONITOR.md`](systems/README_UNIVERSE_EVOLUTION_MONITOR.md).

## 7. Protected areas

**CSS / wallpaper / visual foundation are protected areas.** Gameplay work must not alter the
established CSS or background authority. Detail stays where it is documented; create a dedicated UI/CSS
README only when a frontend audit justifies it.

## 8. OGameX

OGameX = **architectural reference, NOT a dependency.**

```text
study → understand → compare → adapt → validate
```

The first-pass OGameX → L.G.I. map is established; deep comparison happens only where it can expose a
concrete architectural gap.
[`reference/README_OGAMEX.md`](reference/README_OGAMEX.md) · [`reference/OGAMEX_LGI_MAP.md`](reference/OGAMEX_LGI_MAP.md)

## 9. Documentation & memory system

```text
Persistent ChatGPT memory          cross-session principles and preferences
        ↕
PROJECT_CONTEXT_PROMPT.md          operational memory / index (this file)
        ↕
Specialized READMEs / monitors     durable technical detail
        ↕
Real repository + Supabase state   actual implementation and live state
```

When a document grows too large: **segregate before deleting** — move durable detail to the right
README, leave a concise summary/link here, keep traceability. Rules:
[`README_MEMORY_SYSTEM.md`](README_MEMORY_SYSTEM.md).

## 10. Working rules (compact)

```text
Choose the appropriate agent/tool for the task (ChatGPT · Cline+DeepSeek · Copilot · Qwen/LM Studio)
  and state Intelligence + expected cost for Cline/DeepSeek missions.
Do not blindly trust generated changes.
Verify against real Git and Supabase state before believing any claim.
Check whether the functionality already exists before creating anything new.
Keep prompts bounded; do not repeat repository-wide discovery once the map exists.
After meaningful work: update the specialized README (durable detail) and this file (operational state).
```

Core loop: `Context → audit → plan → implement → test → verify → document → update context`
Full protocol, agent responsibilities and cost discipline:
[`tools/README_DEVELOPMENT_WORKFLOW.md`](tools/README_DEVELOPMENT_WORKFLOW.md).

## 11. NEXT ENGINEERING STEP

```text
1. Ownership hardening: DONE — migration 20260918030000 applied to Supabase LIVE and verified on
   2026-09-18 (no guest bypass in the six RPCs; legitimate owner ALLOWED, foreign owner REJECTED,
   auth.uid() NULL REJECTED; buildings lifecycle 13/13 PASS; identity regression PASS; history recorded).
2. Next: begin the Research audit (same chain shape as Buildings, still without audit or tests).
3. Then: Shipyard, Defence, Fleet/Combat mission lifecycle, Lifeforms UI.
```

Universe Evolution is **not** the next implementation target: it already exists, is deployed and is
active. The transversal security block (ownership hardening) is now closed.

## 12. Specialized documentation index

| Area | Document |
|---|---|
| Memory/documentation system | [`README_MEMORY_SYSTEM.md`](README_MEMORY_SYSTEM.md) |
| Architecture | [`architecture/README_ARCHITECTURE.md`](architecture/README_ARCHITECTURE.md) |
| Functional audit (map, gaps, tests) | [`systems/README_FUNCTIONAL_AUDIT.md`](systems/README_FUNCTIONAL_AUDIT.md) |
| Identity & access | [`systems/README_IDENTITY_AND_ACCESS.md`](systems/README_IDENTITY_AND_ACCESS.md) |
| Economy | [`systems/README_ECONOMY.md`](systems/README_ECONOMY.md) |
| Game engine audit (construction) | [`systems/README_GAME_ENGINE_AUDIT.md`](systems/README_GAME_ENGINE_AUDIT.md) |
| Research (audit vs Buildings) | [`systems/README_RESEARCH.md`](systems/README_RESEARCH.md) |
| Fleet engine (classes, modifiers, fuel) | [`systems/README_FLEET_ENGINE.md`](systems/README_FLEET_ENGINE.md) |
| Universe evolution | [`systems/README_UNIVERSE_EVOLUTION.md`](systems/README_UNIVERSE_EVOLUTION.md) |
| Universe evolution monitor | [`systems/README_UNIVERSE_EVOLUTION_MONITOR.md`](systems/README_UNIVERSE_EVOLUTION_MONITOR.md) |
| Rate/fleet engine monitor | [`UNIVERSE_RATE_AND_FLEET_ENGINE_MONITOR.md`](UNIVERSE_RATE_AND_FLEET_ENGINE_MONITOR.md) |
| OGameX reference + map | [`reference/README_OGAMEX.md`](reference/README_OGAMEX.md) · [`reference/OGAMEX_LGI_MAP.md`](reference/OGAMEX_LGI_MAP.md) |
| Development workflow | [`tools/README_DEVELOPMENT_WORKFLOW.md`](tools/README_DEVELOPMENT_WORKFLOW.md) |
| Production DB baseline | [`PRODUCTION_DB_BASELINE.md`](PRODUCTION_DB_BASELINE.md) |
| Supabase engine manifest | [`../supabase/ENGINE_MANIFEST.md`](../supabase/ENGINE_MANIFEST.md) |

---

## Golden rule

> **Do not guess when the project can be inspected.**
>
> **Do not duplicate durable knowledge when it can be referenced.**
>
> **Do not delete useful history merely to make the context smaller.**
>
> Inspect → compare → decide → implement → test → document → preserve continuity.
