-- =============================================================================
-- RECOVERED MIGRATION — 20260918094440
-- ledger name : use_canonical_fleet_travel_time_in_dispatch
-- provenance  : Supabase LIVE supabase_migrations.schema_migrations.statements
--               (verbatim payload of the original apply_migration call; no historical
--                local file existed in this repository, its stashes or the local copies)
-- recovered   : 2026-09-18 by the drift-reconciliation mission
-- ALREADY APPLIED IN LIVE — do not re-apply; this file exists for traceability only.
-- =============================================================================

do $$
declare
  v_sql text;
begin
  select pg_get_functiondef('public.start_fleet(uuid,uuid,uuid,text,bigint,text)'::regprocedure)
    into v_sql;

  v_sql := replace(
    v_sql,
    'v_travel_time:=(v_distance/v_ship_speed)*3600/v_fleet_rate;',
    'v_travel_time:=public.calculate_fleet_travel_time(v_distance,v_ship_speed,v_fleet_rate,100);'
  );

  execute v_sql;

  select pg_get_functiondef('public.start_fleet_mixed(uuid,uuid,uuid,jsonb,text)'::regprocedure)
    into v_sql;

  v_sql := replace(
    v_sql,
    'v_travel_time:=(v_distance/v_min_ship_speed)*3600/v_fleet_rate;',
    'v_travel_time:=public.calculate_fleet_travel_time(v_distance,v_min_ship_speed,v_fleet_rate,100);'
  );

  execute v_sql;
end $$;

