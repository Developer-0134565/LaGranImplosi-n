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
  and build_time_seconds.
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

## Transactional certification — 2026-09-19

Test file:

supabase/tests/shipyard_defense_lifecycle.sql

The fixture runs inside BEGIN … ROLLBACK and therefore leaves no persistent state.

**LIVE result: 12/12 PASS.**

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

## Certification boundary

Backend lifecycle is now **CLOSED / VERIFIED LIVE** for the current V1 single-planet
Shipyard + Defence model.

The remaining gate is browser certification by the user:

- open Shipyard and verify authoritative cost/time/availability;
- start a ship and verify queue/countdown/resource deduction;
- verify completion and inventory;
- repeat for Defence;
- reload and confirm persisted state.

No Lifeforms or ACS/HOLDING/DEFEND implementation is implied by this closure.
