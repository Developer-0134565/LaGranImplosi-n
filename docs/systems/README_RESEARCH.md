# RESEARCH — LA GRAN IMPLOSIÓN

> Audit of the Research domain using **Buildings as the verified internal reference** (2026-09-18).
> Status: **AUDITED — gaps documented, NOT corrected** (this document records facts, not a redesign).
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

Grants: `start_research` → anon/authenticated/service_role · `can_research` → anon/authenticated ·
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

### Client-side contract defect (confirmed — NOT corrected)

Three **client-facing** helpers read that table and are **SECURITY INVOKER**:

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

DISPLAYED by the frontend today (src/App.tsx)
  getCost(d,'research')      = { metal: d.base_metal, crystal: d.base_crystal, deuterium: d.base_deuterium }
  getBuildTime(d,'research') = d.base_research_time_seconds
  · the definitions select does not even request cost_factor / time_factor
  · no research_speed, no evolution (√E), no level scaling, no item bonus
CONCLUSION: the backend is authoritative and correct; the UI figures are wrong from level 2 onward.
```

## 5. Queue / processing / catch-up / concurrency

```text
Start        start_research locks the player row (single research per player) and then the owned planet row.
Blocking     one active research per player: queue rows in RESEARCHING/QUEUED/ACTIVE block a new one
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
| cost | **CLIENT CALCULATED** (base values; no factor, level, speed or evolution) |
| time | **CLIENT CALCULATED** (base seconds; no factor, speed or evolution) |
| prerequisites | **MISSING** (`research_prerequisites` is never queried) |
| availability / disabling | **MISSING** (only `level >= max_level` and `busyId`) |
| action | REAL (`start_research` RPC; the backend rejects invalid requests with explicit errors) |
| queue display | REAL (`research_queue` RESEARCHING/QUEUED rows for the player) |
| completion refresh | DERIVED (the view reloads after an action; the heartbeat/catch-up completes due rows) |
| errors | REAL (raw Postgres error surfaced in the notice/error panel) |

## 8. Test plan (NOT implemented yet)

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
read model for the UI                → research_action_candidates view             → CONVERGED (but unused)
rich availability contract           → can_research is only a boolean subset       → GAP (fragmented)
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
1. Research lifecycle test (plan in §8) — required before Research can be certified.
2. Research UI: consume the authoritative contract (can_research + research_action_candidates, or a new
   consolidated contract) so cost, time, prerequisites and availability are real, as Buildings already does.
3. complete_research: evaluate SECURITY DEFINER + idempotent early return + `target = current+1` guard to
   align with complete_building (separate bounded migration).
4. Decide the fate of the duplicate `calculate_research_time(uuid,text,int)` overload.
5. Client availability contract: `can_research` / `check_research_requirements` / `get_research_requirements`
   are SECURITY INVOKER over the RLS-denied `research_prerequisites` → wrong/empty answers through the
   Data API (§1b). Decide the final architecture (DEFINER helpers vs one consolidated contract vs
   removing them from the client surface), then align the UI, the availability view and the tests.
   The test blind spot is already instrumented (§12.1); the decision itself is NOT started.
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

