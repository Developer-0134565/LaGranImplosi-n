# DEFENSE ENGINE — LA GRAN IMPLOSIÓN

> Living document for the Defense production mechanic (planet-bound, count-based).
> Status: **CORE ENGINE CLOSED / VERIFIED LIVE — 2026-09-21**, after the Defense closeout.
> Combat consumption is a separate, still-open CORE dependency (see §7).

## 1. Scope

This document covers the **current CORE Defense mechanic**: definitions, cost, build time,
prerequisites, availability, start, queue, production completion and persisted state.

Out of scope and deliberately untouched: Lifeforms, Items, Auction, Merchant, Alliance,
Officers/Premium (all future **UPDATE** features), the Combat Engine itself, and the Fleet /
Research / Shipyard engines.

## 2. Canonical lifecycle

```text
defense_definitions + defense_prerequisites
        ↓
can_build_defense(player, planet, defense, quantity)     <- authoritative availability
        ↓
start_defense(player, planet, defense, quantity)         <- SECURITY DEFINER
        ↓
process_planet_tick  (settle pending building/research work)
        ↓
atomic resource charge  +  defense_queue row (status='BUILDING')
        ↓
process_defense_queue(planet)   <- reached by the planet tick / heartbeat chain
        ↓
planet_defenses UPSERT (quantity += n)  +  queue row -> 'COMPLETED'
```

## 3. LIVE objects (verified 2026-09-21)

| Object | Notes |
|---|---|
| `defense_definitions` (**8** rows) | rocket_launcher, light_laser, heavy_laser, gauss_cannon, ion_cannon, plasma_turret, small_shield_dome, large_shield_dome · costs/attack/shield/hull/base_build_time · `defense_definitions_public_read` (client SELECT) |
| `defense_prerequisites` | building/research prerequisites; **no client SELECT grant** (internal, like `research_prerequisites`) |
| `planet_defenses` | PK `id`, **UNIQUE (planet_id, defense_id)**, FK planet CASCADE / defense RESTRICT, `quantity >= 0` |
| `defense_queue` | PK `id`, `quantity > 0`, `status IN ('BUILDING','COMPLETED','CANCELLED')`, FK planet/defense, owner-scoped SELECT |

Functions:

```text
can_build_defense(uuid,uuid,text,bigint)   SECURITY DEFINER  authenticated   <- client contract (fixed 2026-09-21)
start_defense(uuid,uuid,text,bigint)       SECURITY DEFINER  authenticated   <- entrypoint
process_defense_queue(uuid)                SECURITY DEFINER  postgres/service_role
process_defense_queue_until(uuid,tstz)     SECURITY DEFINER  postgres/service_role  <- locked 2026-09-21
check_defense_requirements(uuid,text)      SECURITY INVOKER  internal
calculate_defense_cost(text,bigint)        SECURITY INVOKER  PUBLIC (client-safe: reads only defense_definitions)
calculate_defense_build_time(uuid,text)    SECURITY INVOKER  internal-ish (reads universes -> 42501 for clients)
ui_defense_definitions() / ui_defense_queue(uuid,uuid)   SECURITY DEFINER
```

## 4. Authoritative chain

* **Cost** — `calculate_defense_cost(defense, quantity)` = `metal_cost|crystal_cost|deuterium_cost × quantity`.
  Single source; the UI consumes it through `can_build_defense`. Defense is **count-based, not level-based**.
* **Time** — `calculate_defense_build_time(planet, defense)` =
  `round((base_build_time / greatest(shipyard_level,1)) / (universes.building_speed × sqrt(E)), 4)`.
  Per **unit**; `start_defense` multiplies by quantity for the queued duration. The Defense line shares the
  shipyard's building level and the universe construction rate — it has no separate speed column.
* **Availability** — `can_build_defense` returns `allowed, reason, defense_id, quantity, metal_cost,
  crystal_cost, deuterium_cost, build_time_seconds`. Branches: `AUTHENTICATION_REQUIRED` → `PLAYER_NOT_OWNED`
  → quantity → planet ownership → requirements → resources → **shield-dome uniqueness** → OK.
* **Queue** — planet-scoped, multiple `BUILDING` rows may stack; `start_defense` serialises them by setting
  `started_at = GREATEST(latest active shipyard/defense finishes_at, now())`, i.e. ships and defenses share
  **one production line per planet**.
* **Completion** — `process_defense_queue(planet)` (now()-bounded) is called by the planet tick; the
  `_until(planet, t)` variant serves the temporal arrival resolvers. Both UPSERT `planet_defenses` and flip the
  row to `COMPLETED` under `FOR UPDATE SKIP LOCKED` with a status-guarded UPDATE → no double completion.

## 5. Closeout 2026-09-21 — two defects fixed

### D-01 (P0) `process_defense_queue_until` was publicly executable

`SECURITY DEFINER` + `PUBLIC EXECUTE` + **no ownership check** + **no clamp to `now()`**: the bound is the
caller-supplied `p_until`. LIVE evidence (rolled back): an authenticated **and** an anon caller both executed it
without error, and a queue row scheduled to finish in **1 day** became `COMPLETED` with the `planet_defenses`
row materialised — i.e. **build time could be bypassed for any planet by any client**.

Fix: migration **`20260921161247_lock_down_process_defense_queue_until`** revokes EXECUTE from PUBLIC/anon/
authenticated, restoring the symmetry already held by `process_shipyard_queue_until`. Its only consumers are
`resolve_attack_arrival` / `resolve_espionage_arrival`, which run as the owner. Verified after: both client roles
get `permission denied for function process_defense_queue_until`; `service_role` keeps EXECUTE.

### D-02 (P1) `can_build_defense` was unusable by the real client

It was `SECURITY INVOKER` while depending on objects a client cannot read —
`check_defense_requirements` → `defense_prerequisites` (no client grant) and
`calculate_defense_build_time` → `universes` (no client grant). As the authenticated role it raised, so the
Defense view threw and fell back to local base costs with no prerequisites and no availability gating.

Fix: migration **`20260921161304_fix_can_build_defense_client_contract`** makes it `SECURITY DEFINER` **and**
adds an ownership gate (`AUTHENTICATION_REQUIRED`, `PLAYER_NOT_OWNED`) so becoming DEFINER cannot turn it into a
foreign-data oracle; EXECUTE is tightened from PUBLIC to `authenticated`. Every other branch and reason string is
preserved verbatim. Verified after: owner `allowed=true reason=OK cost=2000/0/0 time=12.54`;
foreign player `PLAYER_NOT_OWNED`; shield dome `Requires shipyard level 6`.

### UI freshness (P2)

The bounded completion refresh previously scoped to `view === 'research'` now also covers `view === 'defense'`
(one `setTimeout` at `finishes_at + 1.5 s`, cleaned up on unmount, reloading authoritative state), so a finished
defense build no longer leaves a stale countdown/quantity.

## 6. Tests

`supabase/tests/shipyard_defense_lifecycle.sql` — **15 assertions**, transactional, ends in `ROLLBACK`.

* 1-8 definition/availability (owner path), exact charge, queue creation, completion + inventory, second-pass no-op;
* 9-12 NULL-auth and foreign-owner rejection for both entrypoints;
* **13-15 (new, 2026-09-21)** reproduce the **real client role** (`SET LOCAL ROLE authenticated`):
  13 `can_build_defense` works for the owner, 14 it is not a foreign oracle (`PLAYER_NOT_OWNED`),
  15 `process_defense_queue_until` is closed to anon/authenticated but open to `service_role`.

The fixture was rewritten to **resolve the LIVE HUMAN player** (the previous hardcoded UUIDs no longer existed and
made the suite unrunnable; it also ran as the owner, i.e. it structurally could not detect D-01/D-02).

LIVE result 2026-09-21: **15/15 PASS, 0 FAIL**.

## 7. Combat boundary

Defense is planet-bound and its persisted state is the single source of truth for future combat:
`planet_defenses(planet_id, defense_id, quantity)` with `defense_definitions.attack|shield|hull`, plus
`repair_defenses_after_combat(uuid)` and the combat-side readers `get_combat_defense_attack|shield|hull`.
**The Combat Engine is not implemented** — a separate CORE block, not a Defense defect. No combat formula was
invented here.

## 8. Remaining P3 (not fixed)

* `start_defense` still carries EXECUTE for `anon` (the body rejects anon with `Authentication required`);
* `calculate_defense_build_time` is PUBLIC-executable and fails for clients (`universes`); it is not a client
  contract, so this is hygiene;
* `check_defense_requirements` is PUBLIC-executable and fails for clients (`defense_prerequisites`);
* an unknown `defense_id` raises from `calculate_defense_cost` before the structured reason is returned
  (pre-existing order, unchanged by the closeout);
* `CANCELLED` is admitted by the CHECK but unreachable (no cancellation path);
* `COMPLETED` `defense_queue` rows are never purged;
* the Shipyard twin `can_build_ship` has the **same D-02 defect class** (reported by the Shipyard audit, not
  fixed here because it is Shipyard-owned).

## 9. Lifeforms

Lifeforms remain a future **UPDATE** family. Nothing in this document activates or implements them.
