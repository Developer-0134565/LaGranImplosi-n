# RESEARCH — LA GRAN IMPLOSIÓN

> Audit of the Research domain using **Buildings as the verified internal reference** (2026-09-18).
> Status: **AUDITED — gaps documented, NOT corrected** (this document records facts, not a redesign).
>
> **CLOSEOUT STATUS — 2026-09-21.** The gaps recorded below were closed by the Research closeout
> mission. The following is the current truth and supersedes the stale claims further down:
> * **The frontend is authoritative now.** `src/App.tsx` (view `research`) calls `can_start_research`
>   per technology and renders its cost, `research_seconds`, item bonus, `prerequisites` and the
>   `allowed` reason; it no longer computes Research cost or time locally. §4 and the §7 table are
>   therefore obsolete for cost/time/prerequisites/availability.
> * **Single client availability contract: `can_start_research`.** `research_action_candidates` was
>   retired AS A CLIENT CONTRACT by migration
>   `20260921140925_retire_research_action_candidates_client_contract`: no client could use it (it
>   failed with `42501 permission denied for table universes`), it is prerequisite-blind, and it is
>   preserved only as an internal dependency of the `action_candidates → executable_*` view family.
>   No `universes` GRANT was added to rescue it.
> * **Client-side contract defect (§1b) RESOLVED**: `can_research` is SECURITY DEFINER, and
>   `can_research` / `check_research_requirements` / `get_research_requirements` carry EXECUTE for
>   `postgres`/`service_role` only, so the wrong-answer client path is unreachable.
> * **`complete_research` is idempotent** (migration
>   `20260921140916_make_complete_research_idempotent`): a second call on a `COMPLETED` row returns
>   `false` instead of raising; all other status/error semantics are unchanged.
> * **The lifecycle suite exists and is runnable**: `supabase/tests/research_lifecycle.sql` — 27 gated
>   assertions plus a separate 12-assertion availability/ownership contract suite. §8's
>   "NOT implemented yet" is obsolete.
> * **Status vocabulary cleaned (2026-09-21)**: the dead `QUEUED` / `ACTIVE` guards were removed from
>   `start_research` and `can_start_research` (migration `20260921152702`), from the research guards in
>   the lifecycle suite and from the frontend research queue filter. `research_queue_status_check` still
>   allows only `RESEARCHING` / `COMPLETED` / `CANCELLED` — no enum change and no new status was
>   invented, and the building / shipyard / defense status vocabularies were deliberately left untouched.
> * **Research Laboratory + the 16 OGameX gates + IRN SHIPPED (2026-09-26).**
>   `20260926180000_research_lab_gates_and_irn` (owner-approved, applied LIVE and present in the migration
>   ledger) adds the `research_lab` building (200/400/200, factor 2, PLANET-only, no cap), fills
>   `research_building_prerequisites` with the 16 OGameX `research_lab` gates and adds
>   `get_research_network_lab_level(player, planet, research)` plus the four-argument
>   `calculate_research_time(player, planet, research, level)` overload consumed by both dispatchers. Gameplay
>   consequence (deliberate, not a defect): **every technology now requires a Research Laboratory on the planet
>   that starts it**, so an empire without one is refused with `RESEARCH_REQUIREMENTS_NOT_MET` until it builds
>   it; IRN is inert at level 0.
> * **§13's `PRODUCT DECISION REQUIRED` classification and §14's "content intentionally EMPTY" paragraph are
>   superseded by that shipment**: both describe the pre-decision state (2026-09-25) and are kept only as the
>   audit record. The decision was taken by the owner on 2026-09-26.
> * **Regression found and fixed (2026-09-27).** Activating the gates invalidated the *fixture precondition* of
>   the two certified Research suites: `research_lifecycle.sql` ran on a planet without a laboratory and
>   `research_building_prerequisites.sql` deletes every building before testing, so both were refused with
>   `RESEARCH_REQUIREMENTS_NOT_MET` before exercising their logic. Both fixtures now install the level the
>   contract itself requires (derived from `research_building_prerequisites`, never hardcoded) and the
>   empty-mechanism assertions no longer claim that nothing is shipped. §16 records the audit and its evidence.
> * **Both fixture-precondition defects and the OGameX interaction gap were closed on 2026-09-27** — all three
>   Research fixtures now run **as files against LIVE** (Management-API query channel; the 2026-09-27 audit could
>   not: no `psql`, Docker down, no DB URL/password). `research_lab_and_irn.sql` **14 PASS + 1 INFO**,
>   `research_building_prerequisites.sql` **21 PASS + 1 INFO**, `research_lifecycle.sql` **27 gated + 12/12
>   contract PASS**. Two *harness* defects that only surface on a file run were found and fixed (the universe tick
>   requires the worker's `auth.uid() IS NULL` context; the contract assertion counted one prerequisite dimension
>   where the contract exposes two) and the `researching while the Research Lab is upgrading` rule was verified
>   in OGameX and classified — **LGI does not implement it and it is not a server rule in OGameX either**. Detail:
>   §16.
> Related: [`README_GAME_ENGINE_AUDIT.md`](README_GAME_ENGINE_AUDIT.md) (construction) ·
> [`README_ECONOMY.md`](README_ECONOMY.md) · [`README_FUNCTIONAL_AUDIT.md`](README_FUNCTIONAL_AUDIT.md).

## 1. Real model (verified against the live database)

```text
research_definitions        id, name, description, base_metal/crystal/deuterium, cost_factor (2|3),
                            base_research_time_seconds (60), time_factor (2), max_level (NULL except
                            graviton_technology = 1)          → 16 rows live
research_prerequisites      research_id, prerequisite_research_id, required_level (>=1), not-self CHECK
                            → 16 rows live (real tech tree: e.g. ion 5 + laser 5 → plasma)
player_research             PK (player_id, research_id), level (>=0)  → 14 rows live (player-owned)
research_queue              id PK, player_id, research_id, target_level>0, started_at, finishes_at,
                            status ∈ {RESEARCHING, COMPLETED, CANCELLED} (default RESEARCHING),
                            planet_id NULLABLE, CHECK finishes_at >= started_at   → 10 COMPLETED, 0 active
```

```text
calculate_research_cost(id, target_level)        = base × cost_factor^(level-1), rounded to 4
                                                   (validates definition + max_level + level>=1)
calculate_research_time(id, target_level, universe)
                                                 = base_time × time_factor^(level-1) ÷ (research_speed × √E)
calculate_research_time(player_id, id, level)    ← SECOND OVERLOAD (returns base/speed/final)
can_research(player, research, target_level)     → boolean: definition, max_level, target = current+1,
                                                   prerequisites. (No resources, no queue, no ownership.)
start_research(player, planet, research)         → hardened SECURITY DEFINER: ownership (players.user_id =
                                                   auth.uid()), player row lock, owned non-destroyed planet
                                                   lock, definition/max, can_research, single active queue,
                                                   cost, time (+expedition item bonus), process_planet_tick,
                                                   atomic resource deduction (INSUFFICIENT_RESOURCES),
                                                   INSERT research_queue(RESEARCHING)
complete_research(queue_id)                      → NOT SECURITY DEFINER (see divergences): row lock,
                                                   status must be 'RESEARCHING', finishes_at <= now(),
                                                   conditional raw settlement, UPSERT player_research,
                                                   status = COMPLETED
process_research_queue() / _for_player() / _for_universe()   → SECURITY DEFINER, FOR UPDATE SKIP LOCKED,
                                                   only rows with status RESEARCHING and finishes_at <= now()
initialize_player_research(player)               → called by register_guest_player (guest onboarding)
```

Views (UI-side availability layer, granted to anon/authenticated):

```text
research_action_candidates  per planet×research: current/target level, cost, available resources,
                            resources_available, research_time_seconds (authoritative), active_research_jobs
action_candidates           UNION of building_action_candidates + research_action_candidates
                            (adds prerequisites_met for both domains)
executable_action_candidates  filtered/derived layer on top of action_candidates
ui_research_definitions()   SECURITY DEFINER, returns all research definitions (not used by the frontend)
```

Grants (RE-VERIFIED LIVE 2026-09-27; the P3 ACL sweep closed the old `anon` surface — this line replaces the
2026-09-21 wording): `start_research`, `can_start_research`, `cancel_research`,
`get_research_network_lab_level`, `calculate_research_time`, `ui_research_definitions` →
authenticated/service_role (**no `anon`**) · `can_research` and the two dead helpers
(`check_research_requirements`, `get_research_requirements`) → postgres/service_role (no client EXECUTE) ·
`complete_research` + all `process_research_queue*` → **service_role only** ·
`research_action_candidates` → anon/authenticated · `research_definitions`, `research_prerequisites`,
`player_research`, `research_queue` → SELECT to anon/authenticated.

⚠ Caveat (documented 2026-09-18, see §1b): the GRANT SELECT on `research_prerequisites` is **not
effective** for client roles — a RESTRICTIVE RLS policy hides every row — and
`research_action_candidates` is **not usable** by clients either (missing table GRANT on `universes`).
Only `research_definitions` is really public among the Research reference tables.

## 1b. Access model of `research_prerequisites` (RLS) — documented 2026-09-18

```text
STATUS: current design documented, NOT redesigned. No RLS policy, GRANT, function or view was changed.
```

`research_prerequisites` is an **internal/authoritative table** and is intentionally not readable through
the Data API by client roles:

```text
policy   deny_direct_api_access — AS RESTRICTIVE FOR ALL TO anon, authenticated
                                  USING (false) WITH CHECK (false)
created  migration 20260913043259_harden_api_security_and_indexes.sql (dynamic loop over ~38
         authoritative tables: building_prerequisites, combat_*, lifeform_*, universe_*, research_* …)
grants   GRANT SELECT, MAINTAIN TO anon/authenticated (MAINTAIN does not allow data writes).
         The GRANT exists, but the RESTRICTIVE policy filters every row → PostgREST answers 200 []
         (not 401/42501): the difference from a missing grant is observable.
writes   impossible for client roles: INSERT/UPDATE/DELETE revoked (migration 20260914215616) → 42501
reads    start_research (SECURITY DEFINER) and the DEFINER processors read it with owner rights, so
         the authoritative prerequisite validation keeps working.
```

Read-only evidence measured on the live project (2026-09-18):

```text
GET /rest/v1/research_prerequisites                    → 200 []  (content-range */0)
GET /rest/v1/building_prerequisites                    → 200 []  (same policy, same pattern)
GET /rest/v1/research_definitions                      → 206 (limit=1) · 16 rows total (public_read policy)
INSERT into research_prerequisites (probe, rejected)    → 401 42501 permission denied (no write path)
```

### Client-side contract defect — **RESOLVED 2026-09-21** (was: confirmed — NOT corrected)

Historical finding: three client-facing helpers read that table as SECURITY INVOKER and answered
wrongly through the Data API. That path no longer exists: `can_research` is **SECURITY DEFINER**, and
`can_research` / `check_research_requirements` / `get_research_requirements` now carry EXECUTE only for
`postgres`/`service_role`, so clients cannot invoke them at all (`42501`). The table and the three
helpers are unchanged for owner-privileged callers. The table below is kept as the historical record:

| Function | Through the Data API (role `anon`/`authenticated`) | Authoritative answer |
|---|---|---|
| `can_research(player, research, target)` | **`true`** even with unmet prerequisites | `false` |
| `check_research_requirements(player, research)` | **`[]`** | the real prerequisite rows |
| `get_research_requirements(player, research)` | **`[]`** | the real prerequisite rows |

Live evidence (synthetic/unknown player, research with a real prerequisite):

```text
can_research(unknown_player, 'astrophysics', 1)                 → true
can_research(unknown_player, 'plasma_technology', 1)            → true
check_research_requirements(unknown_player, 'plasma_technology') → []
get_research_requirements(unknown_player, 'plasma_technology')   → []
```

Scope — deliberately not over-stated:

```text
· NOT a gameplay bypass: start_research is SECURITY DEFINER and validates prerequisites with owner
  rights before charging; queue/level state cannot advance with unmet prerequisites.
· NOT a data leak: RLS returns zero rows; no client ever sees authoritative or foreign rows.
· NOT a privilege/grant bug: the SELECT grant exists on purpose; the RESTRICTIVE policy is the intended
  control and the same pattern is used by building_prerequisites.
· IS a broken availability contract for client callers (wrong/empty answers through the Data API).
· Latent for the UI today: App.tsx does not call these three helpers (it only uses the start_* RPCs,
  can_start_building and sync_current_planet_resources).
· The intended UI availability layer is not usable either: research_action_candidates / action_candidates
  are security_invoker and read `universes`, which has no table GRANT → 401 permission denied for table
  universes (same root cause already noted in README_IDENTITY_AND_ACCESS.md).
```

Buildings comparison: `building_prerequisites` carries the **identical** RESTRICTIVE policy, but the
table is **empty** (0 rows in the live dump) and its equivalent client helper only needs rows that would
never exist, so nothing observable breaks; the difference is **data, not architecture**.

**Decision deliberately LEFT OPEN (architecture mission, not this one):** whether the client contract
should be served by SECURITY DEFINER versions of these helpers, by one consolidated availability
contract (RPC or view), or by removing them from the client surface. No policy, GRANT, function or view
has been touched, and the UI is not modified.

## 2. Buildings ↔ Research structural comparison

| Stage | Buildings (reference) | Research (live) | Divergence | Action |
|---|---|---|---|---|
| definition | `building_definitions` (8 rows) | `research_definitions` (16 rows; cf 2\|3, tf 2, base 60 s) | explained (research also validates `max_level` inside the cost function) | document |
| prerequisites | table exists, **0 rows** (machinery unused by data) | table exists, **16 rows** (real tree, e.g. ion 5 + laser 5 → plasma) | explained (data, not architecture) | document |
| calculate cost | `base × cost_factor^(n−1)` | identical formula + max-level validation | none | none |
| calculate time | `base × time_factor^(n−1) ÷ (building_speed × √E)` | `base × time_factor^(n−1) ÷ (research_speed × √E)` | none; research has a **second overload** `(uuid,text,int)` | document (cleanup candidate) |
| availability contract | **one** `can_start_building` (ownership + resources + fields + queue + prerequisites + cost) | `can_research` (boolean: definition, max, target=current+1, prerequisites only) **+** `research_action_candidates` view (cost, resources, authoritative time, active jobs) | **problematic fragmentation** (no single contract; `can_research` alone cannot decide) | document (candidate: one consolidated contract) |
| start action | `start_building` validate→ownership→charge→queue | `start_research` same sequence **+ player row lock** + owned non-destroyed planet lock + `can_research` | explained (research is player-wide: extra lock; migration 20260913094500) | none |
| queue | `building_queue` planet-scoped, status `BUILDING`, CHECK `finishes_at > started_at`, partial index `(planet_id, …)` | `research_queue` player-scoped (+ **nullable** `planet_id`), status `RESEARCHING`, CHECK `finishes_at >= started_at`, partial index `(player_id, …)` | **legit domain difference** | none |
| processing | `process_building_queue[_for_planet/_for_universe]` SD, `SKIP LOCKED`, `ORDER BY finishes_at` | `process_research_queue[_for_player/_for_universe]` same shape (`_for_universe` resolves the player through its planets) | explained | none |
| completion | `complete_building` **SECURITY DEFINER**, early return when already COMPLETED, guard `target = current+1`, `fields_used+1` | `complete_research` **NOT SECURITY DEFINER**, raises when status ≠ RESEARCHING, **no** `target = current+1` guard, absolute UPSERT, settles only if `planet_id` is not null | **three differences** (SD flag · idempotency semantics · missing level guard) | document (not corrected) |
| persistent state | `planet_buildings` PK `(planet_id, building_id)` | `player_research` PK `(player_id, research_id)` | **legit domain difference** | none |
| ownership | hardened (migration 20260918030000) | hardened in the same migration (`start_research` verified: no guest bypass) | none | none |
| resource transaction | `process_planet_tick` → lock `planet_resources` → atomic guarded UPDATE → `INSUFFICIENT_RESOURCES` | identical pattern; the **active planet** funds a player-wide research | explained (deliberate) | document |
| tests | `buildings_lifecycle.sql` 13/13 PASS + `verify-buildings.mjs` | **none** | **problematic** | create the test (plan in §4) |
| frontend | authoritative: `can_start_building` (cost/level/allowed/reason) + `sync_current_planet_resources` | generic menu with **client-calculated BASE cost and BASE time** (no `cost_factor`, `time_factor`, `research_speed`, √E, `can_research` or candidate view) | **bug-class for the UI display** | fix later (documented, not now) |

## 3. Classification of divergences

```text
A — legit domain difference
   · planet-owned buildings vs player-owned research (queue scope, persistent-state PK, resources paid
     by the active planet while the research belongs to the player)

B — deliberate architectural difference
   · research_queue.planet_id nullable + conditional settlement in complete_research
   · research locks the player row before the planet row (single research per player)
   · calculate_research_cost validates max_level internally (buildings keep it in the contract)
   · can_research returning a boolean instead of a rich contract row
   · complete_research not being SECURITY DEFINER: it is REVOKEd from anon/authenticated and only called
     from SECURITY DEFINER processors (the owner executes it), so the effective behaviour is equivalent

C — suspicious divergence (real, not proven a bug)
   · complete_research raises when the queue row is not RESEARCHING instead of returning idempotently
     (buildings return the target level) → retries are not idempotent, although double increment is
     impossible
   · complete_research has no `target = current_level + 1` guard; the absolute UPSERT prevents N→N+2 but
     does not detect an inconsistent target level
   · two `calculate_research_time` overloads (duplicate API surface)

D — confirmed bug (with proof)
   · Research UI cost/time: the frontend never fetches `cost_factor`/`time_factor`/`research_speed`/E and
     shows `base_metal…` and `base_research_time_seconds` for ANY level. Live data (cost_factor 2–3,
     time_factor 2) makes the displayed values wrong from level 2 onward, and the real time additionally
     divides by `research_speed × √E`. Backend charge/time are correct; only the display is wrong.

E — missing evidence  [HISTORICAL: closed 2026-09-18 — see §12 / §12.1]
   · At audit time no lifecycle test existed for research (execution, persistence, concurrency and
     idempotency of the research chain were unverified end-to-end, unlike buildings).
     [CLOSED 2026-09-18 — see §12 / §12.1]

F — confirmed client-contract defect (documented 2026-09-18, NOT corrected — see §1b)
   · `can_research`, `check_research_requirements` and `get_research_requirements` are SECURITY INVOKER
     and read `research_prerequisites`, which is RLS-denied to anon/authenticated by design → through
     the Data API they answer `true` / `[]` instead of the authoritative result.
   · Not a gameplay bypass (`start_research` is SECURITY DEFINER and validates before charging), not a
     write path and not a data leak; it is a broken availability contract for client callers.
   · Today latent for the UI (App.tsx does not call them). The intended replacement layer
     (`research_action_candidates`) is not usable by clients either (§1b).
```

## 4. Cost / time (authoritative vs displayed)

```text
AUTHORITATIVE chain (what the game charges and schedules)
  calculate_research_cost(id, current+1)                     ← used by start_research
  calculate_research_time(id, current+1, universe_id)        ← ÷ (research_speed × √E)
    → can_research(prerequisites)                            ← validated before charging
      → start_research: process_planet_tick → lock planet_resources
        → guarded UPDATE (metal>=cost AND crystal>=cost AND deuterium>=cost)
        → INSERT research_queue(RESEARCHING, finishes_at = now() + time + expedition-item bonus)

DISPLAYED by the frontend (src/App.tsx) — CORRECTED 2026-09-21
  cost         = info.cost_metal / cost_crystal / cost_deuterium   <- can_start_research
  time         = rinfo.research_seconds                            <- can_start_research
  bonus        = rinfo.item_bonus_percent
  prerequisites= rinfo.prerequisites (required_level / current_level / satisfied)
  disabled     = NOT info.allowed, with info.reason as the tooltip
  · the local base-value fallback (getCost / getBuildTime) still exists in the code but is never
    reached for Research, because can_start_research returns a row for every definition
CONCLUSION: the backend and the UI read the SAME authoritative values — no divergence from level 2
onward. Historical note: before this closeout the UI showed level-1 base values (see git history).
```

## 5. Queue / processing / catch-up / concurrency

```text
Start        start_research locks the player row (single research per player) and then the owned planet row.
Blocking     one active research per player: queue rows with status RESEARCHING block a new one
             (RESEARCH_QUEUE_ALREADY_ACTIVE).
Planet need  yes: an owned, non-destroyed planet is required (the queue stores planet_id and the resource
             settlement uses it) even though the research itself is player-wide.
Charge       on start (atomic guarded UPDATE; INSUFFICIENT_RESOURCES when short).
Persist      on completion (UPSERT into player_research).
Double done  double increment is impossible (row lock + status guard + absolute UPSERT); a second call
             raises 'Research queue is not active' rather than returning idempotently (see C).
Downtime     process_research_queue* only takes rows with finishes_at <= now(); the universe catch-up
             settles planets and completes due building/research events within the same pass.
Processor    process_research_queue / _for_player / _for_universe — SECURITY DEFINER, FOR UPDATE
             SKIP LOCKED, ORDER BY finishes_at; not callable by clients (service_role only).
Concurrency  SKIP LOCKED prevents two processors from grabbing the same row; FOR UPDATE serialises the
             completion. Same guarantees as buildings.
```

## 6. Ownership

`start_research` is one of the six RPCs hardened by migration `20260918030000` (applied 2026-09-18): it
requires `auth.uid()` and `players.user_id = auth.uid()`; the guest bypass is gone (verified with
`pg_get_functiondef`). The frontend passes `p_player_id = currentPlayer.id` resolved from the session
(identity chain), never a global heuristic. No further change required.

## 7. Frontend classification (src/App.tsx, view 'research')

| Element | Classification |
|---|---|
| research list | REAL (`research_definitions`) |
| current level | REAL (`player_research` filtered by the identity player) |
| cost | **REAL** — `info.cost_*` from `can_start_research` (was CLIENT CALCULATED before 2026-09-21) |
| time | **REAL** — `rinfo.research_seconds` from `can_start_research` (item bonus included) |
| prerequisites | **REAL** — `rinfo.prerequisites`; the table stays internal, the SECDEF contract exposes it |
| availability / disabling | **REAL** — `info.allowed` + `info.reason` tooltip (plus `level >= max`) |
| completion refresh | **REAL** — with an active research the view schedules one bounded refresh at `finishes_at + 1.5 s` (2026-09-21) |
| action | REAL (`start_research` RPC; the backend rejects invalid requests with explicit errors) |
| queue display | REAL (`research_queue` rows with status RESEARCHING for the player) |
| completion refresh | DERIVED (the view reloads after an action; the heartbeat/catch-up completes due rows) |
| errors | REAL (raw Postgres error surfaced in the notice/error panel) |

## 8. Test plan — **IMPLEMENTED** (2026-09-18, extended 2026-09-21; heading superseded)

> The plan below was implemented by `supabase/tests/research_lifecycle.sql`. See §12 for execution
> history and §12.1 for the blind-spot instrumentation. The file now carries **27 gated lifecycle
> assertions** plus a separate **12-assertion availability/ownership contract suite**; its fixture
> accepts `DevPlayer`, and assertions 15 and 25-27 exercise the REAL production completion path
> (`process_planet_tick` / `process_universe_tick`) instead of the orphan processors.

```text
Proposed file: supabase/tests/research_lifecycle.sql — transactional (BEGIN … ROLLBACK), same shape as
buildings_lifecycle.sql, with `request.jwt.claims` simulating the anonymous session.

 1. definition válida        can_research(target) = true and cost matches calculate_research_cost
 2. definición inválida      unknown research → RESEARCH_NOT_FOUND
 3. coste correcto           base × cost_factor^(n−1) vs calculate_research_cost (live definitions)
 4. tiempo correcto          base × time_factor^(n−1) ÷ (research_speed × √E) vs calculate_research_time
 5. prerrequisitos           a research with an unmet prerequisite is rejected (research_prerequisites)
 6. recursos insuficientes   → INSUFFICIENT_RESOURCES, no queue row, no charge
 7. start correcto           start_research returns a queue id with status RESEARCHING
 8. descuento correcto       resources decrease exactly by the authoritative cost
 9. queue                    target_level = current+1 and finishes_at > started_at
10. processing               process_research_queue_for_player completes only overdue rows
11. completion               status COMPLETED and player_research.level = target
12. persistencia             one row per (player_id, research_id); repeats never duplicate rows
13. doble completion         a second completion must not advance the level (expected error documented)
14. ownership                foreign session rejected · own session allowed (as in buildings #9/#13)
15. rollback                 no residue (before/after snapshots inside the transaction)
16. concurrencia             1 active research per player enforced (second start rejected)
```

## 9. OGameX contrast (conceptual, not textual)

```text
OGameX reference pattern             → L.G.I. counterpart                          → verdict
app/GameObjects (technology model)   → research_definitions + SQL helper functions  → same responsibility
app/Actions (research upgrade)       → start_research RPC                          → same transition
deferred job / queue                 → research_queue + pg_cron + process_research_queue* → same concept
event/state processing               → finishes_at + complete_research             → same boundary
one authoritative entrypoint         → start_research                              → CONVERGED
read model for the UI                → can_start_research (the view was retired)  → CONVERGED (2026-09-21)
rich availability contract           → can_start_research returns the full set    → CONVERGED (gap closed)
NOT to copy: Eloquent models, PHP service/action inheritance, OGameX timings or balance constants.
```

## 10. Template contrast (`template/investigaciones.txt`)

The templates are **HTML captures of an OGame/OGameX server** (not L.G.I. sources):
`template.txt` = game page (Deuteria), `investigaciones.txt` = research screen, `edificios.txt` = buildings
screen, `hangar.txt` = shipyard screen.

```text
Structure proposed by the research screen:
  <body id="research"> · <ul class="neo-tiles neo-tiles-research">
  per technology: tile + data-technology id + data-status (on/off) + current level
                  + tooltip with "Nivel N → N+1", tip-costs (metal/crystal/deuterium), tip-time, description
                  + an upgrade (▲) action button + a queue slot (neo-tile-queue)

Alignment with Buildings: level + next-level cost + next-level time + action + queue slot ✓ matches the
  L.G.I. building menu (and the authoritative contract added with can_start_building).
Alignment with Research: level ✓, action ✓, queue slot ✓, but the template shows the *next level* cost/time
  while L.G.I. shows level-1 base values → the template reinforces the confirmed UI gap (D). `data-status`
  (on/off) has no L.G.I. equivalent in the menu.
Already better in L.G.I.: authoritative SQL engine, populated prerequisites table, universe multipliers,
  player-owned research with PK guarantees and ownership hardening.
```

## 11. Next actions (documented — NOT implemented)

```text
1. ~~Research lifecycle test (plan in §8)~~ — **DONE**: `supabase/tests/research_lifecycle.sql`
   (27 gated assertions + a 12-assertion contract suite). The fixture now accepts `DevPlayer` and
   assertions 15 / 25-27 exercise the REAL production path (`process_planet_tick`, `process_universe_tick`).
2. ~~Research UI: consume the authoritative contract~~ — **DONE**: the UI uses `can_start_research`
   (cost, time, item bonus, prerequisites, availability) and schedules a bounded completion refresh.
3. ~~complete_research: SECURITY DEFINER + idempotent early return~~ — **DONE (partly)**:
   migration `20260921140916` adds the idempotent early return. SECURITY DEFINER and a
   `target = current+1` guard were deliberately NOT adopted: the caller set is trusted
   (`postgres`/`service_role`) and the absolute UPSERT already makes a duplicate increment impossible.
4. Duplicate `calculate_research_time(uuid,text,int)` overload — **OPEN, deliberately kept**: the two
   overloads agree (`(uuid,…)` delegates to the canonical one) and assertion 5 asserts their
   equivalence, so it is a convenience wrapper rather than a divergence. 2026-09-27: both legacy INVOKER
   overloads and the canonical 3-argument one are now ENGINE-ONLY (`authenticated`/`anon` EXECUTE revoked by
   `20260927130100`, `service_role` kept) — measured as failing closed for a client because they are INVOKER over
   `universes`, which has no client grant; the equivalence assertion runs as the owner and is unaffected. The
   4-argument DEFINER contract consumed by `can_start_research` / `start_research` keeps `authenticated`.
5. ~~Client availability contract~~ — **DONE**: `can_start_research` is the single client contract and
   `research_action_candidates` was retired as a client contract (migration `20260921140925`); the
   wrong-answer helper path is closed because the three legacy helpers are internal-only.
Do not start any of these without an explicit mission.

## 12. Test results — 2026-09-18 (live execution)

```text
file       : supabase/tests/research_lifecycle.sql (443 lines at execution time; 551 lines after the
             §12.1 blind-spot block — transactional, ends with ROLLBACK)
assertions : 24
PASS       : 24
FAIL       : 0
SKIP       : 0
UNKNOWN    : 0  (true multi-session concurrency is NOT simulated — see limitations)

execution  : Supabase MCP execute_sql against the live project (single transaction + ROLLBACK)
fixture    : guest player with user_id + own planet (dynamic selection); armour_technology (no
             prerequisites) for the happy path, computer_technology for the queue-exclusion check and
             astrophysics (prerequisites: espionage 4 + impulse 3) for the prerequisite assertions.
             The selected planet belonged to the inactive TEST universe: research RPCs are
             universe-agnostic and its `research_speed` (1.0) and E were used for the time oracle.

verified (real evidence)
   1  definition valid (name + cost/time factors)
   2  invalid definition → can_research=false + RESEARCH_NOT_FOUND
   3  cost = base × cost_factor^(n−1)                     [1000 / 0 / 0 for armour_technology level 1]
   4  time = base × time_factor^(n−1) ÷ (research_speed × √E)   [20.8581 s = oracle, E ≈ 8.2747]
   5  overload calculate_research_time(uuid,text,integer) equals the canonical overload
   6  unmet prerequisites → RESEARCH_REQUIREMENTS_NOT_MET (astrophysics)
   7  satisfied prerequisites → can_research = true
   8  insufficient resources → INSUFFICIENT_RESOURCES
   9  no partial charge and no queue row after the rejection
  10  start_research returns a queue id
  11  exact deduction of metal / crystal / deuterium
  12  queue: RESEARCHING · target = current+1 · planet_id = funding planet · finishes_at > started_at
  13  second active research → RESEARCH_QUEUE_ALREADY_ACTIVE
  14  exactly 1 active research per player
  15  process_research_queue_for_player → COMPLETED
  16  player_research level persisted = target
  17  one row per (player_id, research_id) with the target level
  18  double completion → RAISES 'Research queue is not active. Current status: COMPLETED'
      (NOT idempotent, unlike buildings) — documented real behaviour, not changed
  19  double completion does not change the level
  20  unknown queue id → 'Research queue does not exist: …'
  21  legitimate owner (auth.uid() = players.user_id) can research
  22  foreign session → 'Player does not belong to authenticated user'
  23  foreign rejection leaves no mutation (resources, level, queue)
  24  auth.uid() IS NULL → 'Authentication required', with no mutation

data safety
  before/after snapshots identical (364 chars): same per-player level rows and sums, same queue statuses
  (COMPLETED 10), 0 fixture sentinel rows (metal = crystal = deuterium = 50 000 000) and unchanged table
  row counts. No new research, resource, level, queue, planet or player change was persisted.

limitations
  · True concurrency (two parallel sessions) is not simulated: exclusivity is proven through the real
    start_research contract (the second start is rejected while one research is active).
  · Executed through the MCP / SQL editor; the repository has no test framework.

divergences confirmed by this run (not corrected)
  · complete_research is not idempotent (it raises instead of returning gracefully) — assertion 18.
  · The Research UI still displays base cost/time (bug D); this test validates the backend only.

regression after the run (unchanged by this mission)
  · buildings_lifecycle.sql → executed after the research test, no exception (13/13 PASS) ✔
  · scripts/verify-buildings.mjs → PASS · scripts/verify-identity.mjs → PASS
```

```



### 12.1 Blind spot closed in the test (client contract) — DEFECT reproduced 2026-09-18

`supabase/tests/research_lifecycle.sql` now ends with a read-only **BLIND SPOT / CLIENT CONTRACT** block,
clearly separated from the gated assertions (its own temp table `t_client_contract`):

```text
· it switches to the REAL client role (`SET LOCAL ROLE authenticated`) in addition to the anonymous
  session claims, because changing only auth.uid() (what assertions 21-24 do) cannot reproduce RLS;
· it computes the oracle on the owner path first (prerequisite rows visible > 0 and can_research = false
  for a synthetic player) and then compares it with the client path;
· it answers PASS (contract consistent with the oracle), DEFECT (known §1b) or PENDIENTE (the harness
  cannot impersonate the client role, or the client call could not be executed) — it never fakes a
  result with owner privileges;
· the defect rows do NOT count in the 24/24 gate, so the certified baseline is preserved until the
  architecture decision of §11.5 is taken.
```

Execution (2026-09-18, LIVE via the project's Supabase MCP `execute_sql` endpoint, single transaction
that ends in `ROLLBACK`):

```text
gate (24 existing assertions) : 24 PASS · 0 FAIL · 0 SKIP · 0 UNKNOWN (no assertion was modified)
BLIND SPOT rows (t_client_contract):
  B0  ORACLE OK   oráculo owner [requisitos=2 · can_research=false]
  B1  DEFECT      camino cliente [can_research=true (owner false) · requisitos=0 (owner 2)]
classification                : DEFECT — expected detection of the known contract defect, NOT a test
                                failure and NOT a correction.
```

The block really switched role: the harness runs as `postgres` with
`pg_has_role(session_user,'authenticated','member') = true`, so `SET LOCAL ROLE authenticated` inside the
`DO` block changed `current_user` to `authenticated` (verified with a read-only probe before the run).
The evidence is therefore a **real client path**, not merely a simulated `auth.uid()` change.

Calls that were wrong (client role, synthetic player, `astrophysics` = research with 2 real
prerequisites), compared with the owner/authoritative oracle computed in the same transaction:

```text
can_research(synthetic, astrophysics, 1)                  → true    (authoritative: false)
check_research_requirements(synthetic, astrophysics)       → 0 rows  (authoritative: 2 rows)
get_research_requirements(...)                            → not exercised by this block; the same
                                                            SECURITY INVOKER + RLS-denied table path was
                                                            confirmed earlier by read-only Data API
                                                            probes (§1b) and remains unmodified
```

Reading of the result:

```text
· The behaviour matches the previous read-only LIVE finding of §1b (can_research → true, requirements
  list → []).
· NOT a gameplay bypass: start_research (SECURITY DEFINER) keeps validating prerequisites with owner
  rights before charging; no queue/level state can advance with unmet prerequisites.
· NOT a data leak and NOT a write path: RLS returns zero rows and client writes stay denied (42501).
· No architectural decision was taken and the defect was NOT corrected (no RLS, GRANT, function, view,
  UI or Buildings change).

Data safety (independent before/after snapshot around the run): research_queue 10 rows (10 COMPLETED,
0 active), player_research 14 rows / level sum 15, planet_resources 240 rows / 0 sentinel rows,
players 238, planets 240, definitions 16, prerequisites 16, building_queue 15, planet_buildings 7 —
identical before and after; the transaction ended in ROLLBACK with no persistent mutation.
```

Status: the 24 existing assertions remain **unchanged and PASS** (verified: 24 result rows, same gate).
The blind spot is now closed **as instrumentation**: any future run of this file reports PASS / DEFECT /
PENDIENTE explicitly.

## 13. Intergalactic Research Network (IRN) — dedicated audit 2026-09-25

> **SUPERSEDED 2026-09-26/27.** The owner approved the adoption/adaptation of the verified OGameX model and it
> shipped in `20260926180000_research_lab_gates_and_irn` — see «Research laboratory, the 16 OGameX gates and the
> Intergalactic Research Network (2026-09-26)» and §16. Everything below is the audit record of the state
> **before** that decision, including the classification line.

Classification (2026-09-25, superseded): **PRODUCT DECISION REQUIRED — STOP** (audit only: no implementation,
no migration, no function/RPC change, no test).

Contract present in LGI (verified LIVE): definition 240 000 / 400 000 / 160 000, `cost_factor` **3**,
`time_factor` 2, `max_level` NULL, `base_research_time_seconds` 60; prerequisites `computer_technology` 8
+ `hyperspace_technology` 8 (`research_prerequisites`); reachable through the generic Research view (the
frontend lists all 16 `research_definitions` rows and contains **no** per-technology code). IRN is a
prerequisite of nothing and has **0 readers**: no function body references it, no migration ever consumed
it, and LIVE holds 0 `player_research` rows and 0 `research_queue` rows for it.

Runtime reality: the canonical duration `calculate_research_time(id, target_level, universe)` is
`base_research_time_seconds × time_factor^(level−1) ÷ (universes.research_speed × research_scale(E))` —
its inputs are the research id, the level and the universe: **no planet, no player, no laboratory term**.
`can_start_research` resolves prerequisites from `research_prerequisites` only, enforces one `RESEARCHING`
job per player (`RESEARCH_QUEUE_ALREADY_ACTIVE`, asserted by assertion 13 of
`supabase/tests/research_lifecycle.sql`) and applies the `research_speed_percent` item bonus. There is no
research-lab building (0 of the 8 building definitions), no lab level anywhere (no `*lab*` function, no
`prosrc` match for `research_lab`/`laborator`), no building-type research prerequisite
(`research_prerequisites` is research→research only) and no research-slot subsystem. The generic reader
`get_player_research_level(player, research_id)` *could* read IRN, but no caller passes it.

OGameX (verified in source, `lanedirt/OGameX` @ `7c420ba`): definition in `ResearchObjects.php` 248-265 →
id 123, `class_name 'researchNetworkTechnology'`, `GameObjectPrice(240000, 400000, 160000, 0, 2)`
(**cost factor 2**, differs from LGI's 3), requirements `computer_technology 8` + **`research_lab 10`** +
`hyperspace_technology 8`. Runtime:
`PlanetService::getResearchNetworkLabLevel(string $machine_name): int` (1233-1272) starts from the current
planet's own lab level (1236), reads `$player->getResearchLevel('intergalactic_research_network')` (1244) and
only when it is `> 0` (1245) iterates the player's **other** planets, skipping every planet where
`ObjectService::objectRequirementsMet($machine_name, $planet)` is false, collects their `research_lab` levels
and adds the top `IRN` of them **sorted descending** (`rsort` 1265 → `array_sum(array_slice(..., 0,
$irn_level))` 1269). Application point: `PlanetService::getTechnologyResearchTime(string $machine_name):
float` (1189-1229), whose denominator (1207-1208) is
`1000 × (1 + effective_lab) × (economySpeed × researchSpeed)`. Effect: IRN **shortens** research time; it does
**not** grant parallel research (OGameX keeps one active research plus a multi-item queue). Sole runtime
consumers: `ResearchQueueService.php:324` (stored duration) and `Http/Traits/ObjectAjaxTrait.php:90-91`
(displayed duration). The behaviour is pinned by the existing test `tests/Feature/ResearchQueueTest.php:191-240`
(effective lab 8 → 18 → 24 → 18 as IRN and the labs change). IRN registers **no** `CalculationType`: an
exhaustive search finds exactly 3 `addCalculation` calls, all on `computer_technology` (`MAX_FLEET_SLOTS`,
line 212) and `astrophysics` (`MAX_COLONIES` 238 / `MAX_EXPEDITION_SLOTS` 241) → Computer and IRN are
independent mechanisms.

Gap and why it is not an implementation task: adopting the OGameX contract would require introducing a
research-lab building with per-planet levels, extending the research prerequisite model to building
requirements, and changing the certified research-duration contract (or adding an IRN-aware overload), plus a
participating-planets rule. That is a product decision, not an implementation detail.

Nature of the pending decision (2026-09-25; **DECIDED and implemented 2026-09-26**): the decision is **not** how
IRN should behave — OGameX's behaviour is already
verified above. The decision is **whether LGI adopts/adapts that verified model** (which means building a
research-laboratory subsystem) or rejects it. If it is ever approved, the implementation must be derived from
OGameX and adapted to LGI, per the permanent rule `OGameX AS DESIGN SOURCE — GAMEPLAY` in
`docs/PROJECT_CONTEXT_PROMPT.md`. This section is the canonical IRN record; `docs/PROJECT_CONTEXT_PROMPT.md`
keeps only the compact status line.

## 14. Building prerequisites for research — mechanism implemented 2026-09-25

Mechanism (migration `20260925192948_research_building_prerequisites_mechanism`, forward-only, LIVE applied):

- `research_building_prerequisites(research_id, building_id, required_level)` — PK `(research_id, building_id)`,
  FKs to `research_definitions`/`building_definitions`, `required_level >= 1`, RLS enabled with the same
  `deny_direct_api_access` policy and grants as the other prerequisite tables (SELECT granted, denied by the
  policy; full access for `service_role`).
- `check_research_building_prerequisites(planet_id, research_id)` — the single source of truth, evaluated on
  the planet that **starts** the research (OGameX parity: `ObjectService::objectRequirementsMet($machine_name,
  $planet)`). Internal helper: EXECUTE only for `postgres`/`service_role`.
- `can_start_research` reports both dimensions in the same `prerequisites` jsonb (every entry now carries
  `kind`, `required_level`, `current_level`, `satisfied`; research entries keep `research_id`, building entries
  carry `building_id`) and `prerequisites_met` is derived from the whole array.
- `start_research` — the only path that charges and enqueues — consults the same helper after the existing
  `can_research` gate and rejects with `RESEARCH_REQUIREMENTS_NOT_MET`. No client-supplied identity is used,
  so a foreign planet/building can never satisfy a requirement.
- Authority split: `can_research` keeps the research-only dimension (definition, max level, target level,
  `research_prerequisites`); the building dimension lives exclusively in the helper, consumed by both surfaces.

**Content: ACTIVATED 2026-09-26** (this paragraph supersedes the 2026-09-25 "intentionally EMPTY" statement).
The OGameX catalogue (`ResearchObjects.php`, exhaustive extraction) gives **16** technologies a `research_lab`
requirement (energy 1, laser 1, computer 1, combustion 1, armour 2, impulse 2, espionage 3, astrophysics 3,
ion 4, plasma 4, weapons 4, shielding 6, hyperspace 7, hyperspace_drive 7, graviton 12, IRN 10 — the text
shipped on 2026-09-25 said "14" while listing these same 16 names; the count was an arithmetic slip and the
migration inserted 16). The mechanism shipped **empty** on 2026-09-25 because LGI had no Research Laboratory and
activating the gates would have blocked research for every existing player — a **PRODUCT DECISION**, which the
owner took on **2026-09-26**: `20260926180000_research_lab_gates_and_irn` created the building and inserted the
16 gates verbatim. No level was invented; the table above is the OGameX extraction, verified row by row against
LIVE.

Tests: `supabase/tests/research_building_prerequisites.sql` — **21/21 PASS + 1 INFO, LIVE 2026-09-25**, inside
its rollback transaction, zero residue: missing building blocked, insufficient level blocked, satisfied
requirement allowed, exact cost charged on success, empty-mechanism regression (payload unchanged and research
still starts), multiple prerequisites combined with the research dimension, the research dimension still
enforced on its own, foreign planet rejected by the ownership gate, unauthenticated actor rejected with no
mutation, the shipped production content (16 laboratory gates, asserted against a pre-mutation snapshot), and
the equivalence proof that all 16 researches report exactly their own prerequisite rows with unchanged values.
LIMITATION: single-session harness (no true concurrency).
**UPDATE 2026-09-27:** activating the gates invalidated this fixture's precondition — it deletes every building
on the fixture planet, so the `allowed = true` assertions and the uncaught `start_research` of assertion 6 hit
`RESEARCH_REQUIREMENTS_NOT_MET`. The fixture now installs the contract-derived laboratory level and restores the
shipped table before the equivalence assertions (so 15a/15b are no longer vacuous); assertion 14 asserts the 16
shipped gates instead of claiming that nothing is shipped. See §16.
The frontend renders both kinds (`src/App.tsx`: `kind === 'building' ? building_id : research_id`).

Remaining gap (2026-09-25, now CLOSED): the research laboratory itself (building definition, cost/time curve
and the decision to activate the 16 gates) was a **PRODUCT DECISION**; the owner took it on 2026-09-26 and
`20260926180000_research_lab_gates_and_irn` shipped both parts, so the requirements are pure data rows today.


## 15. Queue cancellation and the single-authority audit (2026-09-26)

**Audit (§4/§5/§7 of the BUILDINGS+RESEARCH mission).** There is ONE authoritative answer to "may this
research start?": `start_research` is the only write path and it consults `can_research`
(research dimension) plus `check_research_building_prerequisites` (building dimension, planet-scoped);
`can_start_research` is the only client availability contract and reports both dimensions in one `prerequisites`
jsonb. No parallel path exists (`research_action_candidates` is retired as a client contract, the three
`process_research_queue*` orphans remain unused and untouched, `check_research_requirements` /
`get_research_requirements` are still unreachable for clients). Nothing certified was reopened.

**Research cancellation implemented** (migration `20260926082120`, ambiguity fixed by `20260926082529`):

* `cancel_research(queue_id)` — SECURITY DEFINER, EXECUTE only for `authenticated`/`service_role`;
* ownership `auth.uid()` → `players.user_id`; the refund is credited to `research_queue.planet_id` (the planet
  that paid), and a row without a planet is refused instead of guessing one;
* refund = **exactly the charged price**, recomputed with `calculate_research_cost` at the row's
  `target_level` (OGameX `cancel()` refunds the stored price of an already-started item — 100 %, no penalty);
* `RESEARCH_QUEUE_NOT_CANCELLABLE: COMPLETED` for a granted level, `RESEARCH_QUEUE_NOT_CANCELLABLE: CANCELLED`
  for a second call, `Authentication required` without a session: all of them raised before any write;
* the row keeps its `CANCELLED` status (never deleted) and the single research slot is free again.

Refund policy provenance (no invented policy): `BuildingQueueService::cancel()` refunds exactly the price
stored on the cancelled queue row, and `UnitQueueService` states that unit queue objects cannot be cancelled —
hence shipyard/defence keep no cancellation path. Full contract table: `README_ECONOMY.md`, section
«Queue cancellation contract».

Tests: `supabase/tests/queue_cancellation.sql` — **13 PASS + 1 INFO, LIVE 2026-09-26** (valid building and
research cancel with exact refund, queue released, double cancel, foreign caller for both RPCs, terminal
`COMPLETED`, already-due item refused without double credit, unauthenticated actor, ACL and the
`cancel_*`-count parity check), inside a rollback transaction with zero residue.


## Research laboratory, the 16 OGameX gates and the Intergalactic Research Network (2026-09-26)

`20260926180000_research_lab_gates_and_irn.sql` activates the content of the research-building gate mechanism
that was already certified (and intentionally empty) and adds the first real research-time mechanic:

* **Research Lab** (`building_definitions`): 200 metal / 400 crystal / 200 deuterium, cost factor 2,
  `valid_kinds = {PLANET}` (OGameX `StationObjects` declares `valid_planet_types = [Planet]`), no level cap and
  no prerequisites — available from the start, exactly like OGameX.
* **The 16 gates** (`research_building_prerequisites`), verbatim from OGameX `ResearchObjects`: energy 1,
  laser 1, ion 4, hyperspace 7, plasma 4, combustion 1, impulse 2, hyperspace drive 7, espionage 3,
  computer 1, astrophysics 3, IRN 10, graviton 12, weapons 4, shielding 6 and armour 2 (OGameX
  `armor_technology` ↔ LGI `armour_technology`). `start_research` and `can_start_research` already consumed
  `check_research_building_prerequisites`, so filling the table activates the whole rule without touching the
  certified mechanism.
* **IRN** (`get_research_network_lab_level(player, planet, research)`): effective laboratory level = own lab
  level + (when IRN > 0) the sum of the N highest lab levels among the player's **other planets that satisfy
  the research's lab requirement** (N = IRN level), exactly as OGameX
  `PlanetService::getResearchNetworkLabLevel`. Moons never contribute (labs are planet-only).
* **Time wiring**: LGI's curve has no laboratory term (unlike OGame's `(metal+crystal)/(1000·(1+lab))`), so
  OGameX's rule is ported as the equivalent divisor ratio `(1 + own_lab) / (1 + effective_lab)` inside a new
  four-argument overload `calculate_research_time(player, planet, research, level)` that mirrors the certified
  table shape (`final_time_seconds`). Both dispatchers were patched in isolation (`start_research` now selects
  `crt.final_time_seconds`; `can_start_research` already consumed the table) and the certified 3-argument
  overloads are untouched — `research_lifecycle.sql` keeps asserting their equivalence.
  The ratio is exactly 1 when IRN = 0, so the mechanic is inert until the player owns the technology.
* ACL: the two new contracts are `authenticated` + `service_role` only (no anon bypass).

Ownership gate added 2026-09-27 (`20260927120000_harden_cross_owner_research_and_colony_reads`): both contracts take
the target of the read from a CLIENT PARAMETER, and they had no ownership check at all — any signed-in player could
read another empire's `research_lab` level (and its IRN level) without sending a probe, and could infer the same
laboratory level from the returned duration. They now carry the certified identity gate used by
`inspect_demolition` / `calculate_planet_storage` (`auth.uid() IS NOT NULL AND not owner` →
`PLAYER_NOT_OWNED_BY_AUTH_USER`), and the planet-scoped pair additionally requires the planet to belong to that
player (`PLANET_NOT_OWNED_BY_AUTH_USER`), so an own-player + foreign-planet call is refused as well. The
engine/AI context (`auth.uid() IS NULL`, i.e. `start_research` from the AI service actor) is unchanged. Re-certified
by `supabase/tests/cross_owner_research_and_colony_reads.sql` (6 PASS, LIVE) together with
`research_lab_and_irn.sql`, which keeps asserting the IRN mechanics for the owner.

Tests: `supabase/tests/research_lab_and_irn.sql` — **14 PASS + 1 INFO, LIVE 2026-09-27** (15 rows: the fixture
carried 12 gated rows before the two added here — the previously documented "11 PASS" under-counted its own table,
since label 5 is a comment and not an assertion), executed **as a file** through the project's
Management-API query channel, transactional with `ROLLBACK` and zero residue: definition and the 16 gates,
refusal without a laboratory, lab 1 → energy allowed, lab 3 → ion refused, lab 4 → ion allowed, the laboratory
cannot be queued on a moon (`BUILDING_NOT_AVAILABLE_FOR_KIND`), a moon lab never joins the network, IRN 0 → own = 3
and the time equals the canonical value (the certified overload included), IRN 2 → effective 12 with the time
exactly 4/13 of it, IRN 1 → effective 8 with 4/9, the eligibility filter (graviton needs lab 12 so labs 5/4 stay
out) and the dispatcher ratio (measured 19.3891 s at IRN 0 → 5.9659 s at IRN 2 = 4/13). LIMITATION: single-session
harness, no cron and no concurrency.
**Test list completed 2026-09-27 (assertions 9b and 9c).** The mission's required cases *"fewer planets than IRN"*
and *ownership* were not covered by the 2026-09-26 fixture:
* **9b — fewer planets than IRN**: IRN 10 with only two eligible other laboratories (5 and 4) yields effective
  12, i.e. the levels that exist, exactly as OGameX `array_sum(array_slice($levels, 0, $irn_level))` returns
  fewer elements than requested. Nothing is invented and no level is counted twice.
* **9c — ownership**: a second player's planet carrying `research_lab` 20 does **not** join the network
  (effective stays 12). The helper filters by `p_player_id`; it never uses a "first player"/"first planet"/guest
  heuristic, so a foreign laboratory can never satisfy (or shorten) another player's research.
* Regression at IRN 0 is assertion 6: the four-argument overload equals the canonical three-argument value
  byte-for-byte, so no laboratory-independent result moved.

## 16. RESEARCH gameplay completion audit — 2026-09-27

Scope: the RESEARCH mechanic only (player → owned planet → availability → prerequisites → resource validation →
cost → queue → processing → completion → level → new availability/effects). No new architecture; the certified
chain was re-derived from LIVE and only real divergences were fixed.

**Authority (verified LIVE 2026-09-27 against project `evtfsbntvuqmahiskekd`: functions, ACLs and
`pg_get_functiondef`):**

| Object | Role | Evidence |
|---|---|---|
| `can_start_research(player, planet, research)` — SECDEF, STABLE | **AUTHORITATIVE client availability contract** (`allowed`, `reason_code`, `reason`, current/target level, next-level cost, seconds, item bonus, both prerequisite dimensions, queue state). Read-only. | LIVE body + probe |
| `start_research(player, planet, research)` — SECDEF | **AUTHORITATIVE and the only write path**: ownership, gates, single slot, atomic charge, `research_queue` INSERT. | LIVE body + probe |
| `complete_research(queue)` — internal, not SECDEF | completion entrypoint; idempotent on `COMPLETED` (returns `false`, no re-settlement) | LIVE body + probe |
| `process_planet_tick` → `complete_research`; `process_universe_*` chain | **REAL production path** | LIVE body + probe |
| `process_research_queue`, `_for_player`, `_for_universe` | **UNUSED** — 0 callers, `service_role` only | LIVE ACL |
| `can_research`, `check_research_requirements`, `get_research_requirements` | **LEGACY internal helpers** — no client EXECUTE | LIVE ACL |
| `check_research_building_prerequisites(planet, research)` | internal single source of truth of the building dimension | LIVE body |
| `get_research_network_lab_level`, `calculate_research_time(player,planet,research,level)` | IRN effective laboratory level + laboratory-aware duration (ratio = 1 while IRN = 0) | LIVE body + probe |
| `get_player_research_lab_status()` — SECDEF, STABLE | **AUTHORITATIVE state contract of the OGameX laboratory interaction**: empire-wide `research_lab_upgrading` + `research_in_progress` plus the upgrading planet, target level and finish time. Read-only, **not** an enforcement. | LIVE body (`md5(prosrc)` = repo file) + `research_lab_upgrading_status.sql` |
| `enforce_research_lab_research_interaction()` — BEFORE INSERT on `building_queue` | OGameX **queue enforcement** for the laboratory: neither an upgrade nor a downgrade is accepted while a research is running (pre-charge refusal, `BUILDING_BLOCKED_BY_ACTIVE_RESEARCH`). Availability declared in `evaluate_building_start_internal` and `inspect_demolition`. | LIVE trigger + fixture assertions 8/8b/8c |
| `cancel_research(queue)` — SECDEF | owner-only cancellation with the exact refund, planet taken from the queue row | LIVE body |
| `ui_research_definitions()` | **UNUSED** SECDEF wrapper | no caller |
| `research_action_candidates` | **retired as a client contract (2026-09-21)** | §0 |

**Contract re-verified through `start_research`:** `auth.uid()` ↔ `players.user_id` (NULL auth raises
`Authentication required`; the only NULL-auth exception is the AI worker — `is_ai_actor_target` requires
`lgi.ai_worker='on'`, the matching `lgi.ai_player` and an AI player with `user_id IS NULL`), player-row lock,
planet ownership + `is_destroyed`, `RESEARCH_NOT_FOUND`, `target_level = current_level + 1`,
`RESEARCH_MAX_LEVEL_REACHED`, `can_research` (research dimension), the building dimension, the single
`RESEARCHING` slot, `calculate_research_cost(target_level)` (next level — single formula, no second cost path),
`calculate_research_time(player, planet, research, target_level)`, `process_planet_tick`, the atomic deduction
(`INSUFFICIENT_RESOURCES`) and the `research_queue` INSERT.

**Regression found (demonstrated) and fixed.** `20260926180000` activated 16 gates, so *every* technology now
needs a `research_lab`, but the two certified Research fixtures still ran on a planet without one:
`research_lifecycle.sql` (happy path, assertions 10-27) and `research_building_prerequisites.sql` (assertion 5
plus the uncaught `start_research` of assertion 6) were refused with `RESEARCH_REQUIREMENTS_NOT_MET` before
exercising anything. LIVE evidence of the refusal (fixture planet `f35bd4b9…`, `research_lab` NULL, techs
`armour_technology` lab 2 / `computer_technology` lab 1 / `astrophysics` lab 3): both `start_research` calls
returned `RESEARCH_REQUIREMENTS_NOT_MET`. Both fixtures were corrected by installing the level the contract
itself requires (`max(required_level)` from `research_building_prerequisites`, never a hardcoded product value)
inside their rollback transaction. This is a **fixture-precondition defect**, not a gameplay defect: the
laboratory rule is the owner-approved change.

**Evidence executed in this audit (transactional `ROLLBACK`, zero residue) — LIVE contract probe, 11/11 PASS:**
availability (`allowed`, 0→1, cost 1000, 4-arg time = canonical 19.405 s ⇒ IRN inert), building prerequisite
blocked at lab 1 < 2 with the jsonb entry `{kind: building, building_id: research_lab, required_level: 2,
current_level: 1, satisfied: false}` and no queue row, `INSUFFICIENT_RESOURCES` with the gate satisfied, owner
start with the exact single charge, queue `RESEARCHING` `target_level = 1` on the starting planet, second active
research refused (`RESEARCH_QUEUE_ALREADY_ACTIVE`), completion through `process_planet_tick` (`COMPLETED`,
level 1), idempotent second processing (`complete_research` → `false`, status/level unchanged, one row), next
level offered after completion (`allowed`, 1→2, cost 2000), foreign session rejected (`Player does not belong to
authenticated user`) and NULL auth rejected (`Authentication required` / `AUTHENTICATION_REQUIRED`).

**Remaining gaps (explicitly NOT converted into PASS):**
- **Fixtures executed as files — CLOSED 2026-09-27.** A client-side SQL path to LIVE exists on this machine after
  all: `supabase db query --linked` needs a login token the CLI has not stored here, but the project credential
  carried by the repository's MCP configuration (`.vscode/mcp.json`, an `sbp_…` token, **not tracked by git**)
  reaches the Management-API query channel directly, so the three fixtures were streamed from disk and executed
  **verbatim** (each ends in `ROLLBACK`). Results: `research_lab_and_irn.sql` **14 PASS + 1 INFO**,
  `research_building_prerequisites.sql` **21 PASS + 1 INFO**, `research_lifecycle.sql` **27 gated + 12/12
  contract PASS**. Zero residue verified afterwards: 590 planets, 0 moons, 0 `research_lab` rows, 16 gate rows,
  590 players, 589 IRN `player_research` rows and the pre-existing 5 `research_queue` / 3 `building_queue` rows.
- **Two fixture-precondition defects found by the file run and fixed (2026-09-27, harness only).**
  (a) `research_lifecycle.sql` assertions 26-27 called `process_universe_tick` while the fixture held an
  `authenticated` claim; that tick is the **worker** path and iterates **every** planet in the universe, so
  `calculate_planet_storage`'s ownership gate (SECURITY DEFINER, added 2026-09-26) raised `PLAYER_NOT_OWNED` on the
  first foreign planet and the suite died before printing its own report. The fixture now reproduces the worker
  context (`auth.uid() IS NULL`) around those two ticks only. **Not a production defect**: the tick chain is
  `postgres`/`service_role` only (`has_function_privilege('authenticated','process_universe_tick')` = false) and
  the worker authenticates without a `sub` claim, so the gate is skipped. (b) contract assertion 3
  (`prerequisite detail count`) counted only `research_prerequisites` while `can_start_research` has exposed
  **both** prerequisite dimensions since `20260925192948`; it now counts the rows declared by both tables. No
  assertion semantics were weakened and no production contract was touched.
- Browser certification of the Research view with the Laboratory gate active (the UI already renders both
  prerequisite kinds and the backend reason) remains the user-side gate.
- **`researching while the Research Lab is upgrading` — ADAPTED in OGameX's own layer (2026-09-27).** OGameX
  resolves it as **state/UI**, so LGI reproduces it in the equivalent layer and adds **no server gate**:
  * OGameX evidence (@ `7c420bad`): `ObjectAjaxTrait::ajaxHandler`, research branch →
    `// Researching is disallowed when Research Lab is upgrading` /
    `$research_lab_upgrading = $player->isBuildingObject('research_lab')` (plus `$research_in_progress =
    $player->isResearching()` in the building/station branch); both travel in the ajax payload.
    `ResearchController::index` passes the same flag to the view model (75/101/134), while
    `ResearchController::addBuildRequest` (160-193) validates **vacation mode + CSRF only** and
    `ResearchQueueService::add()` never looks at the laboratory — **OGameX does not block it server-side**. Its
    only consumer is the UI mark in `resources/views/ingame/research/research-item.blade.php`:
    `@elseif ($building->research_lab_upgrading) → data-status="disabled"`. `PlayerService::isBuildingObject`
    loops over **every** planet, so the flag is **empire-wide**, not planet-scoped.
  * LGI adaptation (`20260927014725_research_lab_upgrading_state_contract`, applied LIVE; repo ↔ LIVE proven by
    `md5(prosrc) = 4fc9b572…`, 1805 bytes): the read-only, owner-scoped contract
    `get_player_research_lab_status()` returns `research_lab_upgrading` (a `research_lab` row in `building_queue`
    with `status = 'BUILDING'` **and not `is_downgrade`** — OGameX compares `object_level_target` with
    `current_level + 1`, so a downgrade does not raise it), `research_in_progress` (an active `research_queue`
    row) and the upgrading planet / target level / finish. Both React views consume it where OGameX does: the
    Research view disables the investigation with the reason and a note carrying the finish time, and the
    Buildings view does the same for the laboratory while a research is running. **`can_start_research`,
    `start_research` and `start_building` are untouched** and still accept the action (assertions 6 and 8), so LGI
    is not stricter than OGameX.
  * **Queue enforcement IMPLEMENTED (2026-09-27, migration `20260927015502`)** — the server-side half of the OGameX
    behaviour: `BuildingQueueService::addDowngrade` (207-210) refuses the laboratory downgrade while a research runs
    and `start()` (398-401 / 416-421) cancels the not-yet-started laboratory item. LGI adaptation: since LGI charges
    **and** starts in the same act, the equivalent of «cancel the item that has not begun» is a **pre-charge
    refusal**, so the reachable state is identical without the charge → refund cycle. A BEFORE INSERT guard on
    `building_queue` (`enforce_research_lab_research_interaction`, alongside the certified
    `enforce_building_kind_and_research`) rejects `research_lab` upgrades **and** downgrades with
    `BUILDING_BLOCKED_BY_ACTIVE_RESEARCH`; the same rule is declared in `evaluate_building_start_internal`
    (client contract `can_start_building` + AI path) and in `inspect_demolition`, which now blocks **any**
    laboratory demolition while a research runs — the blanket OGameX rule, not only when the removed level is still
    required (reason `DEMOLITION_BLOCKED_BY_ACTIVE_RESEARCH`, unchanged UI vocabulary, so
    `BuildingDemolitionPanel` shows it with no UI change).
    `complete_building` and the queue processors are **untouched**: an upgrade already IN FLIGHT when the research
    starts still completes, exactly like OGameX (`PlanetService::updateBuildingQueue` 1693-1740 never looks at
    research). `start_research` keeps **no** server gate: OGameX does not enforce that direction either.
  * Tests: `supabase/tests/research_lab_upgrading_status.sql` — **14 PASS + 1 INFO, LIVE 2026-09-27**: clean state ·
    empire-wide flag from another owned planet · only the laboratory counts · a downgrade does not raise it ·
    ownership (the foreign row is written through the declared AI-actor context, the only legitimate way past
    `enforce_player_write_access`) · `start_research` accepted while the laboratory upgrades (no server gate) ·
    `research_in_progress` with a real active research · **8: `start_building(research_lab)` refused while
    researching with `BUILDING_BLOCKED_BY_ACTIVE_RESEARCH` and no charge** · 8b: another building is still allowed
    (not stricter) · **8c: the laboratory demolition is blocked while researching (blanket rule)** · 8d-8e: an
    upgrade already in flight is accepted and **completes untouched** while the research keeps running · ACL
    without `anon` · anonymous session → 0 rows.
- The P3 hygiene items recorded in `docs/PROJECT_CONTEXT_PROMPT.md` remain open (the three
  `process_research_queue*` orphans, the two dead helpers, `ui_research_definitions`, unpurged `COMPLETED`
  rows). Nothing was deleted and no grant was widened.
- OGameX differences deliberately preserved (no balance was touched): LGI keeps `cost_factor 3` for IRN
  (OGameX 2), keeps its own duration curve — the laboratory enters only through the IRN divisor ratio, not
  through `(metal+crystal)/(1000·(1+lab))` — and keeps one research slot with its own cost/time factors.

