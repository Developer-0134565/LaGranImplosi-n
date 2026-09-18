-- ============================================================================
-- HARDENING DE IDENTIDAD - player ownership en RPCs con ruta invitado insegura
-- ----------------------------------------------------------------------------
-- Auditoria de identidad (2026-09-18): las RPC de construccion/investigacion/
-- flota/defensa y el sincronizador temporal aceptaban un `p_player_id` arbitrario
-- cuando `auth.uid()` era NULL siempre que el jugador destino tuviera
-- `is_guest = true`, permitiendo operar sobre el planeta de OTRO invitado.
--
-- Cambio (minimo y quirurgico): se elimina UNICAMENTE esa rama de bypass. La
-- comprobacion `players.user_id = auth.uid()` que ya existia para llamadas
-- autenticadas se conserva; sin sesion la operacion se rechaza.
--
-- Compatibilidad: el frontend crea una sesion ANONIMA de Supabase
-- (supabase.auth.signInAnonymously()) antes de operar, por lo que los invitados
-- tienen auth.uid() real y no cambia la UX.
--
-- Cuerpos: extraidos de la definicion viva (backup/supabase/schema.sql) y
-- parcheados programaticamente; el unico diff en cada funcion es el guard.
--
-- Pendientes de una fase de seguridad posterior (sin uso en el frontend actual):
-- start_lifeform_building, start_lifeform_research, start_colonize_fleet,
-- start_fleet_mixed, use_expedition_item y el trigger enforce_player_write_access.
-- ============================================================================

CREATE OR REPLACE FUNCTION "public"."start_building"("p_player_id" "uuid", "p_planet_id" "uuid", "p_building_id" "text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
DECLARE
    v_universe_id uuid;
    v_current_level integer;
    v_target_level integer;
    v_build_time numeric;
    v_metal_cost numeric;
    v_crystal_cost numeric;
    v_deuterium_cost numeric;
    v_queue_id uuid;
    v_item_bonus numeric := 0;
    v_auth_user uuid;
BEGIN
    v_auth_user := auth.uid();

    IF v_auth_user IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.players pl
        WHERE pl.id = p_player_id
          AND pl.user_id = v_auth_user
    ) THEN
        RAISE EXCEPTION 'Player does not belong to authenticated user';
    END IF;

    IF v_auth_user IS NULL THEN
        RAISE EXCEPTION 'Authentication required';
    END IF;

    SELECT universe_id INTO v_universe_id
    FROM public.planets
    WHERE id = p_planet_id AND player_id = p_player_id AND is_destroyed = false
    FOR UPDATE;

    IF v_universe_id IS NULL THEN RAISE EXCEPTION 'PLANET_NOT_FOUND_OR_NOT_OWNED'; END IF;
    SELECT COALESCE(MAX(level),0) INTO v_current_level FROM public.planet_buildings WHERE planet_id=p_planet_id AND building_id=p_building_id;
    v_target_level:=v_current_level+1;
    IF NOT EXISTS(SELECT 1 FROM public.building_definitions WHERE id=p_building_id) THEN RAISE EXCEPTION 'BUILDING_NOT_FOUND: %',p_building_id; END IF;
    IF EXISTS(SELECT 1 FROM public.building_definitions WHERE id=p_building_id AND max_level IS NOT NULL AND v_target_level>max_level) THEN RAISE EXCEPTION 'BUILDING_MAX_LEVEL_REACHED'; END IF;
    IF EXISTS(SELECT 1 FROM public.building_prerequisites bp LEFT JOIN public.planet_buildings pb ON pb.planet_id=p_planet_id AND pb.building_id=bp.prerequisite_building_id WHERE bp.building_id=p_building_id AND COALESCE(pb.level,0)<bp.required_level) THEN RAISE EXCEPTION 'BUILDING_PREREQUISITES_NOT_MET'; END IF;
    IF EXISTS(SELECT 1 FROM public.building_queue WHERE planet_id=p_planet_id AND UPPER(status) IN('BUILDING','QUEUED','ACTIVE')) THEN RAISE EXCEPTION 'BUILDING_QUEUE_ALREADY_ACTIVE'; END IF;
    IF EXISTS(SELECT 1 FROM public.planets WHERE id=p_planet_id AND fields_used>=fields_total) THEN RAISE EXCEPTION 'PLANET_FIELDS_FULL'; END IF;
    SELECT c.metal,c.crystal,c.deuterium INTO v_metal_cost,v_crystal_cost,v_deuterium_cost FROM public.calculate_building_cost(p_building_id,v_target_level) c;
    v_build_time:=public.calculate_building_time(p_building_id,v_target_level,v_universe_id);
    v_item_bonus:=public.get_active_expedition_item_effect(p_player_id,p_planet_id,'building_speed_percent');
    v_build_time:=round(v_build_time/(1+v_item_bonus/100),4);
    PERFORM public.process_planet_tick(p_planet_id);
    PERFORM 1 FROM public.planet_resources WHERE planet_id=p_planet_id FOR UPDATE;
    UPDATE public.planet_resources SET metal=metal-v_metal_cost,crystal=crystal-v_crystal_cost,deuterium=deuterium-v_deuterium_cost,updated_at=now() WHERE planet_id=p_planet_id AND metal>=v_metal_cost AND crystal>=v_crystal_cost AND deuterium>=v_deuterium_cost;
    IF NOT FOUND THEN RAISE EXCEPTION 'INSUFFICIENT_RESOURCES'; END IF;
    INSERT INTO public.building_queue(planet_id,building_id,target_level,started_at,finishes_at,status) VALUES(p_planet_id,p_building_id,v_target_level,now(),now()+(v_build_time*interval '1 second'),'BUILDING') RETURNING id INTO v_queue_id;
    RETURN v_queue_id;
END;
$$;


CREATE OR REPLACE FUNCTION "public"."start_research"("p_player_id" "uuid", "p_planet_id" "uuid", "p_research_id" "text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare
    v_universe_id uuid;
    v_current_level integer;
    v_target_level integer;
    v_research_time numeric;
    v_metal_cost numeric;
    v_crystal_cost numeric;
    v_deuterium_cost numeric;
    v_queue_id uuid;
    v_item_bonus numeric := 0;
    v_auth_user uuid;
begin
    v_auth_user := auth.uid();

    if v_auth_user is not null and not exists (
        select 1 from public.players pl
        where pl.id = p_player_id
          and pl.user_id = v_auth_user
    ) then
        raise exception 'Player does not belong to authenticated user';
    end if;

    if v_auth_user is null then
        raise exception 'Authentication required';
    end if;

    -- Research is player-wide, not planet-wide. Lock the player row so two
    -- simultaneous requests cannot both pass the single research-queue check.
    perform 1 from public.players where id = p_player_id for update;

    select universe_id into v_universe_id
    from public.planets
    where id = p_planet_id and player_id = p_player_id and is_destroyed = false
    for update;

    if v_universe_id is null then
        raise exception 'PLANET_NOT_FOUND_OR_NOT_OWNED';
    end if;

    if not exists(select 1 from public.research_definitions where id=p_research_id) then
        raise exception 'RESEARCH_NOT_FOUND: %',p_research_id;
    end if;

    select coalesce(max(level),0) into v_current_level
    from public.player_research
    where player_id=p_player_id and research_id=p_research_id;
    v_target_level:=v_current_level+1;

    if exists(
        select 1 from public.research_definitions
        where id=p_research_id and max_level is not null and v_target_level>max_level
    ) then
        raise exception 'RESEARCH_MAX_LEVEL_REACHED';
    end if;

    -- Authoritative prerequisite validation. The old start path checked the
    -- definition, max level and queue, but could bypass research_prerequisites.
    if not public.can_research(p_player_id, p_research_id, v_target_level) then
        raise exception 'RESEARCH_REQUIREMENTS_NOT_MET';
    end if;

    if exists(
        select 1 from public.research_queue
        where player_id=p_player_id
          and upper(status) in('RESEARCHING','QUEUED','ACTIVE')
    ) then
        raise exception 'RESEARCH_QUEUE_ALREADY_ACTIVE';
    end if;

    select c.metal,c.crystal,c.deuterium into v_metal_cost,v_crystal_cost,v_deuterium_cost
    from public.calculate_research_cost(p_research_id,v_target_level) c;

    v_research_time:=public.calculate_research_time(p_research_id,v_target_level,v_universe_id);
    v_item_bonus:=public.get_active_expedition_item_effect(p_player_id,p_planet_id,'research_speed_percent');
    v_research_time:=round(v_research_time/(1+v_item_bonus/100),4);

    perform public.process_planet_tick(p_planet_id);
    perform 1 from public.planet_resources where planet_id=p_planet_id for update;

    update public.planet_resources
    set metal=metal-v_metal_cost,
        crystal=crystal-v_crystal_cost,
        deuterium=deuterium-v_deuterium_cost,
        updated_at=now()
    where planet_id=p_planet_id
      and metal>=v_metal_cost
      and crystal>=v_crystal_cost
      and deuterium>=v_deuterium_cost;

    if not found then
        raise exception 'INSUFFICIENT_RESOURCES';
    end if;

    insert into public.research_queue(
        player_id,planet_id,research_id,target_level,started_at,finishes_at,status
    )
    values(
        p_player_id,p_planet_id,p_research_id,v_target_level,now(),
        now()+(v_research_time*interval '1 second'),'RESEARCHING'
    )
    returning id into v_queue_id;

    return v_queue_id;
end;
$$;


CREATE OR REPLACE FUNCTION "public"."start_ship"("p_player_id" "uuid", "p_planet_id" "uuid", "p_ship_id" "text", "p_quantity" bigint DEFAULT 1) RETURNS TABLE("queue_id" "uuid", "ship_id" "text", "quantity" bigint, "started_at" timestamp with time zone, "finishes_at" timestamp with time zone, "metal_cost" numeric, "crystal_cost" numeric, "deuterium_cost" numeric)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_planet_player uuid; v_reason text; v_metal numeric; v_crystal numeric; v_deuterium numeric; v_metal_available numeric; v_crystal_available numeric; v_deuterium_available numeric; v_unit_time numeric; v_total_time numeric; v_started_at timestamptz; v_finishes_at timestamptz; v_queue_id uuid; v_auth_user uuid;
BEGIN
  v_auth_user:=auth.uid();
  IF v_auth_user IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.players pl WHERE pl.id=p_player_id AND pl.user_id=v_auth_user) THEN RAISE EXCEPTION 'Player does not belong to authenticated user'; END IF;
  IF v_auth_user IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  IF p_quantity<=0 THEN RAISE EXCEPTION 'Quantity must be greater than 0'; END IF;
  SELECT p.player_id INTO v_planet_player FROM public.planets p WHERE p.id=p_planet_id AND NOT p.is_destroyed FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Planet not found or destroyed'; END IF;
  IF v_planet_player<>p_player_id THEN RAISE EXCEPTION 'Planet does not belong to player'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.ship_definitions sd WHERE sd.id=p_ship_id) THEN RAISE EXCEPTION 'Unknown ship: %',p_ship_id; END IF;
  PERFORM public.process_planet_tick(p_planet_id);
  SELECT r.reason INTO v_reason FROM public.check_ship_requirements(p_planet_id,p_ship_id) r WHERE NOT r.allowed LIMIT 1;
  IF v_reason IS NOT NULL THEN RAISE EXCEPTION '%',v_reason; END IF;
  SELECT c.metal,c.crystal,c.deuterium INTO v_metal,v_crystal,v_deuterium FROM public.calculate_ship_cost(p_ship_id,p_quantity) c;
  SELECT pr.metal,pr.crystal,pr.deuterium INTO v_metal_available,v_crystal_available,v_deuterium_available FROM public.planet_resources pr WHERE pr.planet_id=p_planet_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Planet resources not found'; END IF;
  IF v_metal_available<v_metal THEN RAISE EXCEPTION 'Not enough metal'; END IF;
  IF v_crystal_available<v_crystal THEN RAISE EXCEPTION 'Not enough crystal'; END IF;
  IF v_deuterium_available<v_deuterium THEN RAISE EXCEPTION 'Not enough deuterium'; END IF;
  v_unit_time:=public.calculate_ship_build_time(p_planet_id,p_ship_id);
  v_total_time:=v_unit_time*p_quantity;
  SELECT GREATEST(
    COALESCE((SELECT MAX(sq.finishes_at) FROM public.shipyard_queue sq WHERE sq.planet_id=p_planet_id AND sq.status='BUILDING' AND sq.finishes_at>now()),now()),
    COALESCE((SELECT MAX(dq.finishes_at) FROM public.defense_queue dq WHERE dq.planet_id=p_planet_id AND dq.status='BUILDING' AND dq.finishes_at>now()),now())
  ) INTO v_started_at;
  v_finishes_at:=v_started_at+make_interval(secs=>v_total_time);
  UPDATE public.planet_resources SET metal=metal-v_metal,crystal=crystal-v_crystal,deuterium=deuterium-v_deuterium,updated_at=now() WHERE planet_id=p_planet_id;
  INSERT INTO public.shipyard_queue(planet_id,ship_id,quantity,started_at,finishes_at,status) VALUES(p_planet_id,p_ship_id,p_quantity,v_started_at,v_finishes_at,'BUILDING') RETURNING id INTO v_queue_id;
  RETURN QUERY SELECT v_queue_id,p_ship_id,p_quantity,v_started_at,v_finishes_at,v_metal,v_crystal,v_deuterium;
END;
$$;


CREATE OR REPLACE FUNCTION "public"."start_defense"("p_player_id" "uuid", "p_planet_id" "uuid", "p_defense_id" "text", "p_quantity" bigint DEFAULT 1) RETURNS TABLE("queue_id" "uuid", "defense_id" "text", "quantity" bigint, "started_at" timestamp with time zone, "finishes_at" timestamp with time zone, "metal_cost" numeric, "crystal_cost" numeric, "deuterium_cost" numeric)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_planet_player uuid;
  v_reason text;
  v_metal numeric;
  v_crystal numeric;
  v_deuterium numeric;
  v_metal_available numeric;
  v_crystal_available numeric;
  v_deuterium_available numeric;
  v_unit_time numeric;
  v_total_time numeric;
  v_started_at timestamptz;
  v_finishes_at timestamptz;
  v_queue_id uuid;
  v_auth_user uuid;
BEGIN
  v_auth_user := auth.uid();
  IF v_auth_user IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.players pl WHERE pl.id=p_player_id AND pl.user_id=v_auth_user) THEN
    RAISE EXCEPTION 'Player does not belong to authenticated user';
  END IF;
  IF v_auth_user IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;
  IF p_quantity <= 0 THEN RAISE EXCEPTION 'Quantity must be greater than 0'; END IF;

  SELECT p.player_id INTO v_planet_player
  FROM public.planets p
  WHERE p.id=p_planet_id AND NOT p.is_destroyed
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Planet not found or destroyed'; END IF;
  IF v_planet_player <> p_player_id THEN RAISE EXCEPTION 'Planet does not belong to player'; END IF;

  PERFORM public.process_planet_tick(p_planet_id);

  SELECT r.reason INTO v_reason
  FROM public.check_defense_requirements(p_planet_id,p_defense_id) r
  WHERE NOT r.allowed LIMIT 1;
  IF v_reason IS NOT NULL THEN RAISE EXCEPTION '%',v_reason; END IF;

  SELECT c.metal,c.crystal,c.deuterium INTO v_metal,v_crystal,v_deuterium
  FROM public.calculate_defense_cost(p_defense_id,p_quantity) c;

  SELECT pr.metal,pr.crystal,pr.deuterium
  INTO v_metal_available,v_crystal_available,v_deuterium_available
  FROM public.planet_resources pr
  WHERE pr.planet_id=p_planet_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Planet resources not found'; END IF;
  IF v_metal_available < v_metal THEN RAISE EXCEPTION 'Not enough metal'; END IF;
  IF v_crystal_available < v_crystal THEN RAISE EXCEPTION 'Not enough crystal'; END IF;
  IF v_deuterium_available < v_deuterium THEN RAISE EXCEPTION 'Not enough deuterium'; END IF;

  IF p_defense_id IN ('small_shield_dome','large_shield_dome') AND (
    EXISTS (
      SELECT 1 FROM public.planet_defenses pd
      WHERE pd.planet_id=p_planet_id AND pd.defense_id=p_defense_id AND pd.quantity > 0
    )
    OR EXISTS (
      SELECT 1 FROM public.defense_queue dq
      WHERE dq.planet_id=p_planet_id AND dq.defense_id=p_defense_id AND dq.status='BUILDING'
    )
  ) THEN
    RAISE EXCEPTION 'Shield dome already exists or is queued';
  END IF;

  v_unit_time := public.calculate_defense_build_time(p_planet_id,p_defense_id);
  v_total_time := v_unit_time * p_quantity;

  SELECT GREATEST(
    COALESCE((SELECT MAX(sq.finishes_at) FROM public.shipyard_queue sq WHERE sq.planet_id=p_planet_id AND sq.status='BUILDING' AND sq.finishes_at>now()),now()),
    COALESCE((SELECT MAX(dq.finishes_at) FROM public.defense_queue dq WHERE dq.planet_id=p_planet_id AND dq.status='BUILDING' AND dq.finishes_at>now()),now())
  ) INTO v_started_at;
  v_finishes_at := v_started_at + make_interval(secs => v_total_time);

  UPDATE public.planet_resources
  SET metal=metal-v_metal,crystal=crystal-v_crystal,deuterium=deuterium-v_deuterium,updated_at=now()
  WHERE planet_id=p_planet_id;

  INSERT INTO public.defense_queue(planet_id,defense_id,quantity,started_at,finishes_at,status)
  VALUES(p_planet_id,p_defense_id,p_quantity,v_started_at,v_finishes_at,'BUILDING')
  RETURNING id INTO v_queue_id;

  RETURN QUERY SELECT v_queue_id,p_defense_id,p_quantity,v_started_at,v_finishes_at,v_metal,v_crystal,v_deuterium;
END;
$$;


CREATE OR REPLACE FUNCTION "public"."start_fleet"("p_player_id" "uuid", "p_origin_planet_id" "uuid", "p_destination_planet_id" "uuid", "p_ship_id" "text", "p_quantity" bigint, "p_mission_type" "text" DEFAULT 'TRANSPORT'::"text") RETURNS TABLE("fleet_id" "uuid", "ship_id" "text", "quantity" bigint, "origin_planet_id" "uuid", "destination_planet_id" "uuid", "mission_type" "text", "started_at" timestamp with time zone, "arrives_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$ DECLARE v_mission_type text:=upper(p_mission_type); v_fleet_id uuid; v_planet_player uuid; v_universe_id uuid; v_available bigint; v_dest_galaxy int; v_dest_system int; v_dest_position int; v_origin_galaxy int; v_origin_system int; v_origin_position int; v_distance numeric; v_ship_speed numeric; v_fleet_speed numeric; v_evolution numeric; v_fleet_rate numeric; v_travel_time numeric; v_started_at timestamptz; v_arrives_at timestamptz; v_bonus numeric:=1; v_slots int; v_fuel numeric:=0; v_resources record; v_auth_user uuid; BEGIN v_auth_user:=auth.uid(); IF v_auth_user IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.players pl WHERE pl.id=p_player_id AND pl.user_id=v_auth_user) THEN RAISE EXCEPTION 'Player does not belong to authenticated user'; END IF; IF v_auth_user IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF; IF p_quantity<=0 THEN RAISE EXCEPTION 'Fleet quantity must be greater than 0'; END IF; IF v_mission_type NOT IN ('ATTACK','TRANSPORT','DEPLOY','ESPIONAGE','RECYCLE','EXPEDITION') THEN RAISE EXCEPTION 'Invalid mission type: %',v_mission_type; END IF; SELECT p.player_id,p.universe_id,p.galaxy,p.system,p.position INTO v_planet_player,v_universe_id,v_origin_galaxy,v_origin_system,v_origin_position FROM public.planets p WHERE p.id=p_origin_planet_id AND NOT p.is_destroyed FOR UPDATE; IF NOT FOUND OR v_planet_player<>p_player_id THEN RAISE EXCEPTION 'Origin planet does not belong to player'; END IF; IF v_mission_type='EXPEDITION' THEN p_destination_planet_id:=NULL; v_dest_galaxy:=v_origin_galaxy; v_dest_system:=v_origin_system; v_dest_position:=16; v_slots:=public.get_player_expedition_slots(p_player_id); IF public.get_active_expedition_count(p_player_id)>=v_slots THEN RAISE EXCEPTION 'EXPEDITION_SLOTS_FULL: %/%',public.get_active_expedition_count(p_player_id),v_slots; END IF; ELSIF v_mission_type='RECYCLE' THEN IF v_ship_id<>'recycler' THEN RAISE EXCEPTION 'RECYCLE mission requires recycler'; END IF; SELECT df.galaxy,df.system,df.position INTO v_dest_galaxy,v_dest_system,v_dest_position FROM public.debris_fields df WHERE df.universe_id=v_universe_id AND (df.metal>0 OR df.crystal>0) ORDER BY abs(df.galaxy-v_origin_galaxy),abs(df.system-v_origin_system),abs(df.position-v_origin_position) LIMIT 1 FOR UPDATE; IF NOT FOUND THEN RAISE EXCEPTION 'No debris field available for RECYCLE'; END IF; ELSE IF p_destination_planet_id IS NULL THEN RAISE EXCEPTION 'Destination planet is required for %',v_mission_type; END IF; IF p_origin_planet_id=p_destination_planet_id THEN RAISE EXCEPTION 'Origin and destination planets must be different'; END IF; SELECT galaxy,system,position INTO v_dest_galaxy,v_dest_system,v_dest_position FROM public.planets WHERE id=p_destination_planet_id AND universe_id=v_universe_id AND NOT is_destroyed; IF NOT FOUND THEN RAISE EXCEPTION 'Destination planet not found, destroyed, or belongs to another universe'; END IF; END IF; IF NOT EXISTS(SELECT 1 FROM public.ship_definitions WHERE id=p_ship_id) THEN RAISE EXCEPTION 'Unknown ship: %',p_ship_id; END IF; SELECT ps.quantity INTO v_available FROM public.planet_ships ps WHERE ps.planet_id=p_origin_planet_id AND ps.ship_id=p_ship_id FOR UPDATE; IF coalesce(v_available,0)<p_quantity THEN RAISE EXCEPTION 'Not enough %: available %, requested %',p_ship_id,coalesce(v_available,0),p_quantity; END IF; IF v_origin_galaxy<>v_dest_galaxy THEN v_distance:=20000*abs(v_origin_galaxy-v_dest_galaxy); ELSIF v_origin_system<>v_dest_system THEN v_distance:=2700+95*abs(v_origin_system-v_dest_system); ELSIF v_origin_position<>v_dest_position THEN v_distance:=1000+5*abs(v_origin_position-v_dest_position); ELSE v_distance:=5; END IF; v_fuel:=public.calculate_fleet_fuel_for_distance(v_distance,p_ship_id,p_quantity); PERFORM public.update_planet_resources_until(p_origin_planet_id,now()); SELECT * INTO v_resources FROM public.planet_resources pr WHERE pr.planet_id=p_origin_planet_id FOR UPDATE; IF NOT FOUND THEN RAISE EXCEPTION 'Planet resources not found'; END IF; IF v_resources.deuterium<v_fuel THEN RAISE EXCEPTION 'Insufficient deuterium for fleet fuel: required %, available %',v_fuel,v_resources.deuterium; END IF; SELECT speed INTO v_ship_speed FROM public.ship_definitions WHERE id=p_ship_id; SELECT fleet_speed INTO v_fleet_speed FROM public.universes WHERE id=v_universe_id; v_evolution:=public.calculate_universe_evolution_rate(v_universe_id); v_bonus:=1+(coalesce(public.get_active_expedition_item_effect(p_player_id,p_origin_planet_id,'fleet_speed_percent'),0)+coalesce(public.get_active_lifeform_research_effect(p_player_id,'fleet_speed_percent'),0))/100; v_fleet_rate:=v_fleet_speed*power(v_evolution,1.0/3.0)*v_bonus; IF v_mission_type='EXPEDITION' THEN v_travel_time:=((35000/100)*sqrt(v_distance*10/v_ship_speed)+10)/(coalesce((SELECT expedition_speed FROM public.universes WHERE id=v_universe_id),1)*power(v_evolution,1.0/3.0)*v_bonus); ELSE v_travel_time:=(v_distance/v_ship_speed)*3600/v_fleet_rate; END IF; v_travel_time:=greatest(v_travel_time,1); v_started_at:=now(); v_arrives_at:=v_started_at+(v_travel_time*interval '1 second'); UPDATE public.planet_resources SET deuterium=deuterium-v_fuel,updated_at=clock_timestamp() WHERE planet_id=p_origin_planet_id; UPDATE public.planet_ships SET quantity=quantity-p_quantity WHERE planet_id=p_origin_planet_id AND ship_id=p_ship_id; INSERT INTO public.fleet_movements(player_id,origin_planet_id,destination_planet_id,mission_type,started_at,arrives_at,status,destination_galaxy,destination_system,destination_position,expedition_hold_seconds,fuel_consumed) VALUES(p_player_id,p_origin_planet_id,p_destination_planet_id,v_mission_type,v_started_at,v_arrives_at,'OUTBOUND',v_dest_galaxy,v_dest_system,v_dest_position,3600,v_fuel) RETURNING id INTO v_fleet_id; INSERT INTO public.fleet_movement_ships(fleet_id,ship_id,quantity) VALUES(v_fleet_id,p_ship_id,p_quantity); RETURN QUERY SELECT v_fleet_id,p_ship_id,p_quantity,p_origin_planet_id,p_destination_planet_id,v_mission_type,v_started_at,v_arrives_at; END; $$;


CREATE OR REPLACE FUNCTION "public"."sync_current_planet_resources"("p_player_id" "uuid", "p_planet_id" "uuid", "p_until" timestamp with time zone DEFAULT "now"()) RETURNS TABLE("planet_id" "uuid", "metal" numeric, "crystal" numeric, "deuterium" numeric, "energy" numeric, "elapsed_seconds" numeric, "metal_produced" numeric, "crystal_produced" numeric, "deuterium_produced" numeric)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare
  v_auth_user uuid;
  v_is_guest boolean;
begin
  v_auth_user := auth.uid();

  select coalesce(pl.is_guest, false)
    into v_is_guest
  from public.players pl
  where pl.id = p_player_id;

  if not found then
    raise exception 'PLAYER_NOT_FOUND';
  end if;

  if v_auth_user is null then
    raise exception 'AUTHENTICATION_REQUIRED';
  end if;

  if not exists (
    select 1
    from public.players pl
    where pl.id = p_player_id
      and pl.user_id = v_auth_user
  ) then
    raise exception 'PLAYER_ACCESS_DENIED';
  end if;

  if not exists (
    select 1
    from public.planets p
    where p.id = p_planet_id
      and p.player_id = p_player_id
      and p.is_destroyed = false
  ) then
    raise exception 'PLANET_NOT_FOUND_OR_NOT_OWNED';
  end if;

  return query
  select *
  from public.update_planet_resources_until(p_planet_id, p_until);
end;
$$;


