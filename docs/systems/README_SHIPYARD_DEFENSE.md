# SHIPYARD + DEFENCE ENGINE — LA GRAN IMPLOSIÓN

## Scope

Durable detail for the Shipyard and Defence production queues. This document covers the
current V1 single-planet production model only.

Lifeforms are outside this certification. ACS/HOLDING/DEFEND multi-participant gameplay is
outside this certification boundary.

## Canonical lifecycle

```text
Definition + prerequisites
        ↓
can_build_ship() / can_build_defense()
        ↓
start_ship() / start_defense()
        ↓
resource deduction + queue row (BUILDING)
        ↓
process_shipyard_queue() / process_defense_queue()
        ↓
planet_ships / planet_defenses
        ↓
COMPLETED
```

Both domains use server-side cost/time/availability contracts. The frontend consumes
can_build_ship() and can_build_defense() for actionable cost, time, availability and
reason; definition metadata remains presentation-only.

## LIVE entrypoint contract

### Shipyard

- can_build_ship(uuid, uuid, text, bigint) returns authoritative allowed, reason, costs
  and build_time_seconds. **CLOSED 2026-09-22** — SECURITY DEFINER, owner `postgres`,
  `search_path = public, pg_temp`, identity gates (`AUTHENTICATION_REQUIRED`, `PLAYER_NOT_OWNED`)
  and `EXECUTE` only for `authenticated`/`service_role` (migration `20260922050734`). Detail: below.
- start_ship(uuid, uuid, text, bigint) is SECURITY DEFINER, requires non-NULL auth.uid(),
  requires players.user_id = auth.uid(), validates planet ownership, requirements and
  resources, then inserts shipyard_queue(status='BUILDING').
- process_shipyard_queue(uuid) consumes due BUILDING rows and UPSERTs planet_ships; the
  queue row becomes COMPLETED.
- start_ship() settles the planet tick before measuring/deducting resources.

### Defence

- can_build_defense(uuid, uuid, text, bigint) returns authoritative allowed, reason, costs
  and build_time_seconds.
- start_defense(uuid, uuid, text, bigint) is SECURITY DEFINER, requires non-NULL auth.uid(),
  requires players.user_id = auth.uid(), validates planet ownership, requirements and
  resources, then inserts defense_queue(status='BUILDING').
- process_defense_queue(uuid) consumes due BUILDING rows and UPSERTs planet_defenses; the
  queue row becomes COMPLETED.
- Shield-dome uniqueness is enforced by the authoritative defense contract/entrypoint.

## CLIENT CONTRACT — closeout 2026-09-22 (migration `20260922050734`)

### Defect measured LIVE (not inferred from a README)

`can_build_ship` was the **last** availability contract still declared `SECURITY INVOKER` while its
dependencies are intentionally not client-executable:

```text
check_ship_requirements(uuid,text)     ACL = postgres / service_role only
calculate_ship_build_time(uuid,text)   SECURITY INVOKER -> reads public.universes,
                                       which has NO SELECT grant for client roles
```

Measured through the real client role (`SET LOCAL ROLE authenticated` + `request.jwt.claims`):

```text
authenticated owner   can_build_ship(...)          -> ERROR 42501 permission denied for function check_ship_requirements
anon                  can_build_ship(...)          -> ERROR 42501
authenticated         can_build_defense(...)       -> allowed = true   (already fixed)
authenticated         can_start_research(...)      -> allowed = true   (already fixed)
authenticated         calculate_ship_build_time(..)-> ERROR 42501 permission denied for table universes
```

So the Shipyard view could never obtain authoritative availability, and `App.tsx` threw while loading it.

### Second defect found in the same function

`can_build_ship` had **no identity gate at all** (unlike `can_build_defense` / `can_start_research`).
Because it only checked `planets.player_id = p_player_id` with a client-supplied player id, making it
`SECURITY DEFINER` without adding gates would have converted it into a **foreign-player oracle**: its
`reason` reflects another player's building/research levels. Both defects were closed together, because
fixing the first is what would have created the second.

### Contract now

```text
can_build_ship(p_player_id, p_planet_id, p_ship_id, p_quantity)
   -> allowed, reason, ship_id, quantity, costs, build_time_seconds
  SECURITY DEFINER · STABLE · owner postgres · SET search_path = public, pg_temp
  gate 1  auth.uid() IS NULL                          -> false, 'AUTHENTICATION_REQUIRED'
  gate 2  players.id = p_player_id AND players.user_id = auth.uid()  -> else 'PLAYER_NOT_OWNED'
  gate 3  quantity > 0                                -> 'Quantity must be greater than 0'
  gate 4  planet owned by p_player_id and not destroyed -> 'Planet does not belong to player'
  then    prerequisites -> costs -> available resources -> authoritative build time
```

Verified LIVE (identical shape to `can_build_defense`):

```text
pg_proc.proacl = {postgres=X/postgres,service_role=X/postgres,authenticated=X/postgres}
anon EXECUTE = false · authenticated EXECUTE = true · service_role EXECUTE = true
exactly ONE pg_proc definition for the name
```

### Nothing was widened

```text
public.universes              anon/authenticated SELECT  = false  (unchanged)
check_ship_requirements       anon/authenticated EXECUTE = false  (unchanged)
process_shipyard_queue        anon/authenticated EXECUTE = false  (unchanged)
```

`calculate_ship_build_time` keeps its current PUBLIC `EXECUTE`. It is `SECURITY INVOKER` and fails for
clients (`universes`), i.e. a **dead client surface**, exactly like `calculate_defense_build_time` and
`check_defense_requirements`. Recorded as deferred P3 hygiene (Defence-parity class), deliberately not
changed by this mission.

## SECURITY model (Shipyard + Defence)

```text
auth.uid() -> players.user_id -> players.id -> owned planet -> planet_ships / planet_defenses
```

- Every entrypoint (`start_ship`, `start_defense`) and every availability contract (`can_build_ship`,
  `can_build_defense`, `can_start_research`) is `SECURITY DEFINER` with a fixed `search_path`, an explicit
  `auth.uid()` check and an explicit ownership check.
- No `is_guest` branch exists in `start_ship` / `can_build_ship`; client-supplied identity is never trusted.
- `start_ship` / `start_defense` remain unreachable for `anon` (EXECUTE denied).

## PRODUCTION CHAIN (verified LIVE, 2026-09-22)

```text
pg_cron job 'universe-heartbeat'  (* * * * *)
  -> process_universe_heartbeat()            SECURITY DEFINER
      -> process_universe_clock(universe)
          -> process_universe_tick(universe)
              -> process_fleet_movements()
              -> process_planet_tick(planet)      completes building_queue / research_queue
                  -> process_planet_tick_local(planet)
                      -> update_planet_resources_until(planet, now())
                      -> process_lifeform_tick(planet)
                      -> process_shipyard_queue(planet)   <-- SHIPYARD completion
                      -> process_defense_queue(planet)    <-- DEFENCE completion
```

The `process_universe_clock` link is real and was measured in LIVE; the shorthand
"heartbeat -> universe_tick" omits it. Shipyard needs **no** dedicated worker: the universal tick already
drives it, and the fixture proves one completion end-to-end through `process_universe_tick`
(`COMPLETED` + `planet_ships` incremented).

## FRONTEND contract (source-verified; NOT browser-certified)

```text
cost / time / allowed / reason  <- productionInfo (authoritative can_build_ship / can_build_defense) ONLY.
                                   No fallback to ship_definitions.base_* metadata: a missing contract
                                   renders '—' plus 'Disponibilidad no disponible', never an invented value.
button disabled                 <- unless info.allowed is true (missing contract => disabled)
completion refresh              <- ONE bounded setTimeout at finishes_at + 1500 ms, cleared on cleanup;
                                   no polling, no setInterval. Extended to the Shipyard view
                                   (was research/defence only).
dead state                      <- the shipyard_queue filter no longer requests 'QUEUED'
                                   (shipyard_queue.status admits BUILDING/COMPLETED/CANCELLED only).
display                         <- the ship/defence effective time is labelled TIEMPO: it is the
                                   authoritative, shipyard-level-scaled value, not the base one.
```

`ship_definitions.base_*` metadata is presentation-only and is no longer substituted for the authoritative
contract in the Shipyard/Defence views. `defence_queue` and `building_queue` keep their historical filter
shape on purpose: this closeout was scoped to the Shipyard.

## Transactional certification — 2026-09-19

Test file:

supabase/tests/shipyard_defense_lifecycle.sql

The fixture runs inside BEGIN … ROLLBACK and therefore leaves no persistent state.

**LIVE result: 12/12 PASS.** *(historical label)*

> **Correction 2026-09-22:** the fixture already contained **15** assertions (1–12 plus the three Defence
> client-role checks 13–15 added 2026-09-21), so the "12/12" label undercounted the suite. It now contains
> **25** assertions and the measured result is **25/25 PASS** (see below).

Coverage:

1. can_build_ship() allowed path and authoritative cost/time.
2. can_build_defense() allowed path and authoritative cost/time.
3. start_ship() creates BUILDING queue and deducts exact authoritative cost.
4. process_shipyard_queue() completes the queue and persists the ship.
5. A second shipyard processor pass does not reprocess the completed row.
6. start_defense() creates BUILDING queue and deducts exact authoritative cost.
7. process_defense_queue() completes the queue and persists the defence.
8. A second defence processor pass does not reprocess the completed row.
9. start_ship() rejects NULL authentication.
10. start_defense() rejects NULL authentication.
11. start_ship() rejects a foreign authenticated owner.
12. start_defense() rejects a foreign authenticated owner.

The first run exposed only a test-harness measurement issue: start_ship() settles the pending
planet tick internally, so the exact resource delta must be measured immediately after an explicit
process_planet_tick() synchronization. The corrected fixture was rerun LIVE and passed 12/12.
No gameplay code change was required for this observation.

## Certification — Shipyard closeout 2026-09-22

```text
ENGINE              CLOSED / VERIFIED LIVE   V1 single-planet lifecycle (unchanged)
CLIENT CONTRACT     CLOSED / VERIFIED LIVE   can_build_ship: bounded definer + identity gates
SECURITY            CLOSED / VERIFIED LIVE   ACL {postgres,service_role,authenticated}; anon denied;
                                             universes and check_ship_requirements still closed
TEST                CLOSED / VERIFIED LIVE   supabase/tests/shipyard_defense_lifecycle.sql -> 25/25 PASS
FRONTEND            SOURCE VERIFIED          App.tsx compiles; browser certification PENDING
BROWSER VERIFICATION  NOT DONE               explicit manual checklist below
```

New assertions 16–25 (added 2026-09-22, all PASS):

| # | Assertion |
|---|---|
| 16 | `can_build_ship` executable by the REAL client role (`authenticated`) → `allowed`, `reason='OK'` |
| 17 | `can_build_ship` is not a foreign-player oracle → `PLAYER_NOT_OWNED` |
| 18 | `can_build_ship` with no session (`auth.uid()` null) → `AUTHENTICATION_REQUIRED` |
| 19 | `can_build_ship` as `anon` → `42501` (no EXECUTE) |
| 20 | contract cost/time equals an independent oracle (`calculate_ship_cost` + `calculate_ship_build_time`), 4 decimals |
| 21 | the internal dependencies are still closed (`check_ship_requirements` EXECUTE, `universes` SELECT) |
| 22 | **real chain completion**: `process_universe_tick` → `COMPLETED` + `planet_ships` incremented |
| 23 | structural chain present: cron `universe-heartbeat` → `universe_clock` → `universe_tick` → `planet_tick` → `planet_tick_local` → `shipyard_queue` |
| 24 | `process_shipyard_queue` still closed to client roles |
| 25 | `shipyard_queue.status` does not admit the dead `QUEUED` state |

Assertion 22 uses the project's established mechanism (advance `finishes_at`, then run the real tick) —
the same one used by the certified Research suite. It is **not** a direct `process_shipyard_queue` call
(that path is separately covered by assertions 4 and 5).

## Certification boundary

Backend lifecycle, client availability contract, security model and tests are now
**CLOSED / VERIFIED LIVE** for the current V1 single-planet Shipyard + Defence model.

Still OPEN:

- **Browser certification** of Shipyard and Defence (see the checklist below).
- **P3 hygiene (deferred, not part of this closeout):** `calculate_ship_build_time` /
  `calculate_defense_build_time` / `check_defense_requirements` keep a PUBLIC `EXECUTE` that can never
  succeed for clients (`universes` is not granted; `check_ship_requirements` is already closed).
  Harmless dead surface, same class in both domains.
- **`buildings_lifecycle.sql` is runnable again (2026-09-22):** its fixture required a HUMAN player
  *other than* DevPlayer, and DevPlayer is the only HUMAN with an auth user, so it aborted by design. The
  selector was aligned with the certified Research/Shipyard pattern (prefer a non-DevPlayer HUMAN, fall back
  to DevPlayer); no assertion was relaxed. A rollback-safe equivalent probe first confirmed the suite passes
  its own gate once that exclusion is lifted, so the blocker was the selector, not the environment. See the
  Buildings/Temporal documentation for its own certification status.

Browser checklist (must be executed by the user):

1. open Shipyard — every card must show authoritative cost/time, no `—` and no error banner;
2. verify a card with an unmet prerequisite shows `reason` and a DISABLED button;
3. start a ship — queue row appears, resources drop by the authoritative cost;
4. keep the tab open past completion — ONE automatic refresh, no polling, countdown does not loop;
5. verify the ship appears in inventory and the queue row disappears (status `COMPLETED`);
6. reload the page — persisted state unchanged;
7. repeat 1–6 for Defence;
8. while offline/denied (e.g. simulate a failing contract), the Shipyard must show
   `Disponibilidad no disponible` and DISABLED buttons — never base cost/time.

No Lifeforms or ACS/HOLDING/DEFEND implementation is implied by this closure.
