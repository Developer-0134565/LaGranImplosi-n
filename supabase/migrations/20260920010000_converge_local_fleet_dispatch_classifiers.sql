-- LOCAL CONTROLLED CONVERGENCE — NOT DEPLOYED
-- This migration only removes demonstrated dispatcher bypasses:
-- mission class comes from the canonical classifier and colonize ship speed
-- comes from the player-aware propulsion helper.
--
-- It intentionally does not reconstruct fuel consumption, alter expedition
-- timing, change distance calculation, or modify any worker/lifecycle rule.

DO $$
DECLARE
  v_sql text;
  v_changed boolean;
  v_ship_speed_changed boolean;
  v_class_changed boolean;
BEGIN
  v_sql := pg_get_functiondef(
    'public.start_fleet(uuid,uuid,uuid,text,bigint,text)'::regprocedure
  );
  v_changed := false;

  IF v_sql LIKE '%SELECT fleet_speed INTO v_fleet_speed FROM public.universes WHERE id=v_universe_id;%' THEN
    v_sql := replace(
      v_sql,
      'SELECT fleet_speed INTO v_fleet_speed FROM public.universes WHERE id=v_universe_id;',
      'v_fleet_speed:=public.calculate_mission_fleet_speed_multiplier(v_universe_id,v_mission_type);'
    );
    v_changed := true;
  END IF;

  IF v_sql LIKE '%SELECT u.fleet_speed INTO v_fleet_speed FROM public.universes u WHERE id=v_universe_id;%' THEN
    v_sql := replace(
      v_sql,
      'SELECT u.fleet_speed INTO v_fleet_speed FROM public.universes u WHERE id=v_universe_id;',
      'v_fleet_speed:=public.calculate_mission_fleet_speed_multiplier(v_universe_id,v_mission_type);'
    );
    v_changed := true;
  END IF;

  IF NOT v_changed THEN
    RAISE EXCEPTION 'start_fleet mission-class bypass not found';
  END IF;

  EXECUTE v_sql;

  v_sql := pg_get_functiondef(
    'public.start_fleet_mixed(uuid,uuid,uuid,jsonb,text)'::regprocedure
  );
  v_changed := false;

  IF v_sql LIKE '%SELECT fleet_speed INTO v_fleet_speed FROM public.universes WHERE id=v_universe_id;%' THEN
    v_sql := replace(
      v_sql,
      'SELECT fleet_speed INTO v_fleet_speed FROM public.universes WHERE id=v_universe_id;',
      'v_fleet_speed:=public.calculate_mission_fleet_speed_multiplier(v_universe_id,v_mission_type);'
    );
    v_changed := true;
  END IF;

  IF v_sql LIKE '%SELECT u.fleet_speed INTO v_fleet_speed FROM public.universes u WHERE id=v_universe_id;%' THEN
    v_sql := replace(
      v_sql,
      'SELECT u.fleet_speed INTO v_fleet_speed FROM public.universes u WHERE id=v_universe_id;',
      'v_fleet_speed:=public.calculate_mission_fleet_speed_multiplier(v_universe_id,v_mission_type);'
    );
    v_changed := true;
  END IF;

  IF NOT v_changed THEN
    RAISE EXCEPTION 'start_fleet_mixed mission-class bypass not found';
  END IF;

  EXECUTE v_sql;

  v_sql := pg_get_functiondef(
    'public.start_colonize_fleet(uuid,uuid,integer,integer,integer)'::regprocedure
  );
  v_ship_speed_changed := false;
  v_class_changed := false;

  IF v_sql LIKE '%SELECT sd.speed INTO v_ship_speed FROM public.ship_definitions sd WHERE sd.id=''colony_ship'';%' THEN
    v_sql := replace(
      v_sql,
      'SELECT sd.speed INTO v_ship_speed FROM public.ship_definitions sd WHERE sd.id=''colony_ship'';',
      'v_ship_speed:=public.calculate_player_ship_speed(p_player_id,''colony_ship'');'
    );
    v_ship_speed_changed := true;
  END IF;

  IF v_sql LIKE '%SELECT speed INTO v_ship_speed FROM public.ship_definitions WHERE id=''colony_ship'';%' THEN
    v_sql := replace(
      v_sql,
      'SELECT speed INTO v_ship_speed FROM public.ship_definitions WHERE id=''colony_ship'';',
      'v_ship_speed:=public.calculate_player_ship_speed(p_player_id,''colony_ship'');'
    );
    v_ship_speed_changed := true;
  END IF;

  IF v_sql LIKE '%SELECT u.fleet_speed INTO v_fleet_speed FROM public.universes u WHERE id=v_origin.universe_id;%' THEN
    v_sql := replace(
      v_sql,
      'SELECT u.fleet_speed INTO v_fleet_speed FROM public.universes u WHERE id=v_origin.universe_id;',
      'v_fleet_speed:=public.calculate_mission_fleet_speed_multiplier(v_origin.universe_id,''COLONIZE'');'
    );
    v_class_changed := true;
  END IF;

  IF v_sql LIKE '%SELECT fleet_speed INTO v_fleet_speed FROM public.universes WHERE id=v_origin.universe_id;%' THEN
    v_sql := replace(
      v_sql,
      'SELECT fleet_speed INTO v_fleet_speed FROM public.universes WHERE id=v_origin.universe_id;',
      'v_fleet_speed:=public.calculate_mission_fleet_speed_multiplier(v_origin.universe_id,''COLONIZE'');'
    );
    v_class_changed := true;
  END IF;

  IF NOT v_ship_speed_changed OR NOT v_class_changed THEN
    RAISE EXCEPTION
      'start_colonize_fleet convergence targets incomplete (ship_speed=%, class=%)',
      v_ship_speed_changed,
      v_class_changed;
  END IF;

  EXECUTE v_sql;
END
$$;
