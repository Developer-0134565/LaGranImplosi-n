# Missile System — canonical implementation record

**Status:** CLOSED — backend and LIVE verified (2026-10-02). Browser re-certification was not run in the closure session; do not describe the missile UI as newly browser-certified.

## Canonical decisions

- Silo base build time: **60 seconds**, time_factor = 2.
- Anti-ballistic missile base build time: **60 seconds**.
- Interplanetary missile base build time: **60 seconds**.
- These values were checked against the LIVE catalogue. They are the LGI economy decision; do not substitute OGameX's (metal + crystal) / 2500 hours formula or reopen D1 without an explicit human decision.

## Authoritative lifecycle

- Launch is server-authoritative and resolves identity through auth.uid() → players.user_id.
- Ownership, range (impulse * 5) - 1, distance, stock and target priority are validated server-side.
- Dispatch locks the relevant state; travel reuses process_fleet_movements (no second worker).
- Arrival resolution is idempotent for terminal COMPLETED / CANCELLED states.
- Destruction reuses the existing planet_defenses engine, selecting cheapest with deterministic metal + crystal ASC, then defense_id ASC tie-break.
- Player reports use create_player_message with per-mission deduplication.

## Fixture repair and certification

The earlier claimed fixture PASS was invalid: missile_target_priority_regression.sql contained an unterminated INSERT and an unclosed loop. Two false-pass traps also asserted capacity/slot cases without exercising those paths. These were test-fixture defects, not product defects.

After repair, the reported LIVE transactional runs were:

| Fixture / slice | Result |
|---|---:|
| missile_ui_surface.sql | 5/5 PASS |
| missile_target_priority_regression.sql | 13/13 PASS |
| missile_system.sql catalog + capacity | 31 PASS / 0 FAIL |
| missile_system.sql range + flight + priority | 26 PASS / 0 FAIL |
| missile_system.sql combat / idempotency / security / demolition | PASS / 0 FAIL |
| LIVE residue after verification | 0 |

Static checks reported: TypeScript PASS, build PASS, contract certification PASS (74 RPC names at that run), git diff --check PASS; lint 0 errors and 7 pre-existing warnings.

## Operational caveats

- Browser re-certification was not run in that mission.
- Migration-ledger filename/version drift remains documented; do not use supabase db push to repair it.
- No commit or push was made by the original implementation/closure session.
- Do not reopen launch, travel, resolution, destruction priority, report generation or ownership without new regression evidence or an explicit human decision.
