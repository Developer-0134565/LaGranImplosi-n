# GAME ENGINE AUDIT — LA GRAN IMPLOSIÓN

## Purpose

Living audit of the basic gameplay engine before the temporal layer and universe-evolution layer are treated as active implementation priorities.

## Audit order

```text
1. Construction
2. Research
3. Fleet movement
4. Transport
5. Attack
6. Combat

→ only after the motor base is certified:
7. Temporal layer
8. Universe evolution
```

A domain is not considered certified only because functions exist. Audit each domain across:

- implementation
- execution
- persistence/state transitions
- error handling
- idempotency
- concurrency
- integration
- documentation
- web functional test by the user

## Construction — current audit

### Flow

```text
Planet
  ↓
start_building()
  ↓
validation
  ↓
cost + time
  ↓
resource deduction
  ↓
building_queue
  ↓
process_building_queue_for_planet()
  ↓
complete_building()
  ↓
planet_buildings
  ↓
production
```

### Current status

| Area | Status | Notes |
|---|---|---|
| `start_building` | 🟢 | Entrypoint audited: ownership/guest access, planet lock, destroyed state, definition, max level, prerequisites, active-queue guard and planet fields |
| Cost calculation | 🟢 | `calculate_building_cost()` = `base * cost_factor^(target_level-1)`; verified live against the oracle for every definition |
| Time calculation | 🟢 | `calculate_building_time()` = `base_build_time_seconds * time_factor^(L-1) / (universe.building_speed * sqrt(evolution))` + expedition-item bonus applied in `start_building` |
| Resource deduction | 🟢 | `planet_resources` locked `FOR UPDATE` and deducted atomically (`UPDATE ... WHERE metal>=cost ... IF NOT FOUND → INSUFFICIENT_RESOURCES`) |
| `building_queue` | 🟢 | Records target level, status (`BUILDING`/`COMPLETED`/`CANCELLED`) and timing |
| Queue processing | 🟢 | `process_building_queue()`, `_for_planet()`, `_for_universe()` with `FOR UPDATE SKIP LOCKED`; `process_planet_tick()` and `update_planet_resources_until()` also settle due events |
| Completion | 🟢 | `complete_building()` guards queue status, finish time and expected target level |
| Persistence | 🟢 | `planet_buildings` UPSERT by PK `(planet_id, building_id)`; live evidence: completed queue row with its level persisted |
| Idempotency / concurrency | 🟢 | See "Concurrency & idempotency guarantees" below; covered by the transactional lifecycle test |
| Requirements | 🟡 | Machinery complete (`building_prerequisites` + validation in `start_building`/`can_start_building`), but the live table is empty: no dependency is configured yet |
| Production after construction | 🟢 | `calculate_planet_production()` is authoritative (universe rates + item/lifeform bonuses + energy limitation) and is what resource settlement uses; the new level is applied on the next settlement |
| UI | 🟢 | Buildings view now consumes `can_start_building()` (authoritative cost of the next level, current level and availability+reason) and settles temporal state with `sync_current_planet_resources()`; base-time label kept honest ("TIEMPO BASE") because client access to universe rates is gated |
| Tests | 🟢 | `scripts/verify-buildings.mjs` (read-only live verification) and `supabase/tests/buildings_lifecycle.sql` (transactional lifecycle test) |
| Web functional test | 🟡 | User must still validate the complete construction flow through the browser |
| Certification | 🟡 | Pending only the user's browser validation |

### Evidence discipline

Do not describe a live database test as executed unless its result is directly observable in the current session/tool output. Distinguish:

- code/documentation evidence;
- verified live execution;
- pending validation.

## Construction — concurrency & idempotency guarantees

Static audit of the live engine (verified 2026-09-18 against the live database dump):

```text
start_building()
  · SELECT ... FROM planets WHERE id=... AND player_id=... FOR UPDATE   → serializes starts per planet
  · IF EXISTS(active queue row) → BUILDING_QUEUE_ALREADY_ACTIVE
  · UPDATE planet_resources ... WHERE metal>=cost AND crystal>=cost AND deuterium>=cost
      IF NOT FOUND → INSUFFICIENT_RESOURCES                             → atomic deduction, no partial spend
  · INSERT building_queue(status='BUILDING', target_level=current+1)

complete_building(queue_id)
  · SELECT ... FROM building_queue WHERE id=... FOR UPDATE              → serializes completions of that row
  · IF status='COMPLETED' → RETURN target_level  (idempotent, no second increment)
  · IF status<>'BUILDING' → BUILDING_QUEUE_NOT_ACTIVE
  · IF finishes_at > now() → BUILDING_NOT_FINISHED
  · SELECT ... FROM planet_buildings ... FOR UPDATE
  · IF target_level <> current_level + 1 → BUILDING_LEVEL_MISMATCH       → blocks any N→N+2 transition
  · INSERT ... ON CONFLICT(planet_id, building_id) DO UPDATE SET level   → single row per building

process_building_queue*()  → FOR UPDATE SKIP LOCKED (concurrent processors cannot grab the same row)
```

Conclusion: two concurrent completions cannot advance one queue item twice (row lock + status
early-return + target-level guard + PK upsert), and two concurrent starts cannot create two active
queue rows for the same planet (planet row lock + active-queue guard).

## Construction — projection helpers (unused, divergent — documented, not changed)

`calculate_building_production_delta()` and `project_building_production()` are **not called by the
game engine nor by the frontend** (the frontend only uses `building_definitions`, `planet_buildings`,
`building_queue` and `start_building`). They are legacy projection helpers and their output does not
match the authoritative engine:

- `calculate_building_production_delta()` is **broken in the live database**: it selects
  `r.economy_rate` / `r.production_rate`, but `calculate_universe_rates()` returns `economy` /
  `production`. Live call result: `ERROR: column r.economy_rate does not exist`.
- `project_building_production()` mixes the authoritative engine for the *current* value
  (`calculate_planet_production()`, which includes item/lifeform bonuses and the energy limitation)
  with bare formulas for the *target* value (no bonuses, no energy factor, bare energy for
  `solar_plant`). Any projection built on it can therefore overstate the gain of a level-up whenever
  energy throttling or bonuses are active.

Decision: keep them untouched (no rule/DB change for unused helpers), do **not** wire them into the
UI, and do not use them as a production oracle. A future cleanup migration may either repair
(`economy`/`production`) or deprecate them explicitly.

## Construction — tests

| Test | Kind | Covers |
|---|---|---|
| `scripts/verify-buildings.mjs` | live, read-only | definitions, cost oracle (`base·factor^(n-1)`), `can_start_building` contract + cost coherence, insufficient-resources branch, queue/level invariants, projection-helper divergence |
| `supabase/tests/buildings_lifecycle.sql` | transactional (`BEGIN … ROLLBACK`, never commits) | cost contract, insufficient resources, invalid building, start + exact cost deduction, queue creation, single active queue, processing/completion, level persistence, double completion (idempotency + N→N+2 protection), target-level guard, production after level-up |

```bash
node scripts/verify-buildings.mjs            # solo lectura (usa .env.local)
# supabase/tests/buildings_lifecycle.sql → pegar completo en el SQL editor de Supabase
```

## Construction — findings outside the Buildings scope (documented, not fixed)

- `public.universes` has a public RLS `SELECT` policy for `anon`/`authenticated` but **no table
  `GRANT SELECT`**, so client calls to `calculate_universe_rates()`, `calculate_planet_production()`
  and `calculate_building_time()` fail with `permission denied for table universes`. Building
  start/completion are unaffected (`start_building` is `SECURITY DEFINER`). Belongs to the final
  RLS/security phase.
- `building_prerequisites` is empty: the requirement machinery is implemented but unused until the
  game configures dependencies.
- The Buildings UI displays **base** build time (labelled `TIEMPO BASE`) before starting; the
  authoritative time is visible in the active queue (`building_queue.finishes_at`) as soon as the
  construction starts. Showing the exact pre-start time would require client read access to universe
  rates (see previous finding).

## Construction — user web validation

After the backend/integration validation above, the user validates in the browser:

1. Open the development homeworld.
2. Open Construction.
3. Select a building (the card must show the authoritative cost of the next level).
4. Start construction.
5. Verify resource deduction and the queue entry/countdown.
6. Wait for completion (heartbeat/catch-up settles the event; reloading the view shows the new level).
7. Verify the resulting building level and the production change.

Only after the user reports this test as successful does Construction become **CERTIFIED**.

## Scope boundary

Do not mix the following into the construction certification unless a concrete dependency requires it:

- universe-evolution formulas;
- redesign of the persistent temporal engine;
- final RLS/security hardening.

Those are separate layers/phases.

## Documentation rule

When a construction test changes the confirmed state, update this document first. Update `docs/PROJECT_CONTEXT_PROMPT.md` only when the operational OPEN/CLOSED/certification state changes.


## Ownership hardening — 2026-09-18

### Status

**CLOSED / VERIFIED LIVE.** Ownership hardening is treated as a cross-cutting security gate for the owned game-action entrypoints, not as a gameplay-domain fix.

The live migration `20260918030000_harden_player_ownership_in_owned_rpcs` is applied. Six critical RPCs were hardened:

- `start_building(uuid, uuid, text)`
- `start_research(uuid, uuid, text)`
- `start_ship(uuid, uuid, text, bigint)`
- `start_defense(uuid, uuid, text, bigint)`
- `start_fleet(uuid, uuid, uuid, text, bigint, text)`
- `sync_current_planet_resources(uuid, uuid, timestamptz)`

Live inspection confirms all six are `SECURITY DEFINER` with `search_path = public, pg_temp`. The entrypoints validate the authenticated user against `players.user_id`; planet-scoped actions additionally validate that the planet belongs to the supplied player and is not destroyed. NULL `auth.uid()` is rejected.

The transactional foreign-owner regression rejected all six calls without committing mutations. The NULL-auth regression also rejected all six calls when executed as `authenticated` with no JWT subject. `start_fleet` is not executable by `anon`, which is an ACL restriction rather than a failed ownership guard.

Detailed evidence and the migration/reproducibility finding are tracked in [`README_OWNERSHIP_HARDENING.md`](README_OWNERSHIP_HARDENING.md).
