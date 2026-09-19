CREATE OR REPLACE FUNCTION public.update_planet_resources_until_raw(
    p_planet_id uuid,
    p_until timestamptz
)
RETURNS TABLE(
    planet_id uuid,
    metal numeric,
    crystal numeric,
    deuterium numeric,
    energy numeric,
    elapsed_seconds numeric,
    metal_produced numeric,
    crystal_produced numeric,
    deuterium_produced numeric
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
declare
    v_last_calculated_at timestamptz;
    v_metal numeric;
    v_crystal numeric;
    v_deuterium numeric;
    v_energy numeric;
    v_elapsed_seconds numeric;
    v_metal_per_hour numeric;
    v_crystal_per_hour numeric;
    v_deuterium_per_hour numeric;
    v_weighted_evolution_seconds numeric;
    v_economy_rate numeric;
    v_production_rate numeric;
    v_current_combined_rate numeric;
    v_metal_base_per_hour numeric;
    v_crystal_base_per_hour numeric;
    v_deuterium_base_per_hour numeric;
    v_metal_produced numeric;
    v_crystal_produced numeric;
    v_deuterium_produced numeric;
    v_metal_capacity numeric;
    v_crystal_capacity numeric;
    v_deuterium_capacity numeric;
    v_universe_id uuid;
begin
    select pr.last_calculated_at, pr.metal, pr.crystal, pr.deuterium, pr.energy
      into v_last_calculated_at, v_metal, v_crystal, v_deuterium, v_energy
    from public.planet_resources pr
    where pr.planet_id = p_planet_id
    for update;

    if not found then raise exception 'PLANET_RESOURCES_NOT_FOUND'; end if;
    if p_until < v_last_calculated_at then raise exception 'INVALID_RESOURCE_TIMESTAMP'; end if;

    select p.universe_id into v_universe_id
    from public.planets p where p.id = p_planet_id;
    if v_universe_id is null then raise exception 'PLANET_NOT_FOUND'; end if;

    v_elapsed_seconds := greatest(0, extract(epoch from (p_until - v_last_calculated_at)));

    select pp.metal_per_hour, pp.crystal_per_hour, pp.deuterium_per_hour
      into v_metal_per_hour, v_crystal_per_hour, v_deuterium_per_hour
    from public.calculate_planet_production(p_planet_id) pp;

    select r.economy, r.production
      into v_economy_rate, v_production_rate
    from public.calculate_universe_rates(v_universe_id) r;

    v_current_combined_rate := v_economy_rate * v_production_rate;
    v_weighted_evolution_seconds := public.calculate_universe_evolution_production_seconds(v_universe_id, v_last_calculated_at, p_until);

    if v_current_combined_rate > 0 then
        v_metal_base_per_hour := v_metal_per_hour / v_current_combined_rate;
        v_crystal_base_per_hour := v_crystal_per_hour / v_current_combined_rate;
        v_deuterium_base_per_hour := v_deuterium_per_hour / v_current_combined_rate;
        v_metal_produced := v_metal_base_per_hour * v_weighted_evolution_seconds / 3600.0;
        v_crystal_produced := v_crystal_base_per_hour * v_weighted_evolution_seconds / 3600.0;
        v_deuterium_produced := v_deuterium_base_per_hour * v_weighted_evolution_seconds / 3600.0;
    else
        v_metal_produced := 0; v_crystal_produced := 0; v_deuterium_produced := 0;
    end if;

    select s.metal_capacity, s.crystal_capacity, s.deuterium_capacity
      into v_metal_capacity, v_crystal_capacity, v_deuterium_capacity
    from public.calculate_planet_storage(p_planet_id) s;

    v_metal := least(v_metal_capacity, greatest(0, v_metal + v_metal_produced));
    v_crystal := least(v_crystal_capacity, greatest(0, v_crystal + v_crystal_produced));
    v_deuterium := least(v_deuterium_capacity, greatest(0, v_deuterium + v_deuterium_produced));

    update public.planet_resources pr
       set metal = v_metal, crystal = v_crystal, deuterium = v_deuterium,
           last_calculated_at = p_until, updated_at = now()
     where pr.planet_id = p_planet_id;

    planet_id := p_planet_id; metal := v_metal; crystal := v_crystal; deuterium := v_deuterium; energy := v_energy;
    elapsed_seconds := v_elapsed_seconds; metal_produced := v_metal_produced; crystal_produced := v_crystal_produced; deuterium_produced := v_deuterium_produced;
    return next;
end;
$function$;

CREATE OR REPLACE FUNCTION public.complete_building(p_queue_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_queue public.building_queue%rowtype;
    v_current_level integer;
BEGIN
    SELECT * INTO v_queue FROM public.building_queue WHERE id = p_queue_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'BUILDING_QUEUE_NOT_FOUND'; END IF;
    IF UPPER(v_queue.status) = 'COMPLETED' THEN RETURN v_queue.target_level; END IF;
    IF UPPER(v_queue.status) <> 'BUILDING' THEN RAISE EXCEPTION 'BUILDING_QUEUE_NOT_ACTIVE'; END IF;
    IF v_queue.finishes_at > now() THEN RAISE EXCEPTION 'BUILDING_NOT_FINISHED'; END IF;

    PERFORM 1 FROM public.planets WHERE id = v_queue.planet_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'PLANET_NOT_FOUND'; END IF;

    -- Raw settlement is used here because the public temporal wrapper may already
    -- be walking this exact queue event. This prevents recursive event processing.
    PERFORM * FROM public.update_planet_resources_until_raw(v_queue.planet_id, v_queue.finishes_at);

    SELECT pb.level INTO v_current_level
    FROM public.planet_buildings pb
    WHERE pb.planet_id = v_queue.planet_id AND pb.building_id = v_queue.building_id
    FOR UPDATE;
    v_current_level := COALESCE(v_current_level, 0);

    IF v_queue.target_level <> v_current_level + 1 THEN
        RAISE EXCEPTION 'BUILDING_LEVEL_MISMATCH: current=%, target=%', v_current_level, v_queue.target_level;
    END IF;

    INSERT INTO public.planet_buildings(planet_id, building_id, level)
    VALUES(v_queue.planet_id, v_queue.building_id, v_queue.target_level)
    ON CONFLICT(planet_id, building_id) DO UPDATE SET level = EXCLUDED.level;

    UPDATE public.planets SET fields_used = fields_used + 1 WHERE id = v_queue.planet_id;
    UPDATE public.building_queue SET status = 'COMPLETED' WHERE id = p_queue_id;
    RETURN v_queue.target_level;
END;
$function$;

CREATE OR REPLACE FUNCTION public.complete_research(p_queue_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
declare
    v_player_id uuid;
    v_planet_id uuid;
    v_research_id text;
    v_target_level integer;
    v_status text;
    v_finishes_at timestamptz;
begin
    select player_id, planet_id, research_id, target_level, status, finishes_at
      into v_player_id, v_planet_id, v_research_id, v_target_level, v_status, v_finishes_at
    from public.research_queue
    where id = p_queue_id
    for update;

    if not found then raise exception 'Research queue does not exist: %', p_queue_id; end if;
    if v_status <> 'RESEARCHING' then raise exception 'Research queue is not active. Current status: %', v_status; end if;
    if v_finishes_at > now() then raise exception 'Research is not finished yet. Finishes at: %', v_finishes_at; end if;

    if v_planet_id is not null then
        perform public.update_planet_resources_until_raw(v_planet_id, v_finishes_at);
    end if;

    insert into public.player_research(player_id, research_id, level)
    values(v_player_id, v_research_id, v_target_level)
    on conflict(player_id, research_id) do update set level = excluded.level;

    update public.research_queue set status = 'COMPLETED' where id = p_queue_id;
    return true;
end;
$function$;

CREATE OR REPLACE FUNCTION public.update_planet_resources_until(
    p_planet_id uuid,
    p_until timestamptz
)
RETURNS TABLE(
    planet_id uuid,
    metal numeric,
    crystal numeric,
    deuterium numeric,
    energy numeric,
    elapsed_seconds numeric,
    metal_produced numeric,
    crystal_produced numeric,
    deuterium_produced numeric
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
declare
    v_player_id uuid;
    v_last_calculated_at timestamptz;
    v_event_id uuid;
    v_event_at timestamptz;
    v_event_type text;
    v_raw record;
    v_final record;
begin
    select p.player_id, pr.last_calculated_at
      into v_player_id, v_last_calculated_at
    from public.planets p
    join public.planet_resources pr on pr.planet_id = p.id
    where p.id = p_planet_id
    for update of pr;

    if not found then raise exception 'PLANET_RESOURCES_NOT_FOUND'; end if;
    if p_until < v_last_calculated_at then raise exception 'INVALID_RESOURCE_TIMESTAMP'; end if;

    -- Walk every economic event between the current resource clock and the
    -- requested timestamp. This is the crucial offline/catch-up boundary: a
    -- late fleet/transport/espionage event must not make current building or
    -- research production apply retroactively to an earlier interval.
    loop
        v_event_id := null;
        v_event_at := null;
        v_event_type := null;

        select q.id, q.finishes_at, 'BUILDING'
          into v_event_id, v_event_at, v_event_type
        from public.building_queue q
        where q.planet_id = p_planet_id
          and upper(q.status) = 'BUILDING'
          and q.finishes_at > v_last_calculated_at
          and q.finishes_at <= p_until
        order by q.finishes_at, q.created_at, q.id
        limit 1;

        if v_player_id is not null then
            declare
                r_id uuid;
                r_at timestamptz;
            begin
                select q.id, q.finishes_at into r_id, r_at
                from public.research_queue q
                where q.player_id = v_player_id
                  and upper(q.status) = 'RESEARCHING'
                  and q.finishes_at > v_last_calculated_at
                  and q.finishes_at <= p_until
                order by q.finishes_at, q.created_at, q.id
                limit 1;

                if r_id is not null and (v_event_at is null or r_at < v_event_at or (r_at = v_event_at and r_id::text < v_event_id::text)) then
                    v_event_id := r_id;
                    v_event_at := r_at;
                    v_event_type := 'RESEARCH';
                end if;
            end;
        end if;

        if v_event_id is null then exit; end if;

        select * into v_raw from public.update_planet_resources_until_raw(p_planet_id, v_event_at);

        if v_event_type = 'BUILDING' then
            perform public.complete_building(v_event_id);
        else
            perform public.complete_research(v_event_id);
        end if;

        select pr.last_calculated_at into v_last_calculated_at
        from public.planet_resources pr
        where pr.planet_id = p_planet_id;
    end loop;

    select * into v_final from public.update_planet_resources_until_raw(p_planet_id, p_until);

    return query
    select v_final.planet_id, v_final.metal, v_final.crystal, v_final.deuterium,
           v_final.energy, v_final.elapsed_seconds, v_final.metal_produced,
           v_final.crystal_produced, v_final.deuterium_produced;
end;
$function$;

-- Mixed fleets acquire all ship rows in deterministic order. This removes a
-- deadlock window when two concurrent mixed-fleet launches use the same planet
-- with different JSON key order.
CREATE OR REPLACE FUNCTION public.start_fleet_mixed(
  p_player_id uuid, p_origin_planet_id uuid, p_destination_planet_id uuid,
  p_ships jsonb, p_mission_type text DEFAULT 'TRANSPORT'
)
RETURNS TABLE(fleet_id uuid, ship_id text, quantity bigint, origin_planet_id uuid,
              destination_planet_id uuid, mission_type text, started_at timestamptz,
              arrives_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_mission_type text := upper(p_mission_type);
  v_fleet_id uuid; v_planet_player uuid; v_universe_id uuid;
  v_dest_galaxy integer; v_dest_system integer; v_dest_position integer;
  v_origin_galaxy integer; v_origin_system integer; v_origin_position integer;
  v_distance numeric; v_min_ship_speed numeric := NULL; v_ship_speed numeric;
  v_fleet_speed numeric; v_evolution numeric; v_fleet_rate numeric;
  v_travel_time numeric; v_started_at timestamptz; v_arrives_at timestamptz;
  v_bonus numeric := 1; v_slots integer; v_auth_user uuid;
  v_ship_id text; v_quantity bigint; v_available bigint; v_count integer := 0;
BEGIN
  v_auth_user := auth.uid();
  IF v_auth_user IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.players pl WHERE pl.id=p_player_id AND pl.user_id=v_auth_user) THEN
    RAISE EXCEPTION 'Player does not belong to authenticated user';
  END IF;
  IF v_auth_user IS NULL AND NOT EXISTS (SELECT 1 FROM public.players pl WHERE pl.id=p_player_id AND coalesce(pl.is_guest,false)=true) THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;
  IF p_ships IS NULL OR jsonb_typeof(p_ships)<>'object' OR p_ships='{}'::jsonb THEN RAISE EXCEPTION 'Fleet composition must be a non-empty JSON object'; END IF;
  IF v_mission_type NOT IN ('ATTACK','TRANSPORT','DEPLOY','ESPIONAGE','RECYCLE','EXPEDITION') THEN RAISE EXCEPTION 'Invalid mission type: %',v_mission_type; END IF;

  SELECT p.player_id,p.universe_id,p.galaxy,p.system,p.position
  INTO v_planet_player,v_universe_id,v_origin_galaxy,v_origin_system,v_origin_position
  FROM public.planets p WHERE p.id=p_origin_planet_id AND NOT p.is_destroyed FOR UPDATE;
  IF NOT FOUND OR v_planet_player<>p_player_id THEN RAISE EXCEPTION 'Origin planet does not belong to player'; END IF;

  IF v_mission_type='EXPEDITION' THEN
    p_destination_planet_id:=NULL; v_dest_galaxy:=v_origin_galaxy; v_dest_system:=v_origin_system; v_dest_position:=16;
    v_slots:=public.get_player_expedition_slots(p_player_id);
    IF public.get_active_expedition_count(p_player_id)>=v_slots THEN RAISE EXCEPTION 'EXPEDITION_SLOTS_FULL: %/%',public.get_active_expedition_count(p_player_id),v_slots; END IF;
  ELSIF v_mission_type='RECYCLE' THEN
    SELECT df.galaxy,df.system,df.position INTO v_dest_galaxy,v_dest_system,v_dest_position
    FROM public.debris_fields df WHERE df.universe_id=v_universe_id AND (df.metal>0 OR df.crystal>0)
    ORDER BY abs(df.galaxy-v_origin_galaxy),abs(df.system-v_origin_system),abs(df.position-v_origin_position),df.id
    LIMIT 1 FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'No debris field available for RECYCLE'; END IF;
    p_destination_planet_id:=NULL;
  ELSE
    IF p_destination_planet_id IS NULL THEN RAISE EXCEPTION 'Destination planet is required for %',v_mission_type; END IF;
    IF p_origin_planet_id=p_destination_planet_id THEN RAISE EXCEPTION 'Origin and destination planets must be different'; END IF;
    SELECT galaxy,system,position INTO v_dest_galaxy,v_dest_system,v_dest_position
    FROM public.planets WHERE id=p_destination_planet_id AND universe_id=v_universe_id AND NOT is_destroyed;
    IF NOT FOUND THEN RAISE EXCEPTION 'Destination planet not found, destroyed, or belongs to another universe'; END IF;
  END IF;

  -- First lock/validate every ship row in deterministic ship_id order.
  FOR v_ship_id,v_quantity IN SELECT key,value::bigint FROM jsonb_each_text(p_ships) ORDER BY key LOOP
    v_count:=v_count+1;
    IF v_ship_id IS NULL OR v_ship_id='' OR v_quantity IS NULL OR v_quantity<=0 THEN RAISE EXCEPTION 'Invalid fleet composition entry: % = %',v_ship_id,v_quantity; END IF;
    IF NOT EXISTS (SELECT 1 FROM public.ship_definitions WHERE id=v_ship_id) THEN RAISE EXCEPTION 'Unknown ship: %',v_ship_id; END IF;
    SELECT ps.quantity INTO v_available FROM public.planet_ships ps WHERE ps.planet_id=p_origin_planet_id AND ps.ship_id=v_ship_id FOR UPDATE;
    IF coalesce(v_available,0)<v_quantity THEN RAISE EXCEPTION 'Not enough %: available %, requested %',v_ship_id,coalesce(v_available,0),v_quantity; END IF;
    SELECT sd.speed INTO v_ship_speed FROM public.ship_definitions sd WHERE sd.id=v_ship_id;
    IF v_ship_speed IS NULL OR v_ship_speed<=0 THEN RAISE EXCEPTION 'Ship % cannot participate in a fleet because its speed is %',v_ship_id,v_ship_speed; END IF;
    v_min_ship_speed:=CASE WHEN v_min_ship_speed IS NULL THEN v_ship_speed ELSE least(v_min_ship_speed,v_ship_speed) END;
    IF v_mission_type='RECYCLE' AND v_ship_id<>'recycler' THEN RAISE EXCEPTION 'RECYCLE mixed fleet may contain only recyclers'; END IF;
  END LOOP;
  IF v_count=0 OR v_min_ship_speed IS NULL THEN RAISE EXCEPTION 'Fleet composition contains no usable ships'; END IF;

  IF v_origin_galaxy<>v_dest_galaxy THEN v_distance:=20000*abs(v_origin_galaxy-v_dest_galaxy);
  ELSIF v_origin_system<>v_dest_system THEN v_distance:=2700+95*abs(v_origin_system-v_dest_system);
  ELSIF v_origin_position<>v_dest_position THEN v_distance:=1000+5*abs(v_origin_position-v_dest_position);
  ELSE v_distance:=5; END IF;

  SELECT fleet_speed INTO v_fleet_speed FROM public.universes WHERE id=v_universe_id;
  v_evolution:=public.calculate_universe_evolution_rate(v_universe_id);
  v_bonus:=1+(coalesce(public.get_active_expedition_item_effect(p_player_id,p_origin_planet_id,'fleet_speed_percent'),0)+coalesce(public.get_active_lifeform_research_effect(p_player_id,'fleet_speed_percent'),0))/100;
  v_fleet_rate:=v_fleet_speed*power(v_evolution,1.0/3.0)*v_bonus;
  IF v_mission_type='EXPEDITION' THEN
    v_travel_time:=((35000/100)*sqrt(v_distance*10/v_min_ship_speed)+10)/(coalesce((select expedition_speed from public.universes where id=v_universe_id),1)*power(v_evolution,1.0/3.0)*v_bonus);
  ELSE
    v_travel_time:=(v_distance/v_min_ship_speed)*3600/v_fleet_rate;
  END IF;
  v_travel_time:=greatest(v_travel_time,1); v_started_at:=now(); v_arrives_at:=v_started_at+(v_travel_time*interval '1 second');

  FOR v_ship_id,v_quantity IN SELECT key,value::bigint FROM jsonb_each_text(p_ships) ORDER BY key LOOP
    UPDATE public.planet_ships ps SET quantity=ps.quantity-v_quantity WHERE ps.planet_id=p_origin_planet_id AND ps.ship_id=v_ship_id;
  END LOOP;

  INSERT INTO public.fleet_movements(player_id,origin_planet_id,destination_planet_id,mission_type,started_at,arrives_at,status,destination_galaxy,destination_system,destination_position,expedition_hold_seconds)
  VALUES(p_player_id,p_origin_planet_id,p_destination_planet_id,v_mission_type,v_started_at,v_arrives_at,'OUTBOUND',v_dest_galaxy,v_dest_system,v_dest_position,3600)
  RETURNING id INTO v_fleet_id;

  INSERT INTO public.fleet_movement_ships(fleet_id,ship_id,quantity)
  SELECT v_fleet_id,key,value::bigint FROM jsonb_each_text(p_ships) ORDER BY key;

  RETURN QUERY SELECT v_fleet_id,fms.ship_id,fms.quantity,p_origin_planet_id,p_destination_planet_id,v_mission_type,v_started_at,v_arrives_at
  FROM public.fleet_movement_ships fms WHERE fms.fleet_id=v_fleet_id ORDER BY fms.ship_id;
END;
$function$;