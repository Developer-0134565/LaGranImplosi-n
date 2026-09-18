-- =============================================================================
-- RECOVERED MIGRATION — 20260918095005
-- ledger name : apply_drive_tech_to_fleet_dispatch
-- provenance  : Supabase LIVE supabase_migrations.schema_migrations.statements
--               (verbatim payload of the original apply_migration call; no historical
--                local file existed in this repository, its stashes or the local copies)
-- recovered   : 2026-09-18 by the drift-reconciliation mission
-- ALREADY APPLIED IN LIVE — do not re-apply; this file exists for traceability only.
-- =============================================================================

do $$
declare
  f text;
begin
  f := pg_get_functiondef('public.start_fleet(uuid,uuid,uuid,text,bigint,text)'::regprocedure);

  f := replace(
    f,
    'v_fuel:=public.calculate_fleet_fuel_for_distance(v_distance,p_ship_id,p_quantity);',
    'v_fuel:=0;'
  );

  f := replace(
    f,
    'SELECT speed INTO v_ship_speed FROM public.ship_definitions WHERE id=p_ship_id;',
    'v_ship_speed:=public.calculate_player_ship_speed(p_player_id,p_ship_id);'
  );

  f := replace(
    f,
    'v_travel_time:=greatest(v_travel_time,1);',
    'v_travel_time:=greatest(v_travel_time,1); v_fuel:=public.calculate_player_fleet_fuel_for_distance(v_distance,v_travel_time,p_player_id,p_ship_id,p_quantity,100);'
  );

  execute f;
end $$;

do $$
declare
  f text;
begin
  f := pg_get_functiondef('public.start_fleet_mixed(uuid,uuid,uuid,jsonb,text)'::regprocedure);

  f := replace(
    f,
    'v_fuel:=v_fuel+public.calculate_fleet_fuel_for_distance(v_distance,v_ship_id,v_quantity);',
    'null;'
  );

  f := replace(
    f,
    'SELECT sd.speed INTO v_ship_speed FROM public.ship_definitions sd WHERE sd.id=v_ship_id;',
    'v_ship_speed:=public.calculate_player_ship_speed(p_player_id,v_ship_id);'
  );

  f := replace(
    f,
    'v_travel_time:=greatest(v_travel_time,1);',
    'v_travel_time:=greatest(v_travel_time,1); v_fuel:=0; FOR v_ship_id,v_quantity IN SELECT key,value::bigint FROM jsonb_each_text(p_ships) ORDER BY key LOOP v_fuel:=v_fuel+public.calculate_player_fleet_fuel_for_distance(v_distance,v_travel_time,p_player_id,v_ship_id,v_quantity,100); END LOOP;'
  );

  execute f;
end $$;

