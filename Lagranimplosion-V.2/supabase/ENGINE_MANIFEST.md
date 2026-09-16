# Supabase Game Engine Manifest

Audited against the live project `evtfsbntvuqmahiskekd` on 2026-09-16.

The repository contains the frontend, Cloudflare Worker and a versioned `supabase/migrations` tree. The live Supabase database remains authoritative at runtime, but the backend changes relevant to the current engine are now represented in Git as migrations.

The live database currently contains the audited engines for economy, construction, research, shipyard, defense, fleet movement, combat, expeditions, lifeforms, universe evolution/clock/expansion, AI population and guest onboarding.

## Current universe temporal engine

The universe engine is timestamp-driven rather than dependent on a continuously running application process:

- `universe_clock` stores the authoritative `last_tick_at`, `next_tick_at` and tick interval.
- `process_universe_clock(uuid)` catches up overdue time from the stored schedule instead of replaying every missed minute.
- `process_universe_heartbeat()` processes active universes and coordinates clock catch-up, galaxy rolls, system expansion and AI population reconciliation.
- The live Supabase project currently runs `universe-heartbeat` through `pg_cron` once per minute.
- Fleet events have a separate live `pg_cron` worker at one-second cadence and are serialized against universe economic settlement.

The important consequence is that the universe's logical time is stored in the database. If the heartbeat is delayed or the application is offline, the next successful heartbeat catches up from persisted timestamps rather than resetting the universe clock to the current time.

## Universe expansion model

For the active production universe:

- galaxies 1–100 are normal galaxies;
- normal galaxy system intervals are configured from the selected `8 × G^0.75` hour curve;
- special galaxies are created after the normal galaxy range by the configured global roll;
- special galaxies begin with their configured initial system count and use their own interval-growth factor;
- AI population is reconciled against the configured lower density band and never deletes existing AI planets merely because density later rises.

## Migration history

The repository contains the backend hardening and engine migrations through the current temporal/fleet fixes, including:

- `20260914074800_integrate_evolution_over_resource_time.sql`
- `20260914215000_close_legacy_state_mutation_entrypoints.sql`
- `20260914215616_final_audit_close_public_state_mutation_gaps.sql`
- `20260915050000_add_guest_temporal_ui_sync_rpc.sql`
- `20260915210651_create_normal_guest_onboarding_and_early_tester.sql`
- `20260916014916_harden_universe_temporal_catchup_v2.sql`
- `20260916020002_harden_universe_fleet_event_order.sql`
- `20260916020230_harden_fleet_arrival_queue_timestamps.sql`
- `20260916020500_harden_fleet_event_time_rewards.sql`
- `20260916021500_fix_attack_arrival_temporal_order.sql`

## Runtime boundary

`src/` = presentation/client integration.

`worker/` = Cloudflare edge request boundary.

`supabase/` = database schema, migrations and authoritative game engine.

No combat, economy, fleet, research, lifeform or universe rule should be duplicated in the frontend.

## Operational dependency

The repository's Cloudflare Worker is currently an HTTP/assets boundary; it is not the universe scheduler. Universe progression depends on the Supabase `pg_cron` job `universe-heartbeat`, and fleet event processing depends on the existing `deuteria-fleet-worker` job. These live scheduler jobs should be treated as deployment/runtime infrastructure and kept aligned with the versioned backend migrations.
