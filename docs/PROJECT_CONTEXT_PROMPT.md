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
  players holding a `user_id`. Still OPEN: the six `*_select_guest` policies, the 12 policies still
  carrying an `is_guest` branch, the `enforce_player_write_access` guest branch, the `players.is_guest`
  column (0 rows true), and the `early_tester_registrations` / `player_achievements` product decision.
- Identity cleanup detail (verified LIVE 2026-09-21). **Anonymous Auth:** 13 users → **0** (all deleted;
  no anonymous owner remains for any player). **Claimed AI empires:** 13 → **0** — the empires
  `AI-G1-S1-P2` … `AI-G1-S1-P14` were **released** (`players.user_id = NULL`), **not destroyed**: each
  still exists as an unowned AI with 1 homeworld and no gameplay investment (0 research, 0 buildings,
  0 ships, 0 queues). **AI owned by the DEV email account: none** — the email account owns only
  `DevPlayer`. **Unowned AI pool:** 370 players. Nothing was deleted by the identity closeout beyond the
  13 anonymous Auth users.
- **REGRESSION found 2026-09-21 (OPEN, verified LIVE).** `planet_buildings`, `planet_defenses`,
  `planet_ships`, `shipyard_queue`, `fleet_movements` and `fleet_movement_ships` each carry **only** a
  `*_select_guest` policy (`pl.is_guest = true`). Now that the DEV player is `is_guest = false`, its owner
  session reads **0 rows** from `planet_buildings` (2 exist), `planet_ships` (1 exists) and
  `shipyard_queue` (1 exists) — all three are read by `src/App.tsx`. `planets`, `planet_resources`,
  `player_research`, `building_queue` and `research_queue` remain readable. Note
  `20260920120400_remove_guest_rls_surface.sql` **drops** those six policies and creates **no**
  owner-based replacement, so applying it as-is would leave them deny-all. Fix belongs to the guest-RLS
  phase; it must not be improvised directly in LIVE.
- `players_select_access` still hardcodes the DevPlayer UUID `aa1deb2d-3ed6-4350-922a-172d999b2af7` and
  the guest branch. Verified 2026-09-21: a **stranger session can read the DevPlayer row** (its
  `planet_resources` stay protected). Follow-up: rebase the policy on `players.user_id = auth.uid()`.
- Anonymous sign-in was still **ENABLED** in the Auth configuration on 2026-09-21
  (`GET /auth/v1/settings` → `external.anonymous_users = true`), with 13 anonymous users then; all 13 are
  now deleted. Disabling it is still a pending Auth-configuration decision.
- LIVE integrity reconciliation (2026-09-20): executed read-only and recorded in
  [`docs/audits/LIVE_INTEGRITY_RECONCILIATION_2026-09-20.md`](audits/LIVE_INTEGRITY_RECONCILIATION_2026-09-20.md).
  Its findings were **superseded by the 2026-09-21 application**: `on_auth_user_created` is now dropped
  (it had claimed 13 AI empires, all since released), `register_guest_player` is dropped, and the
  remaining `is_guest` surface is the RLS/branch residue listed above.
- Security findings **APPLIED** (re-versioned, 2026-09-21): `20260921044623` (was `20260920120500` —
  public cross-player `ui_defense_queue` read), `20260921044643` (was `20260920120600` — unauthenticated
  unbounded `generate_building_sequences`), `20260921044659` (was `20260920120700` — RLS disabled on
  `universe_process_health` / `combat_battle_participants`). Still **NOT** applied: `20260920120800`
  (guest ownership bypasses; replaces the unexecutable `20260920120300`, now `.superseded`).
- Browser certification of the seven implemented fleet missions.
- Shipyard/defence and buildings browser certification where still pending.
- Bounded hygiene decisions for `calculate_universe_rates` and unused Lifeform keys.
- Fleet lifecycle UI, Combat UI, Lifeforms UI, expedition result UI and `player_messages`.

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
1. Define and implement the minimum participant-aware combat model required by ACS
   (DEFEND stays closed until then).
2. Certify the ACS_HOLD Fase A flow: run the SQL tests in LIVE, then define the
   player-facing UI contract (selector ACS_HOLD + DEFEND, DEFEND still closed).
3. Decide the two open product rules: holding fuel and maximum holding duration.
4. Certify the already-converged seven fleet missions in the browser.
5. Continue remaining browser and bounded hygiene work without reopening closed fleet rules.
```

> **Golden rule:** inspect → compare → decide → implement → test → verify → document.
