# Supabase Game Engine Manifest

Audited against the live project `evtfsbntvuqmahiskekd` on 2026-09-15.

The repository currently contains the frontend and Cloudflare worker, but no versioned `supabase/migrations` tree. The authoritative backend is therefore live in Supabase and is not yet reproducible from Git alone.

The live database currently contains the audited engines for economy, construction, research, shipyard, defense, fleet movement, combat, expeditions, lifeforms, universe evolution/clock/expansion, AI population and guest onboarding.

Migration history exists in Supabase and includes the final engine/audit migrations through:

- `20260914205823_close_fleet_engine_v1_fuel`
- `20260914211217_enforce_research_prerequisites_on_start`
- `20260914214728_20260914215000_close_legacy_state_mutation_entrypoints`
- `20260914215616_final_audit_close_public_state_mutation_gaps`
- `20260914223208_20260914223000_close_internal_plain_rpc_surface`
- `20260914223220_20260914223100_remove_public_execute_from_internal_rpcs`
- `20260915045311_add_guest_temporal_ui_sync_rpc`
- `20260915052852_grant_guest_game_read_tables`
- `20260915172235_grant_guest_action_rpcs`
- `20260915210651_create_normal_guest_onboarding_and_early_tester`
- `20260915210748_allow_dev_frontend_player_read`
- `20260915210912_allow_dev_frontend_resource_read`

## Boundary

`src/` = presentation/client integration.

`worker/` = Cloudflare edge request boundary.

`supabase/` = database schema, migrations and authoritative game engine.

No combat/economy/universe rule should be duplicated in the frontend.
