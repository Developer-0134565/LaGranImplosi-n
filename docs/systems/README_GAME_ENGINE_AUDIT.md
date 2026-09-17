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
| Basic idempotency | 🟢 | Already-completed/non-building states are guarded |
| Production after construction | 🟡 | Must be explicitly validated as the next construction test |
| Real concurrency/race safety | 🟡 | Must be tested/reasoned with concurrent completion attempts |
| Web functional test | 🟡 | User must validate the complete construction flow through the web UI |
| Certification | 🟡 | Pending production, concurrency and user web validation |

### Evidence discipline

Do not describe a live database test as executed unless its result is directly observable in the current session/tool output. Distinguish:

- code/documentation evidence;
- verified live execution;
- pending validation.

## Construction — next tests

### A. Building → production

Prove that after a building changes from level N to N+1, the resulting production is correct and derives from the persisted building state. Keep the classic/base engine separate from future universe-evolution modifiers.

### B. Completion concurrency / repeated completion

Verify that two completion attempts cannot advance one queue item twice or produce an unintended N→N+2 transition. Distinguish logical idempotency from real transactional race safety.

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
