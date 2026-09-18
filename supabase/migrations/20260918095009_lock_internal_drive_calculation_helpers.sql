-- =============================================================================
-- RECOVERED MIGRATION — 20260918095009
-- ledger name : lock_internal_drive_calculation_helpers
-- provenance  : Supabase LIVE supabase_migrations.schema_migrations.statements
--               (verbatim payload of the original apply_migration call; no historical
--                local file existed in this repository, its stashes or the local copies)
-- recovered   : 2026-09-18 by the drift-reconciliation mission
-- ALREADY APPLIED IN LIVE — do not re-apply; this file exists for traceability only.
-- =============================================================================

revoke execute on function public.get_player_research_level(uuid,text) from public, anon, authenticated;
revoke execute on function public.calculate_player_ship_speed(uuid,text) from public, anon, authenticated;
revoke execute on function public.calculate_player_fleet_fuel_for_distance(numeric,numeric,uuid,text,bigint,numeric) from public, anon, authenticated;

