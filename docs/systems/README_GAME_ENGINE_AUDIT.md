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
| `start_building` | 🟢 | Existing construction entrypoint identified and audited |
| Validation | 🟢 | Ownership/access, destroyed state, definition, max level, prerequisites, active queue and planet space are part of the flow |
| Cost calculation | 🟢 | Uses the building cost calculation path |
| Time calculation | 🟢 | Uses the building time calculation path and existing applicable bonus logic |
| Resource deduction | 🟢 | Resource state is locked before deduction |
| `building_queue` | 🟢 | Queue records target level, status and timing |
| Queue processing | 🟢 | `process_building_queue_for_planet()` exists |
| Completion | 🟢 | `complete_building()` guards status, finish time and expected target level |
| Persistence | 🟢 | Completion persists the building level and queue state |
| Basic idempotency | 🟢 | Live test confirmed a repeated completion returns the existing target level without advancing it again |
| Production after construction | 🟢 | Live test confirmed persisted level changes feed the production engine; level 2 → 3 changed the production calculation |
| Production projection helpers | 🟡 | `calculate_building_production_delta()` currently fails because it references `economy_rate`/`production_rate` while `calculate_universe_rates()` returns `economy`/`production`. `project_building_production()` also does not apply the live energy-limitation factor used by `calculate_planet_production()`. Neither helper was found in the GitHub frontend search, so this is currently a helper-layer issue, not a proven blocker for `start_building()`/completion. |
| Real concurrency/race safety | 🟡 | Lock ordering and concurrent completion behavior still require a dedicated race test/reasoning pass |
| Web functional test | 🟡 | User must validate the complete construction flow through the web UI |
| Certification | 🟡 | Pending concurrency and user web validation |

### Verified live construction test

Test environment: inactive **TEST - Universe 1**, planet **Dev Homeworld**. No production-universe mutation was used for the construction test.

Observed sequence:

1. Started `metal_mine` from level 2 toward level 3.
2. Queue row was created with target level 3 and status `BUILDING`.
3. Test completion time was moved into the past while preserving the queue constraint `finishes_at > started_at`.
4. `complete_building()` changed the persisted building to level 3 and queue status to `COMPLETED`.
5. A second `complete_building()` call did not advance the building again.
6. Production was recalculated from persisted building state.
7. The test planet was restored to its previous level/resources/fields and the test queue row was removed.

This verifies logical idempotency and the construction → persisted level → production path. It does **not** yet prove multi-session transactional race safety.

### Evidence discipline

Do not describe a live database test as executed unless its result is directly observable in the current session/tool output. Distinguish:

- code/documentation evidence;
- verified live execution;
- pending validation.

## Construction — next tests

### A. Concurrency / race safety

Prove that two concurrent completion attempts cannot advance one queue item twice or produce an unintended N→N+2 transition. Also inspect lock ordering between:

- `start_building()`
- `process_building_queue_for_planet()`
- `complete_building()`
- `process_planet_tick()`

Distinguish logical idempotency from real transactional race safety.

### B. Helper-layer cleanup

Decide whether the broken/semantically inconsistent production projection helpers are:

- obsolete and should be removed, or
- used by UI/future systems and should be corrected against the authoritative production engine.

Do not modify them merely because they are imperfect; first establish whether they are part of an active contract.

### C. User web validation

After backend/integration validation, the user validates in the browser:

1. Open the development homeworld.
2. Open Construction.
3. Select a building.
4. Verify displayed cost.
5. Start construction.
6. Verify resource deduction.
7. Verify queue entry/countdown.
8. Wait for completion.
9. Verify resulting building level.
10. Verify production change.

Only after the user reports this test as successful does Construction become **CERTIFIED**.

## Scope boundary

Do not mix the following into the construction certification unless a concrete dependency requires it:

- universe-evolution formulas;
- redesign of the persistent temporal engine;
- final RLS/security hardening.

Those are separate layers/phases.

## Documentation rule

When a construction test changes the confirmed state, update this document first. Update `docs/PROJECT_CONTEXT_PROMPT.md` only when the operational OPEN/CLOSED/certification state changes.
