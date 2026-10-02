# PROJECT CONTEXT — LA GRAN IMPLOSIÓN

> **Purpose:** compact operational memory for safe session recovery.
>
> This document is the operational control panel, not an encyclopedia. Durable technical detail belongs in
> the specialized documents linked below.


## MANDATORY SYNC GATE

Before any new Cline/Copilot implementation mission, verify LOCAL ↔ \`origin/main\` first. The gate must record branch, local HEAD, remote HEAD, merge-base, ahead/behind, staged/unstaged/untracked/deleted files, stashes and relevant divergences. If local work is not understood or the trees diverge, stop implementation and protect the work first. Do not automatically pull, merge, rebase, reset, clean, checkout, stash-pop/drop, commit or push. For backend/migration/RPC/RLS work, also verify Supabase LIVE and consult the cloud reconciliation record: [\`docs/audits/CLOUD_STATE_RECONCILIATION_2026-09-28.md\`](audits/CLOUD_STATE_RECONCILIATION_2026-09-28.md).

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
                       docs/systems/README_MOON_ENGINE.md
  verified live        ACS settlement PG-08/09/10 was already implemented by the previous block; untouched here.

STILL OPEN (evidence recorded, ready to implement)
  fusion plant         formula recorded; blocked by the deuterium-fuel policy of the linear devengo (no free energy).
  crawler              rules recorded; same economy devengo as the fusion plant.
  AI behaviour         CLOSED — service-role actor contract + full gameplay policy (see the AI GAMEPLAY
                       BEHAVIOUR section at the end of this document).
  demolition           refund / ion-technology policy not determined with certainty → not invented.
  moon polishing       see docs/systems/README_MOON_ENGINE.md §9 (dedicated destruction mission, phalanx departures,
                       moon UI panel, defence kind gate, wreck field).

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
  fusion plant      OGameX id 12: 900/360/180 (factor 1.8), deuterium_synthesizer 5 + energy_technology 3,                    energy 30·L·(1.05+0.01·ET)^L and fuel burn 10·L·1.1^L expressed inside the authoritative
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
                    D1 dedicated destruction mission FUTURE · D5 wreck field PRODUCT DECISION

STILL OPEN / DECISIONS
  AI behaviour policy   which action an AI picks and when (priority list, cadence, budget, reserve, attack policy) —
                        the execution contract is done, the policy is product. README_AI_ENGINE.md §4.
  wreck field           new subsystem (Space Dock); product decision, not started.
  fusion research_lab   OGameX gates the fusion reactor behind a research laboratory; the laboratory now EXISTS
                        (20260926180000), so that gate is a data row. What remains open for fusion_plant is its
                        own energy/deuterium burn (see the fusion note below), not the laboratory.
  crawler overload      player-set 0–150 % overload does not exist in LGI (100 % assumed).
  moon polishing        D1 (dedicated destruction mission type + UI entry).

DOCUMENTS
  docs/systems/README_ECONOMY.md        fusion + crawler integration, fuel policy, kind authority
  docs/systems/README_AI_ENGINE.md      NEW — the actor contract, tests, behaviour-policy decision, OGameX comparison
  docs/systems/README_MOON_ENGINE.md    §9 D1…D5 classified, D4 closed
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
BLOCKED (environment)  browser certification of the fleet flow: no driver installed and no human credential. Still
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

## MISSILE SYSTEM CLOSURE — 2026-10-02

The Missile System is now **CLOSED — BACKEND / LIVE VERIFIED**. This entry supersedes older project-context statements that describe missiles as unimplemented, D1-blocked, or pending. Durable technical detail belongs in `docs/systems/README_MISSILE_SYSTEM.md`.

```text
STATUS
  Backend implementation       CLOSED
  D1                           CLOSED
  LIVE verification            CLOSED
  Fixtures                     CLOSED / VERIFIED
  Static verification         CLOSED
  Browser re-certification    NOT RUN in this run
  Migration ledger drift      DOCUMENTED / OPEN by design

D1 — CANONICAL LGI BUILD TIMES
  silo: 60 s / time_factor 2
  anti-ballistic missile: 60 s
  interplanetary missile: 60 s
  Values were contrasted directly against the LIVE catalog. Do not reopen without an explicit human product decision.

VERIFICATION
  missile_ui_surface.sql: 5/5 PASS
  missile_target_priority_regression.sql: 13/13 PASS
  missile_system.sql catalog+capacity: 31 PASS / 0 FAIL
  missile_system.sql range+flight+priority: 26 PASS / 0 FAIL
  missile_system.sql combat/idempotency/security/demolition: PASS / 0 FAIL
  LIVE residue after verification: 0
  tsc: PASS · build: PASS · contracts: PASS (74 RPC names) · git diff --check: PASS
  lint: 0 errors / 7 pre-existing warnings

FIXTURE LESSON
  Earlier apparent PASS claims were invalid because missile_target_priority_regression.sql contained an unterminated
  INSERT and unclosed loop. The fixture defects were corrected and the tests were then actually executed.
  Classification: DOCUMENTATION / TEST FIXTURE DEFECT — NOT a product defect.

LIVE / SCOPE CAVEATS
  Browser certification was not re-run because DEV credentials were unavailable; no browser result is simulated.
  Migration ledger drift remains documented; db push is forbidden as a repair mechanism.
  No new product code was introduced by the documentation-closure mission.
```

**Do not reopen** missile D1, launch, travel, arrival, destruction priority, report generation or ownership/security without new regression evidence or an explicit human decision.

## NEXT TECHNICAL SWEEP — 2026-10-02

With Missile System closed, the next implementation candidate is an **AUTONOMOUS ECONOMY GAP SWEEP**. This is discovery-first, not permission to invent economy rules.

```text
CYCLE
  SYNC GATE → inspect real code/docs → identify objective technical GAP → verify LIVE →
  implement only if behavior is already determined → test → certify → document → close.

DO NOT REPEAT
  espionage buildings/research gating: CLOSED
  P3 ACL cleanup: CLOSED
  AI beginner protection: CLOSED LIVE
  Missile System: CLOSED backend/LIVE verified

SEARCH SCOPE
  economy / remaining technical gaps
  backend contract ↔ frontend consumer mismatches
  documented mechanics implemented in backend but not connected to a real client path
  objective missing contracts, UI consumers, or runtime wiring

RULE
  If a finding depends on a new product decision, STOP and report the decision needed.
  Do not invent formulas, balance, UI behavior, or OGameX parity merely to fill a gap.
  OGameX remains reference-only, never authority.

KNOWN OPEN / NON-GAPS
  browser fleet certification: environment-blocked; no driver + human DEV credential, so do not simulate PASS
  AI activation: product decision; AI remains DORMANT until explicit activation
  moon polishing: documented decisions remain separate from technical gap discovery
  migration ledger drift: documented; do not repair with db push
```

The sweep must begin with the mandatory LOCAL ↔ `origin/main` SYNC GATE and must protect all existing local work. No automatic pull/merge/rebase/reset/clean/checkout/stash-pop/drop/commit/push.
