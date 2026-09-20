# L.G.I. — Forensic Project Integrity Report
## 2026-09-20 — segregated audit record

> **Purpose:** preserve the forensic integrity audit as a specialized document, separate from
> `docs/PROJECT_CONTEXT_PROMPT.md`. This file is an audit record, not the operational context panel.
>
> **Source:** forensic report supplied by Cline on 2026-09-20.
>
> **Important:** the report states that the auditing session performed read-only operations and did not
> create or modify the workspace artifacts listed below. Do not infer authorship beyond that statement.

---

## 1. Baseline and workspace integrity

- Branch: `main`
- HEAD: `12ff781fcef0988a8bc6a980f8b2eacbc63d3b85`
- `origin/main`: same commit
- Ahead / behind: `0 / 0`
- `git diff --check`: clean

At the end of the forensic mission the workspace contained:

```text
M  docs/PROJECT_CONTEXT_PROMPT.md
M  docs/systems/README_FLEET_ENGINE.md
?? supabase/migrations/20260920010000_converge_local_fleet_dispatch_classifiers.sql
```

The report attributes those three artifacts to a parallel session, with mtimes before the forensic session's
T0. They were deliberately **not reverted, cleaned or modified**.

The untracked migration is classified as **LOCAL_ONLY** and is outside the audited HEAD/provenance chain.

### Do not touch

- `*.superseded`
- `*.obsolete`
- `refs/copilot/checkpoints/**`
- `refs/cline/checkpoints/**`
- stashes `stash@{0}` and `stash@{1}`
- `backup/supabase/*.sql`
- the seven unreachable blobs identified by the audit
- the four LIVE-only ledger artifacts
- `20260919180000`
- the parallel-session artifacts listed above

---

## 2. Executive conclusion

The forensic audit classifies the project as:

**Functional engine, but incomplete chain integrity.**

Reported totals:

- 22 findings.
- 3 CRITICAL.
- 4 HIGH.
- 8 MEDIUM.
- 7 LOW/INFO.
- 6 provenance/LIVE-only gaps.
- 11 demonstrated dead ends.
- 4 active legacy paths.
- 5 documentation divergences.

The most important newly identified issue is a possible **automatic reassignment of an existing player by an `auth.users` trigger**.

The second major issue is that the local fleet-dispatch chain does not fully reproduce the observed LIVE chain.

---

# 3. CRITICAL findings

## F-01 — Identity / ownership / onboarding

The local evidence indicates an `auth.users` insertion trigger:

```text
auth.users INSERT
    ↓
on_auth_user_created
    ↓
private.handle_new_auth_user
    ↓
oldest unclaimed player
    ↓
assign player.user_id to new auth user
```

The 16/09 data snapshot reportedly contains:

- 163/163 players with `user_id IS NULL`.
- 161 AI.
- 2 DevPlayer/HUMAN guest records.

This potentially conflicts with the canonical identity chain:

```text
auth.uid()
  ↓
players.user_id
  ↓
players.id
  ↓
owned active planet
  ↓
universe
```

and with the explicit onboarding RPC:

```text
register_guest_player
```

### Risk

A new user could receive an existing player through the trigger before the intended guest-registration path,
causing identity drift or ambiguous ownership.

### Status

**LIVE VERIFICATION REQUIRED.**

Do not modify the trigger before LIVE verification and an explicit product/architecture decision.

---

## F-02 — `start_colonize_fleet` calls a removed helper

The local body of `start_colonize_fleet` still calls:

```text
calculate_fleet_fuel_for_distance
```

The audit reports that this function was dropped by:

```text
20260919042419
```

Therefore a rebuild from the local migration chain can produce:

```text
start_colonize_fleet
    ↓
removed helper
    ↓
runtime failure
```

The local colonization path also does not reproduce the fully converged canonical speed/class pipeline.

### Status

**LOCAL BUG.**

Do not recreate the missing helper merely to make the path compile. Its provenance is itself a separate gap.

---

## F-03 — Fleet provenance / LIVE-only convergence

The audit reports several LIVE states that are not reproducible from the current local migration history:

- four LIVE-only versions without recoverable payloads;
- classifier creation outside the complete local chain;
- converged bodies of the three dispatchers not reproducible locally;
- missing body/provenance for `calculate_player_ship_fuel_consumption`.

### Status

**PROVENANCE GATE CLOSED.**

Do not invent or reconstruct missing SQL without evidence.

---

# 4. HIGH findings

## F-04 — `ui_defense_queue` ownership contract

The function is reported as `SECURITY DEFINER` and validates through:

```text
planets.player_id = p_player_id
```

without demonstrated `auth.uid()` ownership chaining.

Potential risk: cross-player queue reads.

**Status:** LIVE verification required before ACL/RLS changes.

## F-05 — public EXECUTE surface

The audit reports EXECUTE for `anon` on:

- `start_fleet_mixed`
- `start_building`
- `start_research`
- `start_defense`
- `sync_current_planet_resources`

Do not revoke until the effective LIVE ACL matrix is verified.

## F-06 — Lifeform dead state

`lifeform_building_queue` and `lifeform_research_queue` are reported as:

- written but not meaningfully read;
- without a processing worker;
- rows inserted as `COMPLETED`;
- `started_at = finishes_at = now()`;
- level applied immediately.

Do not delete these tables/triggers yet: they are evidence of an incomplete design.

## F-07 — Worker / heartbeat duplication

The audit identifies:

- `deuteria-fleet-worker` every 1 second;
- a heartbeat every 1 second;
- a historical heartbeat every 1 minute;
- `process_universe_tick` also capable of draining fleet movements.

This creates up to three drain paths, currently mitigated by advisory locking.

---

# 5. Medium / Low findings

## F-08 — Parallel temporal paths

Coexisting generations include:

- `process_planet_tick`
- `process_planet_tick_local`
- `process_shipyard_queue`
- `process_defense_queue`
- `*_until`

They do not necessarily have identical settlement semantics.

## F-09 — Optimization baseline / orphans

A broad family of `simulate_*`, `evaluate_*`, `rank_*`, `project_*` and snapshot functions/views has no
clear engine/UI consumer in the local chain.

Do not remove until LIVE consumers, including AI usage, are checked.

## F-10 — Historical `start_fleet_core` wrapper

A migration references `start_fleet_core`, but the audit found no actual definition for it.

## F-11 — Stale generated frontend contract

`database.types.ts` reportedly retains 13 retired RPCs, including internal worker surface such as
`run_fleet_worker`.

## F-12 — Research duplicate contracts

Research exposes parallel concepts:

- `can_research`
- `can_start_research`
- `check_research_requirements`
- `get_research_requirements`

The latter requirement helpers were reported as having no consumers.

## F-13 — Legacy universe-rate path

`calculate_universe_rates` retains legacy `fleet_speed` routing and has no identified engine consumer.

## F-14 — Documentation drift

Reported drift affects:

- `README_FLEET_ENGINE.md`
- `PROJECT_CONTEXT_PROMPT.md`
- `README_ECONOMY.md`
- `README_FUNCTIONAL_AUDIT.md`
- `PRODUCTION_DB_BASELINE.md`
- `README_IDENTITY_AND_ACCESS.md`

In particular, the identity README omits the reported `auth.users` trigger path.

## F-15 — Possible orphan tables

Reported candidates:

- `player_messages`
- `player_notes`
- `player_achievements`
- `expedition_resource_caps`
- `expedition_ship_tiers`
- `combat_unit_state`

Do not remove without LIVE/baseline reconciliation.

## F-16 — Trigger function ACL hygiene

`enforce_player_write_access` reportedly has EXECUTE for `anon`. This is a security-hygiene observation,
not by itself proof of a functional vulnerability.

## F-17 — Baseline reconstruction gap

The local tree does not reproduce the complete baseline represented by the 16/09 dump:

- 66 tables;
- 220 functions;
- 21 views.

Some engine/support paths therefore cannot be rebuilt solely from local CREATE history.

## F-18 — Parallel workspace migration

```text
supabase/migrations/20260920010000_converge_local_fleet_dispatch_classifiers.sql
```

is reported as untracked and LOCAL_ONLY.

It converges some speed/class calls but still leaves the fuel helper failure, expedition inline formula,
missing fuel helper provenance and colonization-distance provenance unresolved.

## F-19 — Frontend mission surface

The UI does not expose complete COLONIZE / ACS_HOLD / DEFEND surfaces according to the audit.

## F-20 — Empty message/note contracts

`player_messages` and `player_notes` appear to exist without an identified writer.

---

# 6. Active legacy paths

| Legacy path | Intended/current path | Audit status |
|---|---|---|
| `calculate_fleet_fuel_for_distance` | `calculate_player_fleet_fuel_for_distance` | still called by colonization |
| universal `universes.fleet_speed` | mission classifier | local bypass detected |
| inline EXPEDITION travel formula | `calculate_fleet_travel_time` | divergent path |
| `get_player_fleet_speed_multiplier` | integrated speed bonus | historical duplicate |
| `process_planet_tick_local` | `process_planet_tick` | coexistence |
| `process_*_queue` | `process_*_queue_until` | coexistence |
| `can_research` | `can_start_research` | parallel contracts |
| `calculate_universe_rates` | mission-aware routing | legacy |

---

# 7. Fleet canonical chain vs provenance

The intended canonical fleet pipeline is:

```text
calculate_player_ship_speed()
        ↓
calculate_mission_fleet_speed_multiplier()
        ↓
universe evolution E^(1/3)
        ↓
mission / item / lifeform modifiers
        ↓
calculate_fleet_travel_time()
        ↓
calculate_player_fleet_fuel_for_distance()
```

The forensic report explicitly distinguishes the **observed LIVE convergence** from the **locally reproducible
migration chain**.

This distinction must be preserved. LIVE evidence is not permission to fabricate missing migrations.

---

# 8. Documentation / provenance rules

The following are evidence and must not be silently normalized:

- `.superseded` / `.obsolete` artifacts;
- Copilot/Cline checkpoint refs;
- stashes;
- the 16/09 backup dump;
- unreachable blobs;
- LIVE-only ledger entries;
- LOCAL_ONLY migration `20260919180000`;
- parallel-session migration `20260920010000`.

When LOCAL and LIVE disagree, record them as separate states until reconciliation.

---

# 9. Only next technical action authorized by this audit

Perform **one read-only LIVE audit of the identity/ownership onboarding chain**:

```text
auth.users
   ↓
on_auth_user_created
   ↓
private.handle_new_auth_user
   ↓
players.user_id
   ↓
register_guest_player
   ↓
players.id
   ↓
planets.player_id
```

Verify:

1. whether `on_auth_user_created` exists and is active in LIVE;
2. the LIVE body of `private.handle_new_auth_user`;
3. current distribution of `players.user_id`;
4. current AI / DevPlayer / guest distribution;
5. the LIVE body of `register_guest_player`;
6. whether that RPC creates, reuses or collides with an already-assigned player;
7. the effective chain used by frontend `resolvePlayer()`.

### Explicit restrictions

This audit must be:

**READ-ONLY.**

No:

- migrations;
- UPDATE/DELETE;
- ACL changes;
- RLS changes;
- cleanup;
- documentation edits;
- commits;
- pushes.

---

# 10. Product/architecture decision after F-01 verification

Only after the LIVE audit should the project decide between:

### Model A — controlled reassignment

An explicit pool/reassignment model for existing players.

### Model B — explicit guest creation

A `register_guest_player`-driven onboarding model in which a new authenticated user receives/creates the
intended guest player through the canonical ownership chain.

This is a product/architecture decision and must not be inferred solely from historical code.

---

# 11. Operational rules carried forward

1. A dirty tree created by another session is not reverted or cleaned by this audit.
2. Missing provenance is not reconstructed by invention.
3. LOCAL and LIVE are always classified separately.
4. ACL/RLS changes require LIVE verification first.
5. Suspected orphans require LIVE consumer verification before removal.
6. An audit is not an excuse for an unbounded refactor.
7. Work is performed in bounded phases.
8. CRITICAL identity/provenance issues are closed before opening additional engine domains.
9. Tests must verify behavior, not merely compilation.
10. Durable discoveries belong in specialized documentation; `PROJECT_CONTEXT_PROMPT.md` remains the compact
    operational control panel.

---

## Closing state

According to the supplied forensic report:

**No repository repair was performed by the forensic session.**

**LIVE was not modified.**

**The next authorized move is the read-only LIVE identity/ownership verification described above.**
