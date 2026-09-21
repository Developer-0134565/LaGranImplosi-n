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
- **Research certification CLOSED (2026-09-21)** for the audited chain: availability (`can_start_research`
  is the single authoritative client contract), prerequisites (16 LIVE rows; SECDEF `can_research`),
  cost and time (single-sourced, verified to 4 decimals against LIVE), queue semantics, atomic
  single charge, ownership, persistent level (`player_research`) and the REAL production completion path
  (`process_universe_heartbeat → process_universe_clock → process_universe_tick → process_planet_tick →
  complete_research`). `complete_research` is idempotent since `20260921140916`; the client-facing
  `research_action_candidates` view was retired as a client contract by `20260921140925`; the lifecycle
  suite (27 gated + 12 contract assertions) is runnable and its fixture accepts `DevPlayer`.
  Detail: [`README_RESEARCH.md`](systems/README_RESEARCH.md).
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
- **Combat Engine: OPEN — the next CORE block.** Defense already exposes the single source of truth combat must
  consume (`planet_defenses` + `defense_definitions.attack|shield|hull`, with `repair_defenses_after_combat` and the
  `get_combat_defense_*` readers). No combat formula exists yet. Lifeforms, Items, Auction, Merchant, Alliance and
  Officers remain future **UPDATE** features and must not be started.

Evidence and detailed tests remain in
[`docs/systems/README_FLEET_ENGINE.md`](systems/README_FLEET_ENGINE.md), not in this file.

## 7. OPEN

### OPEN — PARTIAL: ACS / HOLDING / DEFEND

Decision (2026-09-19): **ACS_HOLD Fase A implemented in the backend**; `DEFEND` remains closed.

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

- `DEFEND` and ACS combat integration / multi-defender settlement → **BLOCKED BY COMBAT ENGINE**;
- holding fuel → **product decision pending** (not invented);
- maximum holding duration → **product decision pending** (not hardcoded);
- support recall during outbound/holding;
- UI (the future selector is `ACS_HOLD` + `DEFEND`; DEFEND stays closed);
- browser certification of the ACS_HOLD flow and execution of the new SQL test in LIVE.

### Other OPEN work

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
  `start_research` still grants EXECUTE to `anon` (the body rejects anon with
  `Authentication required`), `ui_research_definitions()` is a redundant SECURITY DEFINER wrapper whose
  `search_path` omits `pg_temp`, `research_action_candidates` keeps ALL-privilege grants for
  `service_role`, old `COMPLETED` queue rows are never purged, and there is no research cancellation
  path. (The dead `QUEUED`/`ACTIVE` research status guards were removed by `20260921152702`; the CHECK
  still allows only `RESEARCHING`/`COMPLETED`/`CANCELLED`.)
- **Defense hygiene (P3 — deferred):** `start_defense` still grants EXECUTE to `anon` (the body rejects it);
  `calculate_defense_build_time` and `check_defense_requirements` are PUBLIC-executable and fail for clients;
  `CANCELLED` is admitted by the CHECK but unreachable; `COMPLETED` `defense_queue` rows are never purged.
  **Shipyard parity (P1, Shipyard-owned):** `can_build_ship` still carries the same client-contract defect class
  that `can_build_defense` had — reported by the Shipyard audit, to be closed by a Shipyard mission.

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
8. Combat/DEFEND and remaining ACS product decisions stay behind their existing boundaries.
9. Browser certification remains a separate validation track.
```

> **Golden rule:** inspect → compare → decide → implement → test → verify → document.
