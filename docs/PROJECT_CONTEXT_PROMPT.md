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

### Mandatory verification-before-new-work gate

Before proposing, assigning or executing any new audit, investigation, implementation or agent mission, first verify whether the requested subject is already documented, tested, certified or otherwise explicitly closed in the current repository/context.

- **CLOSED / VERIFIED:** do not repeat the work.
- **OPEN but already investigated:** continue from the existing evidence; do not rerun the same audit.
- **PARTIALLY VERIFIED:** work only on the exact unverified residue.
- **UNRESOLVED PRODUCT DECISION:** do not silently convert technical evidence into a product decision.
- **NOT YET VERIFIED:** only then create a new audit/investigation scope.

The check must use the current repository state and the relevant specialized documentation, not memory or an older session assumption. If a prior report already establishes the requested result, treat that result as evidence and identify only what remains missing.

This gate exists specifically to prevent duplicate Cline/Copilot missions, repeated OGameX comparisons and wasted implementation/audit cycles.

### Missing-contract / OGameX implementation rule

When L.G.I. requires a contract, function or subsystem that does **not yet exist**, OGameX must be consulted before designing the missing implementation. Use the current OGameX implementation to determine responsibility, lifecycle, inputs/outputs, ownership model, ordering and relevant failure/idempotency behavior.

The sequence is:

LGI existing invariants → OGameX equivalent/reference → LGI contract definition → human product decision where required → implementation → tests → verification.

OGameX remains a reference, never an authority or dependency. Do not copy Laravel/PHP/ORM/routing architecture or import game/balance semantics blindly. If OGameX contradicts an explicit L.G.I. contract or product decision, L.G.I. wins and the contradiction must be documented.

For an existing L.G.I. contract that has already been verified, do **not** reopen it merely because OGameX has an equivalent implementation. OGameX is primarily required for genuine L.G.I. gaps and for resolving documented architectural unknowns.

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
- Identity onboarding is **email/password only**: no anonymous session bootstrap, no `register_guest_player`,
  no guest authorization branch and no claiming of existing (`user_id IS NULL`/AI/DevPlayer) players. An
  authenticated user without a player performs the explicit `provision_player(...)` step
  (detail: [`README_IDENTITY_AND_ACCESS.md`](systems/README_IDENTITY_AND_ACCESS.md)).
- Documentation detail is segregated; moving it to a specialized README is not deletion.
- Migration provenance is governed by the [Migration Provenance Gate](MIGRATION_PROVENANCE_GATE.md):
  `20260919180000_fix_planet_support_authorization_ambiguity.sql` is **LOCAL_ONLY / NOT_DEPLOYED /
  BLOCKED**, while LIVE-only versions `20260919055336`, `20260919061454`, `20260919062509` and
  `20260919070020` are **NOT_RECOVERABLE**. Missing provenance blocks deployment; never reconstruct
  lost SQL, create same-version placeholders, mark migrations reverted, or edit the migration ledger.
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

- **DevPlayer:** exactly **one** DevPlayer/HUMAN test account is intended to remain. `playerA` was selected for
  removal; its child/parent ownership graph is to be removed with it. The remaining DevPlayer is the canonical test
  account. Any unexpected AI/user reassignment observed in LIVE must be reconciled before further identity cleanup.
- **AI:** do not implement or redesign AI yet. Before the AI phase, compare the current AI schema/call graph with
  OGameX and other suitable OGame-like clones to identify the expected structure, schedulers, decision loops and
  required callers. If L.G.I. lacks the necessary code/callers, leave AI as a final-phase scope rather than inventing
  infrastructure prematurely.

- Guest decommission: **IN PROGRESS — BLOCK 2**. Guest/anonymous identity is no longer part of the intended product
  model; the target architecture is the existing email/password login + explicit `provision_player(...)` flow.
  Guest-specific registration, authorization branches, guest RLS policies and `players.is_guest` are candidates for
  removal or controlled reimplementation only where required by the final login/password architecture. Do not delete
  guest infrastructure blindly: first map all LIVE consumers and dependencies, then remove/reimplement forward-only.
  `initialize_player_research` verification is CLOSED (read-only LIVE verification).
- LIVE integrity reconciliation (2026-09-20): executed read-only and recorded in
  [`docs/audits/LIVE_INTEGRITY_RECONCILIATION_2026-09-20.md`](audits/LIVE_INTEGRITY_RECONCILIATION_2026-09-20.md).
  Confirmed LIVE: `on_auth_user_created` still ENABLED and it has **already reassigned 12 AI empires**
  (`player_type='AI'` with `user_id` set); `register_guest_player` still reachable by `authenticated`;
  6 `*_select_guest` policies live; 9 functions still carry `is_guest` logic; 2 cron jobs active.
  Deployment is **BLOCKED** by `docs/MIGRATION_PROVENANCE_GATE.md` (4 LIVE-only versions unrecoverable).
- **Block 1 security fixes CLOSED in LIVE (2026-09-21):** `ui_defense_queue` ownership/auth hardening,
  analysis-function ACL hardening (including `generate_building_sequences` external execution removal), and RLS
  enablement on `universe_process_health` / `combat_battle_participants` were applied and verified. The three local
  migration files were renamed to their server-assigned ledger versions `20260921044623`, `20260921044643` and
  `20260921044659`, preserving their hashes. No commit/push was performed as part of the audit execution.
- Block 1 follow-up: the numeric `p_depth` guard for `generate_building_sequences` was **not** invented; the external
  abuse vector is closed by ACL. A privileged/future re-grant could still pass a large depth and remains a separate
  bounded hardening decision.
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
