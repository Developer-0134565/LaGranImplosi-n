# UNIVERSE EVOLUTION MONITOR — LA GRAN IMPLISIÓN

## Purpose

This document is the durable reference for the operational monitor of the Universe Evolution engine. It keeps detailed observability knowledge out of `PROJECT_CONTEXT_PROMPT.md`.

The monitor is **read-only**. It observes the evolution engine; it does not execute or repair evolution work.

## Architecture

```
Supabase evolution engine
        ↓
get_universe_evolution_monitor(uuid)
        ↓
private/internal monitor read model
        ↓
get_universe_evolution_monitor_public(uuid)
        ↓
sanitized UI contract
        ↓
React UniverseEvolutionMonitor
        ↓
Overview
        ↓
Cloudflare Worker production deployment
```

### Private monitor RPC

`public.get_universe_evolution_monitor(uuid)`

- `SECURITY INVOKER`
- full operational monitor
- deliberately not executable by `anon` or `authenticated`
- intended for trusted/internal inspection

### Public UI RPC

`public.get_universe_evolution_monitor_public(uuid)`

- `SECURITY DEFINER`
- `STABLE`
- `SET search_path = ''`
- executable by `anon` and `authenticated`
- only exposes an explicit whitelist of UI-safe fields
- filters to active universes
- does not expose internal failure/error details

This is an intentional, constrained exception to the normal preference for invoker functions. The function must remain read-only, typed, free of dynamic SQL, and limited to the sanitized response contract.

## UI contract

The public monitor exposes:

- universe identity and active state;
- operational status;
- clock last/next execution, interval, processing state, lag and ticks due;
- galaxy/system counts;
- expansion backlog and oldest expansion lag;
- next galaxy roll and rolls due;
- AI population, density, target, tolerance, valid range, deficit and batch estimates;
- next AI reconciliation.

The UI deliberately distinguishes:

### Schedule backlog

An event timestamp is overdue.

Examples:

- clock lag;
- ticks due;
- pending expansion galaxies;
- galaxy rolls due.

### Work backlog

There is actual unfinished universe work.

A small clock lag does not automatically mean the engine is failed. Status must be interpreted together with processing state and evidence of progress.

## Operational statuses

The monitor uses descriptive states:

```
HEALTHY
CATCHING_UP
DEGRADED
STALLED
FAILED
RECOVERING
INACTIVE
```

These are operational states, not performance scores or rankings.

## Polling

The React monitor polls the public RPC approximately every 30 seconds. The authoritative universe clock remains server-side/persisted; the browser timer is only for refreshing the display.

## Validation — 2026-09-18

The monitor passed an end-to-end recovery test:

1. UI initially observed `CATCHING_UP`.
2. Clock showed one pending tick and approximately 46 seconds of lag.
3. After subsequent heartbeat execution:
   - status became `HEALTHY`;
   - lag became `0s`;
   - ticks pending became `0`;
   - expansion backlog remained `0`;
   - galaxy rolls due remained `0`;
   - AI deficit remained `0`.

Observed active Universe 1:

```
Galaxies       101
Normal         100
Special        1
Systems        207
Positions      3105
AI planets     226
AI density     7.28%
Target         7.50%
Tolerance      ±0.25%
Valid range    7.25%–7.75%
Clock interval 60s
```

This validates the complete path:

```
Supabase → sanitized RPC → authenticated EXECUTE → React → monitor UI
```

## Production deployment validation — 2026-09-18

The monitor was verified on the deployed Cloudflare Worker after the production build and asset upload completed successfully.

```text
Worker          lagranimplosion
URL             https://lagranimplosion.lagranimplosion.workers.dev
Version         a5cba4c6-b82f-4c73-b445-f32fb887614
Status          HEALTHY
Clock lag       0s
Ticks pending   0
Expansion       0 pending
Galaxy rolls    0 due
AI deficit      0
```

The public Overview rendered the monitor correctly in production and showed Universe 1 with 101 galaxies, 207 systems, 3105 positions and 226 AI planets at 7.28% density against the 7.50% target with ±0.25% tolerance.

This closes the current monitor deployment/validation phase.

## Security notes

The live Supabase security advisor reports the public RPC as a `SECURITY DEFINER` function accessible to `anon` and `authenticated`. This is intentional for the guest/authenticated UI monitor and must not be treated as permission to expose the private monitor or underlying tables.

A separate security-hardening pass remains responsible for reviewing other existing `SECURITY DEFINER` functions and RLS findings. Do not opportunistically broaden this monitor or change unrelated security policy during feature work.

## Git / migrations

The monitor backend is versioned in:

```
supabase/migrations/20260918020000_register_universe_evolution_monitor.sql
supabase/migrations/20260918020100_add_public_universe_evolution_monitor.sql
supabase/migrations/20260918020200_lock_public_universe_evolution_monitor_to_guest.sql
supabase/migrations/20260918020300_allow_authenticated_universe_evolution_monitor.sql
```

The fourth migration is required because the real game session uses the `authenticated` role as well as guest/anonymous access.

Migration-history synchronization in Supabase previously showed a discrepancy: the SQL objects and permissions were live, while the migration-history query did not list these versions. This remains a reconciliation item; do not blindly re-apply migrations without checking current migration state.

## Maintenance rules

- Do not make the monitor execute evolution functions.
- Do not expose the private monitor RPC to frontend roles.
- Keep the public response whitelist minimal.
- Update this document when monitor fields, status semantics, security boundary or validation results materially change.
- Keep `PROJECT_CONTEXT_PROMPT.md` limited to operational status and a link to this document.
