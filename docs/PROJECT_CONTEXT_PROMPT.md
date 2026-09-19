# PROJECT CONTEXT — LA GRAN IMPLOSIÓN

> **Purpose:** compact operational memory to continue development safely across sessions.
>
> This file is the project's **operational control panel**, not its encyclopedia. Durable technical
> knowledge lives in specialized READMEs and living monitors (see the index at the end).
> Consolidated from the local operational work and `origin/main` during the 2026-09-18 integration merge.

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

## 4. Tool-selection gate (mandatory)

Before **every** task that will implement, review, audit or modify project material, ChatGPT must first make
an explicit tool/agent selection.

- **ChatGPT:** architecture, system-level interpretation, audit design, cross-system decisions and final verification.
- **Cline + DeepSeek:** complex or multi-file implementation, difficult debugging, deep bounded audits and
  operations requiring repository execution; heavy-duty reasoning vessel, still cost-conscious.
- **Copilot:** small/localized implementation, UI components, CSS, TypeScript changes, mechanical fixes.
- **Qwen / LM Studio:** local experiments, prototypes and tasks where API cost matters.

For Cline/DeepSeek missions always state: **🧠 Intelligence** (None/Low/Medium/High/Extra) · **💰 Cost
expected** (LOW/MEDIUM/HIGH) · **🎯 Why** (one sentence).

The selected tool is not automatically the one that performs the whole task: ChatGPT remains responsible for
choosing the mission, defining boundaries and verifying the result. No tool is the project's independent
brain: agents execute approved work; they do not redefine canonical gameplay or architecture without an
explicit project decision. Detailed workflow:
[`tools/README_DEVELOPMENT_WORKFLOW.md`](tools/README_DEVELOPMENT_WORKFLOW.md).

## 5. OGameX reference layer

OGameX is a permanent architectural/gameplay-pattern reference, not a dependency:

```text
study → understand → compare → adapt → validate
```

The first-pass OGameX → L.G.I. subsystem map is established; deep audits use it only where comparison can
expose a concrete architectural gap. Never copy Laravel/PHP/ORM/routing.
Method and map: [`reference/README_OGAMEX.md`](reference/README_OGAMEX.md) →
[`reference/OGAMEX_LGI_MAP.md`](reference/OGAMEX_LGI_MAP.md).

## 6. Current gameplay / universe decisions

### Universe evolution

- Persistent internal clock; must progress conceptually while the site/server is offline.
- Resume processing detects elapsed time and catches up missed events.
- Normal galaxy system-expansion timing: `8 × G^0.75` hours per new system.
- Every 12 real hours: one global 1% roll for a special galaxy after G100.
- Special galaxies start with 10 systems and use a separate expansion formula.
- AI population targets roughly 5–10% of available universe slots, with tolerance and reconciliation as space
  expands.
- Production verification confirmed active pg_cron jobs `universe-heartbeat` (1 minute) and
  `deuteria-fleet-worker` (1 second); the repository/dump alone does not expose those cron rows.

### Protected UI area

Wallpaper/background behaviour is a protected area. Gameplay work must not casually alter established
CSS/background authority. Create a dedicated UI/CSS README when a frontend audit makes that worthwhile.

## 7. Current status

### CLOSED

```text
Buildings lifecycle functional verification   13/13 PASS (transactional, no residue); the UI consumes the
                                              authoritative can_start_building() contract; user browser test pending
Frontend identity chain                       anonymous session → players.user_id → planets.player_id
Guest identity registration                   register_guest_player (anonymous JWT) + onboarding
Initial functional audit                      2026-09-18 → systems/README_FUNCTIONAL_AUDIT.md
Research domain                               authoritative can_start_research() contract (server-computed cost,
                                              time, prerequisites, queue and reason_code), ownership/security
                                              gates, legacy helper APIs closed, regression battery
                                              (supabase/tests/research_lifecycle.sql) and browser level-up /
                                              resource-deduction flow validated
Ownership hardening (CRITICAL #1)             migration 20260918030000 APPLIED to LIVE and verified; six owned
                                              RPCs hardened (start_building, start_research, start_ship,
                                              start_defense, start_fleet, sync_current_planet_resources) →
                                              systems/README_OWNERSHIP_HARDENING.md
Fleet movement lifecycle hardening            persisted event timing, downtime/catch-up, concurrent worker
                                              serialization, duplicate-run protection, private worker APIs
Fleet propulsion / mission-speed / fuel       CLOSED functionally: Hyperspace fuel reduction removed (lifeform
                                              fuel_reduction_percent is the source); fleet_speed split into
                                              peaceful/war/holding and dispatchers select class → E^(1/3) →
                                              item/lifeform modifiers; supabase/tests/fleet_speed_classes.sql
                                              22/22 PASS; legacy calculation RPC cluster retired 2026-09-19
Universe Evolution engine + monitor           clock, catch-up, normal/special expansion, galaxy rolls, AI
                                              reconciliation, heartbeat, read-only monitor and Cloudflare
                                              production deployment (Worker lagranimplosion) validated
Migration-history recovery                     CLOSED: LIVE/local migration parity reconciled at 262/262; 4 historical
                                              non-LIVE origin files are retained only as .superseded provenance artifacts;
                                              no migration blocker remains
```

### OPEN — CRITICAL

```text
(none)
```

### OPEN — HIGH

```text
Basic game engine audit order (systems/README_GAME_ENGINE_AUDIT.md)
  1 construction  backend + integration validated · pending the user's browser test
  2 research      CLOSED (contract + browser flow validated)
  3 fleet         backend lifecycle/propulsion/fuel/mission classes converged · browser certification OPEN
  4 transport     audit pending
  5 attack        audit pending
  6 combat        audit pending
Shipyard audit/tests
Defence audit/tests
Research UI cost/time: the research view must consume the authoritative contract (can_start_research) instead
  of base cost/time columns; pending frontend switch
Migration-history final reconciliation: all 260 LIVE ledger rows are recovered locally; remaining blocker is
  the 4 non-LIVE drift files plus 2 out-of-band monitor ACL changes. No `supabase db push`, `migration repair`,
  reset, pull or dump until the final reconciliation decision is closed
Browser certification of Buildings (user-run functional test)
```

### OPEN — MEDIUM

```text
Economy semantics audit (resource balances, production/consumption semantics, modifier ordering)
Combat UI
Fleet mission lifecycle UI
Lifeforms UI
Expedition result UI
player_messages integration
```

### OPEN — LOW

```text
Final security/RLS hardening phase (deferred unless a concrete defect requires earlier intervention)
Bounded fleet hygiene: calculate_universe_rates canonical meaning decision + unused lifeform-key decision
Placeholder chrome modules (Wiki, tools, population, food, dark matter, polls, friends)
```

## 8. Established / CLOSED decisions

- Supabase is the backend authority; GitHub/repository state is the code/history authority.
- The project follows `Context → Audit → Plan → Implement → Test → Verify → Document`.
- OGameX is a reference layer, not a dependency; never copy Laravel/PHP/ORM/routing.
- `Player → active planet → universe` is the canonical frontend/domain contract; global planet heuristics and
  any client-provided `player_id` without an ownership check are forbidden.
- Universe evolution is separate from galaxy/system expansion; `calculate_universe_scaling(E)` contains only
  the E → category transformation (no technology, planet, lifeform, item, event, alliance or mission
  modifiers).
- Durable detail is segregated into specialized documentation; moving detail out of this file is not deletion,
  and history stays traceable.
- The first-pass OGameX → L.G.I. structural map is established; subsystem-specific audits remain open.
- Universe Evolution engine validation, monitor validation and production deployment validation are CLOSED for
  the currently implemented clock/catch-up/expansion/roll/AI/heartbeat surface.
- The public monitor backend is versioned by migrations `20260918020000` … `20260918020300`; the public RPC is
  intentionally callable by `anon` and `authenticated`, while the full monitor stays private.
- Basic-engine certification includes a user-performed web functional test; backend existence alone is
  insufficient.
- Research is functionally closed: authoritative `can_start_research()` contract, security/ownership checks,
  regression battery and browser level-up/resource-deduction flow validated.
- Ownership hardening is closed for the six critical player/planet action RPCs; the final security/RLS phase
  remains separate.
- Fleet engine backend audit is closed for the implemented seven missions: propulsion, cargo/fuel, mission-speed
  classes, modifiers, dispatch/return timing and duplicate-run behaviour are verified. Remaining fleet work is
  browser certification, future ACS/HOLDING/DEFEND design, and bounded hygiene only. The dead legacy calculation
  RPC cluster was retired 2026-09-19.
- The first DeepSeek/Cline recognition audit is an initial map, not a template for future broad scans: later
  prompts must be bounded and cost-aware.
- Migration history: LIVE `supabase_migrations.schema_migrations` remains the certified ledger; local active migrations
  are aligned with LIVE at 262/262. Four historical origin files are preserved as `.superseded` provenance artifacts;
  no migration repair/reset/replay was used.

Detailed architectural history: [`architecture/README_ARCHITECTURE.md`](architecture/README_ARCHITECTURE.md)

## 9. Documentation & memory system

Three-layer continuity model:

```text
PROJECT_CONTEXT_PROMPT.md      compact operational memory, status and roadmap (this file)
        ↓
specialized READMEs            durable detail per system/domain
        ↓
living monitors / reports      observability, audits and validated evidence
```

Rules: keep this file compact; segregate durable detail before deleting anything; after meaningful work update
the specialized README (durable knowledge) and this file (operational state); always preserve traceability for
superseded decisions. Details: [`README_MEMORY_SYSTEM.md`](README_MEMORY_SYSTEM.md).

## 10. Session recovery

At the beginning of a substantial session:

1. Recover persistent memory/context.
2. Read this file.
3. Follow only the specialized README/monitor links relevant to the task.
4. Inspect current Git/repository state.
5. Inspect Supabase when backend state matters.
6. Reconcile documentation with reality before modifying anything.

At the end of meaningful work:

1. Update the relevant specialized README/monitor if durable knowledge changed.
2. Update this file if operational state or OPEN/CLOSED decisions changed.
3. Preserve traceability for superseded decisions.
4. Leave the repository testable and recoverable.

## 11. Specialized documentation index

| Area | Document | Role |
|---|---|---|
| Memory/documentation | [`README_MEMORY_SYSTEM.md`](README_MEMORY_SYSTEM.md) | Rules for memory and documentation segregation |
| Architecture | [`architecture/README_ARCHITECTURE.md`](architecture/README_ARCHITECTURE.md) | Durable architecture and design decisions |
| Functional audit | [`systems/README_FUNCTIONAL_AUDIT.md`](systems/README_FUNCTIONAL_AUDIT.md) | exists/deployed/connected/verified map, gaps and tests |
| Identity & access | [`systems/README_IDENTITY_AND_ACCESS.md`](systems/README_IDENTITY_AND_ACCESS.md) | Identity chain, RLS model and ownership hardening |
| Ownership hardening | [`systems/README_OWNERSHIP_HARDENING.md`](systems/README_OWNERSHIP_HARDENING.md) | Owned RPC authorization and hardening evidence |
| Economy | [`systems/README_ECONOMY.md`](systems/README_ECONOMY.md) | Resources, production, costs, settlement semantics |
| Game engine audit | [`systems/README_GAME_ENGINE_AUDIT.md`](systems/README_GAME_ENGINE_AUDIT.md) | Construction/research/fleet audit, guarantees, next validations |
| Research | [`systems/README_RESEARCH.md`](systems/README_RESEARCH.md) | Research audit vs Buildings + client availability contract |
| Fleet engine | [`systems/README_FLEET_ENGINE.md`](systems/README_FLEET_ENGINE.md) | Prerequisites, propulsion, mission classes, fuel, lifecycle |\n| Combat engine | [`systems/README_COMBAT_ENGINE.md`](systems/README_COMBAT_ENGINE.md) | LIVE combat V2 pipeline, participant model and ACS prerequisite |
| Universe evolution | [`systems/README_UNIVERSE_EVOLUTION.md`](systems/README_UNIVERSE_EVOLUTION.md) | Evolution formulas, clock, catch-up, expansion and AI |
| Universe evolution monitor | [`systems/README_UNIVERSE_EVOLUTION_MONITOR.md`](systems/README_UNIVERSE_EVOLUTION_MONITOR.md) | Read-only observability, public RPC contract and deployment evidence |
| Rate/fleet monitor | [`UNIVERSE_RATE_AND_FLEET_ENGINE_MONITOR.md`](UNIVERSE_RATE_AND_FLEET_ENGINE_MONITOR.md) | Canonical scaling, travel-time and fleet integration audit |
| Migration drift (forward) | [`MIGRATION_DRIFT_RECONCILIATION.md`](MIGRATION_DRIFT_RECONCILIATION.md) | Verbatim recovery, verification and push rules |
| Migration drift (inverse) | [`MIGRATION_INVERSE_DRIFT_AUDIT.md`](MIGRATION_INVERSE_DRIFT_AUDIT.md) | Inverse audit, blocker resolution, push-safety state |
| OGameX reference + map | [`reference/README_OGAMEX.md`](reference/README_OGAMEX.md) · [`reference/OGAMEX_LGI_MAP.md`](reference/OGAMEX_LGI_MAP.md) | Method + concrete OGameX → L.G.I. comparison |
| Development workflow | [`tools/README_DEVELOPMENT_WORKFLOW.md`](tools/README_DEVELOPMENT_WORKFLOW.md) | Tool/agent responsibilities and workflow |
| Production DB baseline | [`PRODUCTION_DB_BASELINE.md`](PRODUCTION_DB_BASELINE.md) | Production database/source-of-truth baseline |
| Supabase engine manifest | [`../supabase/ENGINE_MANIFEST.md`](../supabase/ENGINE_MANIFEST.md) | Backend engine/runtime boundary and scheduler status |

Create another specialized README only when a domain contains enough durable knowledge to justify independent
maintenance.

## 12. Next engineering step

```text
0. ACS/HOLDING/DEFEND: combat architecture prerequisite is now audited; implement the minimum participant-aware combat model before player-facing ACS dispatch.
1. Fleet browser certification: verify the already-converged seven implemented mission paths through the user's web client.
2. Shipyard audit/tests.
3. Defence audit/tests.
4. Research UI contract integration: switch the research view to the authoritative can_start_research() contract.
5. Continue basic-engine order: Transport → Attack → Combat.
6. Keep fleet legacy cleanup CLOSED; only revisit bounded hygiene (calculate_universe_rates, unused lifeform keys) when the surrounding engine audit reaches it.
7. Later: fleet mission lifecycle UI, Combat UI, Lifeforms UI, expedition result UI and player_messages.
```

The transversal security block (ownership hardening) is closed; Universe Evolution is implemented, deployed and
active, and is **not** the next implementation target.


## 12.1 Operational correction — 2026-09-19

The latest read-only audits supersede stale assumptions:

- **Fleet mission audit:** seven implemented mission paths are functionally converged in LIVE; no live double modifier, fuel-order defect or legacy bypass was found. ACS/HOLDING/DEFEND remains definition-only. Detailed evidence: systems/README_FLEET_ENGINE.md.
- **Fleet legacy cleanup:** CLOSED. The dead legacy fleet calculation RPC cluster was retired in LIVE migration `20260919042419_retire_legacy_fleet_calculation_rpc_cluster`. Do not restart a generic Fleet Speed audit.
- **Migration reconciliation:** CLOSED. LIVE ledger and local active migrations are aligned at 262/262; four historical non-LIVE files are preserved as `.superseded` provenance artifacts. Do not use migration repair/reset/replay as a recovery mechanism.
- **Universe Evolution:** runtime engine is already active in LIVE. Do not design a second clock, scheduler, worker or catch-up mechanism.
- **Canonical fleet open work:** browser certification, future ACS/HOLDING/DEFEND design, and bounded hygiene only.

## 12.3 Holding audit correction + ACS design findings — 2026-09-19

- The first HOLDING lifecycle migration preserved the mission-specific worker branches but omitted two pre-existing worker hardening details: outbound/returning partial indexes and the private EXECUTE ACL. This was corrected forward-only in 20260919060000_restore_fleet_worker_hardening; LIVE verification confirms both indexes/ACL and the HOLDING branches.
- OGameX ACS Defend reference: ACS Defend is a distinct mission with physical arrival separated from the hold window, buddy/alliance eligibility, and multi-defender combat with per-fleet owner/mission attribution. Source reference: OGameX AcsDefendMission, FleetMissionService, DefenderFleet, and FleetDispatchAcsDefendTest.
- L.G.I. has no LIVE alliance/buddy tables, so the OGameX eligibility rule must not be copied blindly. Support eligibility is a game-design OPEN decision.
- Before start_acs_hold / start_defend, preserve the current canonical speed/fuel pipeline and require the existing authenticated ownership pattern. Do not route ACS through the legacy start_fleet_mixed security/authority gap.
- LIVE combat audit: `combat_battles` currently models one attacking fleet against one target planet, and `resolve_combat()` snapshots only stationary ships/defenses on that planet. ACS cannot be safely integrated by patching `resolve_attack_arrival()` around this model; a durable multi-defender participant/ownership model is required first so each support fleet can be resolved and returned to its own origin.

## 12.2 ACS / HOLDING / DEFEND lifecycle implementation — 2026-09-19

The HOLDING persistence/lifecycle contract is now implemented in LIVE; this supersedes the older “definition-only/no persistence” wording, while gameplay remains intentionally open:

- Migration `20260919053220_add_fleet_holding_lifecycle` adds `fleet_movements.holding_until`, admits `ACS_HOLD` / `HOLDING` / `DEFEND` mission types, admits durable `HOLDING` status, and requires `holding_until` for those mission types.
- `process_fleet_movements()` now transitions due support movements `OUTBOUND → HOLDING`, then due `holding_until` `HOLDING → RETURNING`, reusing the persisted outbound duration for the return leg.
- No ACS/DEFEND player-facing dispatch RPC, support-combat integration, target semantics or UI has been implemented yet.
- No separate ACS support table was introduced; the current design reuses `fleet_movements` + `fleet_movement_ships`.
- Before building dispatch, verify the live worker against the pre-change/canonical worker body to ensure the lifecycle migration preserved all existing mission-specific arrival/return branches. Any discrepancy must be corrected with a new migration, not by editing migration history.
- Next bounded task: audit the existing fleet dispatch/ownership contracts and OGameX ACS defend pattern, then define the minimal `start_acs_hold` / `start_defend` contract before implementing any player-facing RPC.

---

## 13. Golden rule

> **Do not guess when the project can be inspected.**
>
> **Do not duplicate durable knowledge when it can be referenced.**
>
> **Do not delete useful history merely to make the context smaller.**
>
> Inspect → compare → decide → implement → test → document → preserve continuity.


## 12.4 Combat architecture audit — 2026-09-19

- LIVE combat V2 is confirmed as the active path: `combat_battles → combat_individual_units → snapshots → shots/RF → combat_round_damage → target resolution → apply damage → combat_rounds → next round → finalization → resolve_attack_arrival settlement`.
- `combat_battles` is structurally single-attacker/single-target-planet. `resolve_combat()` initializes the attack fleet plus stationary planet ships/defences.
- `combat_individual_units` has no durable fleet/owner participant identity. Its uniqueness model would collide when two support fleets contain the same ship type/unit number.
- `resolve_attack_arrival()` settles one attacker fleet plus one stationary planet and cannot safely return multiple ACS fleets by inference.
- Minimum ACS prerequisite is an explicit `combat_battle_participants` layer plus `participant_id` propagation through individual units, snapshots, shots and damage. Preserve aggregate ATTACKER/DEFENDER round semantics, but retain participant-level survivor identity for settlement.
- Participant settlement must return each surviving support fleet to its own `fleet_id` / `origin_planet_id`; loot remains attacker-only, defence repair remains planet-only, debris remains battle-scoped.
- No combat schema/function changes were made in this audit. Durable detail: `systems/README_COMBAT_ENGINE.md`.
- Next implementation boundary: participant migration + regression fixtures; only after that `start_acs_hold` / `start_defend`.
- Participant schema migration is now LIVE and documented as 20260919070000_add_combat_battle_participants. It adds combat_battle_participants plus nullable participant foreign keys through units/snapshots/shots/damage, but deliberately leaves existing combat writers and uniqueness constraints unchanged. LIVE participant row count is 0; no historical combat rows were rewritten.
- Next precise implementation boundary: backfill/create participants for the current single-attacker path, propagate participant_id through combat writers, then replace uniqueness constraints with participant-aware keys. Only after regression verification should ACS multi-defender dispatch be enabled.

