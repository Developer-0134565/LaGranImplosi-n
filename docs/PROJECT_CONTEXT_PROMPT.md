# PROJECT CONTEXT — LA GRAN IMPLOSIÓN

> **Purpose:** compact operational memory for safe session recovery.
>
> This document is the operational control panel, not an encyclopedia. Durable technical detail belongs in
> the specialized documents linked below.

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
NOT EXECUTED            browser certification: no driver installed (playwright/puppeteer/cypress are absent from
                        `package.json` and `node_modules`) and no human credential available (`.env.local` holds only
                        `VITE_SUPABASE_URL` + `VITE_SUPABASE_PUBLISHABLE_KEY`, no test account). Route when the
                        prerequisite exists: install a driver, provide a DEV human account, and cover
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
  astrophysics        Audited 2026-09-23: 0 code readers and NOTHING depends on it (not a prerequisite of any
                      research/ship/defense/building), 0 player_research rows → it is inert, not even an
                      unlock. Its reference rule (OGame snapshot: +1 colony slot per 2 levels) cannot be
                      applied: LGI has no colony-cap subsystem at all (no column, no count/limit check —
                      colonisation only validates coordinates, target occupancy and the colony ship) and
                      expedition slots are item-driven, not research-driven. Implementing it would mean
                      introducing new colonisation rules → PRODUCT DECISION, not a defect. Do not implement.
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
- `PG-09` loot-capacity source → **`UNRESOLVED PRODUCT DECISION`** (§22.6). Surviving vs original
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
- **Audit result — remaining `is_guest` residue is dead, not live (measured 2026-09-21).** All five
  remaining policies with an `is_guest` OR-branch (`building_queue_select_access`,
  `planet_resources_select_access`, `player_research_select_access`, `research_queue_select_access` and
  `defense_queue_owner_read`) match **0 rows**, because `players.is_guest = true` has 0 rows and no writer
  can produce one. In the first four the `pl.user_id = auth.uid()` half is the branch that actually
  authorises, and it is required by `src/App.tsx`. `defense_queue_owner_read` is different in kind: it is
  **guest-only with no ownership branch**, so the owner cannot read its own defence queue — the same defect
  class as the P0, currently unobservable because `defense_queue` has 0 rows. It is the next demonstrated
  fix, deliberately not applied in this pass.
- Anonymous sign-in was still **ENABLED** in the Auth configuration on 2026-09-21
  (`GET /auth/v1/settings` → `external.anonymous_users = true`), with 13 anonymous users then; all 13 are
  now deleted. Disabling it is still a pending Auth-configuration decision.
- LIVE integrity reconciliation (2026-09-20): executed read-only and recorded in
  [`docs/audits/LIVE_INTEGRITY_RECONCILIATION_2026-09-20.md`](audits/LIVE_INTEGRITY_RECONCILIATION_2026-09-20.md).
  Its findings were **superseded by the 2026-09-21 application**: `on_auth_user_created` is now dropped
  (it had claimed 13 AI empires, all since released), `register_guest_player` is dropped, and the
  remaining `is_guest` surface is the RLS/branch residue listed above.
- **Block 1 security fixes CLOSED in LIVE (2026-09-21):** `ui_defense_queue` ownership/auth hardening,
  analysis-function ACL hardening (including `generate_building_sequences` external execution removal), and RLS
  enablement on `universe_process_health` / `combat_battle_participants` were applied and verified. The three local
  migration files were renamed to their server-assigned ledger versions `20260921044623`, `20260921044643` and
  `20260921044659`, preserving their hashes. No commit/push was performed as part of the audit execution.
- Block 1 follow-up: the numeric `p_depth` guard for `generate_building_sequences` was **not** invented; the external
  abuse vector is closed by ACL. A privileged/future re-grant could still pass a large depth and remains a separate
  bounded hardening decision.
- Security findings **APPLIED** (re-versioned, 2026-09-21): `20260921044623` (was `20260920120500` —
  public cross-player `ui_defense_queue` read), `20260921044643` (was `20260920120600` — unauthenticated
  unbounded `generate_building_sequences`), `20260921044659` (was `20260920120700` — RLS disabled on
  `universe_process_health` / `combat_battle_participants`). Still **NOT** applied: `20260920120800`
  (guest ownership bypasses; replaces the unexecutable `20260920120300`, now `.superseded`).
- Browser certification of the seven implemented fleet missions.
- Shipyard/defence and buildings browser certification where still pending.
- Bounded hygiene decisions for `calculate_universe_rates` and unused Lifeform keys.
- Fleet lifecycle UI, Combat UI, Lifeforms UI, expedition result UI and `player_messages`.
- **Research hygiene (P3 — deferred, do NOT start without an explicit mission):** three orphan
  processors (`process_research_queue`, `process_research_queue_for_player`, `process_research_queue_for_universe`
  — 0 callers), two dead helpers (`check_research_requirements`, `get_research_requirements`),
  `ui_research_definitions()` is a redundant SECURITY DEFINER wrapper whose
  `search_path` omits `pg_temp`, `research_action_candidates` keeps ALL-privilege grants for
  `service_role`, and old `COMPLETED` queue rows are never purged. (**Research cancellation is no longer part
  of this list**: `cancel_research` exists since 2026-09-26 — `20260926082120` + `20260926082529`, certified
  by `supabase/tests/queue_cancellation.sql`.) (The dead `QUEUED`/`ACTIVE` research status guards were removed
  by `20260921152702`; the CHECK still allows only `RESEARCHING`/`COMPLETED`/`CANCELLED`. Re-verified
  2026-09-27: `start_research` **no longer** grants EXECUTE to `anon` — the P3 ACL sweep closed it and LIVE
  shows authenticated/service_role only.)
- **Defense hygiene (P3 — deferred):** `start_defense` still grants EXECUTE to `anon` (the body rejects it);
  `calculate_defense_build_time` and `check_defense_requirements` are PUBLIC-executable and fail for clients;
  `CANCELLED` is admitted by the CHECK but unreachable — and that is now **by design**: OGameX states that unit
  queue objects cannot be cancelled (the building and research queues did get cancellation on 2026-09-26);
  `COMPLETED` `defense_queue` rows are never purged.
  **Shipyard parity (P1): CLOSED 2026-09-22** by `20260922050734_shipyard_availability_contract_definer` —
  `can_build_ship` is now a bounded `SECURITY DEFINER` contract with `auth.uid()`/`PLAYER_NOT_OWNED` gates
  and `EXECUTE` only for `authenticated`/`service_role`.

**BUILDINGS + RESEARCH block (2026-09-26).** Live-verified and closed in this block:
`cancel_building` / `cancel_research` — queue cancellation for the two queues where OGameX has it, refund =
exactly the charged price (recomputed with the same cost function that charged), ownership via
`auth.uid()` → `players.user_id`, every refusal raised before writing
(`supabase/tests/queue_cancellation.sql` 13 PASS + 1 INFO); `calculate_building_production_delta` repaired
(it selected the non-existent `r.economy_rate` / `r.production_rate`) and its structurally unusable client
EXECUTE closed (`supabase/tests/building_production_delta_contract.sql` 10 PASS + 1 INFO). Audited and left
untouched: `can_start_research` / `can_research` / `start_research` remain the single authority for research
availability (no parallel path found), `building_prerequisites` is correctly empty (no OGameX-backed
building→building requirement exists for the eight LGI buildings), and the building contract set
(`can_start_building` / `start_building` / `calculate_building_cost|time|energy_consumption`) agrees rule by
rule with the write path. Deliberately NOT implemented: `fusion_plant` (PRODUCT DECISION, see below) and
cancellation for the shipyard/defence queues (OGameX parity).

**GAMEPLAY COMPLETION SWEEP (2026-09-26).** Transversal sweep of the remaining mechanics; per-area state:

```text
RANKING      CLOSED (contract) — players.points/rank had no writer at all (0 points for 567 players) and the
             live expedition-cap consumer was pinned to its 40 000 floor. `20260926091604` added
             calculate_player_points / recalculate_player_points / recalculate_universe_ranking /
             get_universe_ranking (17 PASS + 1 INFO). Scheduler wiring = GAP (ops decision).
             Detail: docs/systems/README_RANKING.md
WRECK FIELDS CLOSED — debris lifecycle verified end-to-end from LIVE (idempotent creation via
             combat_debris_generations + advisory lock, atomic proportional collection, return leg credits the
             origin planet). OGameX's repairable WreckField/Space Dock and debris decay = MISSING/OUT OF SCOPE.
             Detail: docs/systems/README_COMBAT_ENGINE.md §29
ESPIONAGE    PARTIAL — the mission works end-to-end and the report is replay-safe; the client read contract now
             exists (`get_player_espionage_reports`, 20260926095835: attacker-owned rows only). Still missing:
             counter-espionage (OGameX chance formula verified and recorded; the battle + debris decision is a
             PRODUCT DECISION) and level gating of the report contents. Detail: README_ESPIONAGE_ENGINE.md
MOONS        GAP — no moon model exists (no planet type, no moon buildings, no destruction, no ownership), so
             the lunar base, sensor phalanx, jump gate and moon destruction depend on a scope decision.
COMPUTER     PARTIAL — the OGameX rule is now implemented as a DERIVATION (20260926095953:
             `calculate_player_max_fleet_slots` = 1 + level, `calculate_player_fleet_slots_in_use`,
             `get_player_fleet_slots`; 8 PASS + 1 INFO), but the cap is NOT enforced in any dispatcher →
             adopting it is a PRODUCT DECISION. Expedition slots remain a separate system.
AI           PARTIAL — AI population is created/reconciled (`reconcile_universe_ai_population`) but never acts:
             no dispatcher, no fleet, no building decisions. Acting AI = PRODUCT DECISION.
MESSAGING    PARTIAL — `player_messages` has 0 producers and 0 consumers. `20260926091605` closed the
             `USING (true)` policy and the anon write grants; `20260926095835` added the owner-scoped contract
             (`get_player_messages`, `mark_message_read`; 12 PASS + 1 INFO with the espionage read contract).
             Which gameplay events become messages remains a PRODUCT DECISION, and results keep flowing through
             the existing battle report / espionage report / expedition / fleet-event surfaces (no duplication).
```

Do not change `OPEN — PARTIAL` to `CLOSED` because persistence, dispatcher or worker infrastructure exists.

## 8. SUPERSEDED / protected history

- Historical migration artifacts marked `.superseded` remain provenance only.
- Do not repair migration history by reset, replay or editing old migrations; use forward-only corrections.
- Do not restart a generic Fleet Speed audit when a directed question is sufficient.
- Protected UI wallpaper/background behavior must not be changed casually.

## 9. Session recovery

1. Read `docs/PROJECT_CONTEXT_PROMPT.md`.
2. Identify the subsystem and open only its specialized README/monitor.
3. Inspect Git and, when relevant, LIVE Supabase state.
4. Compare documentation with reality before changing anything.
5. Implement only the bounded requested scope.
6. Run targeted validation, then document durable state changes.

## 10. Specialized documentation

| Area | Document |
|---|---|
| Architecture | [`docs/architecture/README_ARCHITECTURE.md`](architecture/README_ARCHITECTURE.md) |
| Fleet Engine | [`docs/systems/README_FLEET_ENGINE.md`](systems/README_FLEET_ENGINE.md) |
| Universe Evolution | [`docs/systems/README_UNIVERSE_EVOLUTION.md`](systems/README_UNIVERSE_EVOLUTION.md) |
| Combat Engine | [`docs/systems/README_COMBAT_ENGINE.md`](systems/README_COMBAT_ENGINE.md) |
| Functional audit | [`docs/systems/README_FUNCTIONAL_AUDIT.md`](systems/README_FUNCTIONAL_AUDIT.md) |
| Identity and access | [`docs/systems/README_IDENTITY_AND_ACCESS.md`](systems/README_IDENTITY_AND_ACCESS.md) |
| Economy | [`docs/systems/README_ECONOMY.md`](systems/README_ECONOMY.md) |
| Memory system | [`docs/README_MEMORY_SYSTEM.md`](README_MEMORY_SYSTEM.md) |
| Development workflow | [`docs/tools/README_DEVELOPMENT_WORKFLOW.md`](tools/README_DEVELOPMENT_WORKFLOW.md) |
| OGameX method | [`docs/reference/README_OGAMEX.md`](reference/README_OGAMEX.md) |
| OGameX map | [`docs/reference/OGAMEX_LGI_MAP.md`](reference/OGAMEX_LGI_MAP.md) |
| OGameX systematic map (per-domain states + gap register) | [`docs/reference/README_OGAMEX_LGI_MAP.md`](reference/README_OGAMEX_LGI_MAP.md) |
| Rate/fleet monitor | [`docs/UNIVERSE_RATE_AND_FLEET_ENGINE_MONITOR.md`](UNIVERSE_RATE_AND_FLEET_ENGINE_MONITOR.md) |
| Migration provenance gate | [`docs/MIGRATION_PROVENANCE_GATE.md`](MIGRATION_PROVENANCE_GATE.md) |

## 11. Next engineering boundary

```text
BLOCK 2 — Identity / Guest Decommission
1. Read the current PROJECT_CONTEXT + identity README + LIVE integrity reconciliation.
2. Map every remaining guest/anonymous consumer in LIVE and repo before deleting anything.
3. Confirm the single remaining DevPlayer and verify that playerA plus its ownership graph are fully removed.
4. Reconcile the login/password + provision_player path end-to-end.
5. Remove or reimplement guest-only triggers, RPCs, policies, columns and guards forward-only, only after each
   consumer is proven obsolete or replaced.
6. Verify ownership/auth invariants in LIVE and regenerate database types only after schema convergence.

BLOCKED / LATER
7. AI is final-phase: compare its structure against OGameX/other clones first; implement only if L.G.I. has the
   required authoritative engine/callers, otherwise leave it deferred.
8. Combat: the **base Combat Engine is CERTIFIED** (single attacking fleet vs one planet + expedition
   branch, §5). Phase 4 (read-only ACS/DEFEND/multi-fleet audit) and **Phase 4A (participant/battle identity
   foundation, 13/13 collision fixture) are CLOSED**; the Phase 4A defects it removed — legacy unit/snapshot
   uniqueness keys colliding across fleets, target identity without `participant_id`, loss payloads without a
   participant key — are fixed and must not be re-opened. **Phase 4B — ACS/DEFEND architecture + DEFENDER/FLEET
   representation is CLOSED (2026-09-22)**: new migration
   `20260922043604_defender_fleet_participant_representation` (forward-only, LIVE applied, repo file
   content-identical) makes `initialize_individual_combat_units` materialise `DEFENDER/FLEET` participants
   (own `participant_id`, own owner technology context) and makes `resolve_attack_arrival` fail closed
   (`MULTI_DEFENDER_SETTLEMENT_NOT_DEFINED`). No schema change was needed: `combat_battle_participants` could
   already represent `DEFENDER/FLEET`. Still NOT IMPLEMENTED (product decisions, not defects): ACS
   grouping/dispatch, DEFEND dispatch, multi-fleet settlement, per-fleet survivor/loot attribution, per-fleet
   report payloads, ACS/DEFEND UI. **Next mission**: the product-gate package is `README_COMBAT_ENGINE` **§22**
   (§21 = option analysis; §22 = decision status, settlement contract, implementation boundary, test plan;
   **§23 = ACS settlement contract research**, read-only: LGI money-path contract inventory, the OGameX
   responsibility map, the LGI↔OGameX contract map, the classification of every OGameX finding, and the
   verified conclusion that the only MISSING contracts are the **battle-level settlement orchestrator** and
   the **participant fleet settlement** one — both blockable by PG-09/PG-10 only on the loot path).
   **All five gates (PG-08…PG-18) are IMPLEMENTED** by
   `20260922060013_acs_settlement_participant_model` (`README_COMBAT_ENGINE` **§24**), with **no schema
   change**; the certified regressions stay green (214 PASS) and the ACS settlement fixture is 18/18. What
   remains is the **producer** (creating/joining participants), ACS grouping/dispatch, DEFEND dispatch,
   withdrawal/late-join rules and the ACS/DEFEND UI, plus the isolated OGameX `lootShare` arithmetic
   BUG/OPEN. The ACS_HOLD transport becoming reachable (§7) does not by itself create gameplay.
   Do not reopen the certified chain without new evidence of a defect, and do not create a second combat
   architecture.

9. Browser certification remains a separate validation track.
```

> **Golden rule:** inspect → compare → decide → implement → test → verify → document.

## 12. MASTER GAMEPLAY AUDIT — OGameX ↔ LGI (2026-09-25)

Status: **COMPLETE** — read-only audit (zero code, zero migration, zero LIVE mutation). Full system-by-system
comparison against OGameX (`lanedirt/OGameX` @ `7c420ba`, 2026-09-21) plus `template/` as the classic/repo
reference. Detail stays in the specialized documents; this entry is the operational pointer and the list of
decisions the audit leaves open.

Baseline measured LIVE (read-only): 236 public functions, 87 public relations (21 views), 73
`SECURITY DEFINER`, 2 `pg_cron` jobs (fleet worker 1 s, universe heartbeat 1 min), triggers limited to the
`trg_enforce_player_write_*` ownership guards.

**Do NOT re-audit — implemented and verified end-to-end** (definition → runtime reader → application →
persistence): economy/production with energy factor, Energy and Plasma Technology, storage and cap; the 8
building definitions, field limit and build queue; the 16 research definitions and their readers; the 16
ships and 8 defences with prerequisites and queues; distance / travel time / fuel / cargo / per-mission speed
classes; the 7 resolved missions (`TRANSPORT`, `DEPLOY`, `COLONIZE`, `ESPIONAGE`, `RECYCLE`, `EXPEDITION`,
`ATTACK`) plus `ACS_HOLD` Fase A; the certified single-attacker combat engine; expeditions with 11 outcome
branches; debris creation and collection; Lifeforms; expedition items; dark-matter rewards; the universe
clock / expansion / AI population engine.

**Declared but NOT implemented — classified, not scheduled** (evidence: `template/*.txt`, OGameX code, or both):

- **Building demolition / downgrade with salvage.** LGI's own mockup declares
  `window.buildListActionDemolish`, `state.downgrading`, `locaDemolishStructureQuestion` and, in the
  `ion_technology` description, "demoler un edificio recupera más de sus recursos (+1 % de rescate por
  nivel)". LGI has no demolish/downgrade function and no salvage formula; the `CANCELLED` value of
  `building_queue` **is** written now (cancellation, 2026-09-26) but cancellation is not demolition: it only
  refunds the item that was charged and never removes an existing level. The base recovery rate is undefined →
  **PRODUCT DECISION REQUIRED**. This qualifies the earlier "ion = prerequisite only" note: ion keeps its
  unlock role, and a declared numeric effect is now on record as unimplemented.
- **Fleet-slot cap (`computer_technology`).** OGameX `MAX_FLEET_SLOTS = 1 + level`, every mission except
  missile attack holds a slot for its entire duration (`GameMission.php:234`,
  `PlayerService.php:540/566`); LGI's mockup declares the same. LGI has no fleet-slot subsystem
  (`fleet_slot` / `max_fleet` = NONE). Investigation-only for now.
- **Colony cap / colonisation gating (`astrophysics`).** OGameX `getMaxPlanetAmount = 1 + round(level/2)`
  and positions 1 / 15 require level 8 (`canColonizePosition`); the LGI mockup states one extra colony per
  two levels. LGI has no cap (`max_planet` = NONE) and `resolve_colonize_arrival` uses a fixed
  `fields_total = 100`. Unchanged: **AUDITED — PENDING PRODUCT DECISION**.
- **Colonisation is unreachable from the client.** `start_colonize_fleet` is LIVE-verified with EXECUTE for
  `authenticated`, but `src/` contains no `COLONIZE` reference.
- **Fleet cargo is unreachable from the client.** `load_fleet_cargo` / `calculate_fleet_cargo_capacity`
  validate capacity, resources and ownership but are granted to `postgres`/`service_role` only, and the
  dispatch RPCs take no resource parameters.
- **Espionage has no probe loss, counter-espionage or level-gated visibility.** `resolve_espionage_arrival`
  always returns the probes and writes full resources + fleet + defence JSON regardless of level. OGameX runs
  a counter-espionage battle (`CounterEspionageService`, `EspionageMission.php:112-178`).
  **Formula verified 2026-09-26** (verbatim from `CounterEspionageService.php` @ `7c420bad`):
  `chance% = floor(clamp(0..100, defender_ships × (defender_esp_level − attacker_esp_level + 1) / (probes × 4) × 100))`,
  rolled on 1..100, and on success OGameX resolves a battle between the probes and the defender's ships
  (defence structures excluded). Implementing it needs that battle plus a decision about debris from destroyed
  probes → **PRODUCT DECISION**, not implemented. Detail: `README_ESPIONAGE_ENGINE.md` §4.
- **Queues have no Dark-Matter acceleration and no multi-item queue.** OGameX has multi-item queues with
  `cancel()` / `addDowngrade()` and DM halving / instant completion (`HalvingService`). LGI: one active item,
  no DM acceleration, and `dark_matter` is only ever credited by expedition resolution. **Cancellation IS
  implemented for the building and research queues** (2026-09-26: `cancel_building` / `cancel_research`,
  refund = exactly the charged price, taken from OGameX `cancel()`); the shipyard and defence queues
  deliberately have none because OGameX states that unit queue objects cannot be cancelled.
- **`fusion_plant` is NOT implemented, deliberately (2026-09-26).** Its OGameX contract is fully determined
  and verified against `BuildingObjects.php` @ `7c420bad`: 900/360/180, factor 1.8, requirements
  `deuterium_synthesizer 5` + `energy_technology 3`, energy `30·L·(1.05 + 0.01·energy_technology)^L`, **and a
  deuterium burn** `-10·L·1.1^L` that the earlier record did not capture. The blocker is not a missing formula
  branch: LGI has no consumption model, and the settlement divides per-hour production by (economy ×
  production) and weights it by evolution, so an absolute burn cannot ride `deuterium_per_hour` without being
  scaled by universe speed; the fuel-shortage policy (OGame stops the reactor) is undetermined. Shipping the
  reactor without the burn would be free energy. Recorded as **PRODUCT DECISION**; the full analysis lives in
  `docs/reference/README_OGAMEX_LGI_MAP.md` (NEXT CANDIDATES 4).
- Broader scope declared in `template/*.txt` but absent from LIVE definitions: moons (jump gate, lunar base),
  robot/nano factory, terraformer, missile silo + ABM/IPM, crawler ("taladradores", +0.02 % per unit, capped
  by mine levels), capital ships (Leviatán, Juggernaut, Tempestad), extra defences (Centinela orbital, Cañón
  de singularidad, Cúpula de escudo planetario), energy-surplus→deuterium technology, officers and character
  classes. Treat as **roadmap intent, not contract**.

Not reopened here: IRN (needs research laboratories), `computer_technology`, `astrophysics`, `graviton`,
`laser`, `ion` unlock roles, `DEFEND` (technically blocked by ACS grouping), ACS grouping (PG-08/09/10/17/18
decided, implementation pending an explicit mission) and the Lifeform DLC (out of scope).

**Fleet cargo IMPLEMENTED (2026-09-25)** — the audit-level candidate of this section is now real gameplay:
the existing `load_fleet_cargo` is owner-gated (`auth.uid()` → `players.user_id` → fleet, plus origin-planet
ownership and a `TRANSPORT | ESPIONAGE | ACS_HOLD | DEPLOY | COLONIZE | EXPEDITION` mission whitelist) and its
EXECUTE was widened to `authenticated` only; applied LIVE as `20260925154234` (forward-only, no schema change).
**Cargo lifecycle COMPLETED (2026-09-25) — `20260925171816`:** `resolve_deploy_arrival` now delivers the cargo
to the destination planet, `resolve_colonize_arrival` seeds the new colony with it, and the EXPEDITION
`RESOURCES` outcome ADDS the find instead of overwriting the cargo. Two PRE-EXISTING latent defects were found
on those paths and fixed forward-only: a PL/pgSQL `fleet_id` column/variable ambiguity in
`resolve_colonize_arrival` (`20260925172115` — colonisation arrivals could never complete) and the same
ambiguity in `prepare_expedition_resource_reward` (`20260925172311` — EXPEDITION/RESOURCES could never
resolve). The Fleet UI loads optional METAL/CRISTAL/DEUTERIO at dispatch and displays the payload/capacity the
SERVER returns. Regressions: `fleet_cargo_loading.sql` 18/18 and `fleet_cargo_lifecycle.sql` 17/17 PASS LIVE,
zero residue. `RECYCLE` and `ATTACK` remain deliberately excluded; detail:
[`systems/README_FLEET_ENGINE.md`](systems/README_FLEET_ENGINE.md) §24–§25. Still deferred: colonisation UI,
fleet-slot cap and colony cap (product
decision pending). Demolition/downgrade was CLOSED on 2026-09-26 (see the block below).
Detailed technical notes belong in [`reference/OGAMEX_LGI_MAP.md`](reference/OGAMEX_LGI_MAP.md) and the
matching [`systems/README_*.md`](systems/) document, not in this operational file.

**TRANSVERSAL SWEEP III (2026-09-26)** — one pending mechanic was implementable without a new product
decision and is now CLOSED: **building demolition / downgrade** (`20260926160000_building_demolition`), i.e.
`start_demolition` / `can_start_demolition` / `inspect_demolition`, cost = construction price of the removed
level −4 %/level of `ion_technology`, duration = construction formula at that level, level 0 reachable, guards
by present dependents / active research / active unit order / busy queue, action-charged and refunded exactly
on cancel; 18/18 assertions PASS LIVE, zero residue. Details:
[`systems/README_ECONOMY.md`](systems/README_ECONOMY.md#building-demolition-downgrade--2026-09-26) and
[`reference/README_OGAMEX_LGI_MAP.md`](reference/README_OGAMEX_LGI_MAP.md) §"Demolition / downgrade — CLOSED".

The rest of the transversal map was re-audited against OGameX and classified instead of half-built. **Ranking
category scores were then also closed** (same sweep, owner-approved): `players.economy_points /
research_points / military_points` plus per-category ranks, `calculate_player_category_scores`, the patched
refresh functions (`recalculate_universe_ranking`, `recalculate_player_points`) and
`get_universe_ranking_by_category`; 8/8 assertions PASS LIVE — see
[`systems/README_RANKING.md`](systems/README_RANKING.md) §«Category scores». **Research laboratory, its 16
OGameX gates and the Intergalactic Research Network are also CLOSED** (`20260926180000`): the laboratory
(200/400/200, factor 2, planets only), the OGameX gate table filled into the already-certified mechanism, and
IRN applied as OGameX's divisor ratio to LGI's research-time curve (inert at IRN 0); 11/11 assertions PASS
LIVE — see [`systems/README_RESEARCH.md`](systems/README_RESEARCH.md). The remaining items are **approved but
not yet implemented** (owner decision 2026-09-26): the wreck field + Space Dock subsystem, the dedicated
moon-destruction mission type, the AI behaviour policy, the colony cap and the message/espionage retention
window. Premium/DM, alliances, chat/buddies/notes and Lifeforms stay out of scope. No certified contract was
weakened and no formula was invented.

## Integral Supabase ↔ frontend contract audit — CLOSED (2026-09-26)

Final verification pass over every contract the React client consumes. 28 RPC and 17 tables reviewed one by one
against LIVE; the surface is certified, with two residual items recorded (one latent bug, one policy decision).

**Closed by this pass**

* **Contract drift: none.** 28/28 RPC exist with matching arguments, defaults, SECURITY mode, ACL and return columns;
  17/17 tables exist with RLS and one policy each; `database.types.ts` matches LIVE for every contract the client
  calls (0 untyped calls remain).
* **Casts removed (mechanical, behaviour-identical):** the `rpcUntyped` helper and the `supabase.rpc as unknown as …`
  casts were retired in `src/App.tsx`, `src/BuildingDemolitionPanel.tsx`, `src/lib/identity.ts` and
  `src/GameplayEnginePanel.tsx` now that the generated types carry those entries. `lib/universeEvolutionMonitor.ts`
  keeps its own wrapper: it does **not** cast the RPC, it normalises and type-validates each returned field at runtime.
* **Error channels:** `can_start_building` (App.tsx) now mirrors its siblings (`const {data, error}; if (error) throw`)
  and the expedition slot/item pair surfaces `error` through the view's own error state instead of failing silently.
  Business refusals are rows, never exceptions, so no gameplay semantics changed. `start_fleet` in `GalaxyView`
  already handled its error (the wrapper definition is what a naive scan flags).
* **Espionage:** the message centre reads the certified RPC, never the `deny_direct_api_access` table.

**Residual (recorded, deliberately not changed)**

* **BUG (latent, pre-existing, not reachable from the UI):** `can_start_building` / `evaluate_building_start_internal`
  raise `structure of query does not match function result type` when asked about a building id that does not exist in
  `building_definitions`, instead of returning the designed `Edificio inexistente` row. Reproduced identically in the
  pre-hardening implementation, so the 2026-09-26 ownership fix did not introduce it. The UI only iterates over ids
  taken from `building_definitions`, so no client path reaches it. Fixing it means rewriting that branch — its own task.
* **SECURITY/POLICY DECISION (out of scope):** the RLS policies of `planet_resources` and `building_queue` include an
  extra allow-branch `pl.is_guest = true` next to `pl.user_id = auth.uid()`: resources and queues of a player flagged
  as *guest* would be readable by any authenticated actor. Demonstrated at policy level only; impact on LIVE not
  evaluated (no guest player was identified). Needs an identity decision, not a frontend change.

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
