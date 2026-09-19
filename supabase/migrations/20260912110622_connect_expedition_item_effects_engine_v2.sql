CREATE OR REPLACE FUNCTION public.get_player_expedition_slots(p_player_id uuid)
RETURNS integer LANGUAGE sql STABLE AS $function$
    SELECT 1 + floor(COALESCE(public.get_active_expedition_item_effect(p_player_id,NULL,'expedition_slots'),0))::integer;
$function$;

CREATE OR REPLACE FUNCTION public.get_active_expedition_count(p_player_id uuid)
RETURNS integer LANGUAGE sql STABLE AS $function$
    SELECT count(*)::integer
    FROM public.fleet_movements
    WHERE player_id=p_player_id
      AND mission_type='EXPEDITION'
      AND status IN ('OUTBOUND','ARRIVED','RETURNING');
$function$;

CREATE OR REPLACE FUNCTION public.calculate_planet_production(p_planet_id uuid)
RETURNS TABLE(metal_per_hour numeric, crystal_per_hour numeric, deuterium_per_hour numeric, energy_per_hour numeric)
LANGUAGE plpgsql STABLE AS $function$
DECLARE
    v_universe_id uuid; v_player_id uuid;
    v_metal_level integer:=0; v_crystal_level integer:=0; v_deuterium_level integer:=0; v_solar_level integer:=0;
    v_economy_rate numeric; v_production_rate numeric; v_item_bonus numeric:=0;
BEGIN
    SELECT p.universe_id,p.player_id INTO v_universe_id,v_player_id FROM public.planets p WHERE p.id=p_planet_id;
    IF v_universe_id IS NULL THEN RAISE EXCEPTION 'Planet % does not exist',p_planet_id; END IF;
    SELECT r.economy,r.production INTO v_economy_rate,v_production_rate FROM public.calculate_universe_rates(v_universe_id) r;
    SELECT COALESCE(MAX(level),0) INTO v_metal_level FROM public.planet_buildings WHERE planet_id=p_planet_id AND building_id='metal_mine';
    SELECT COALESCE(MAX(level),0) INTO v_crystal_level FROM public.planet_buildings WHERE planet_id=p_planet_id AND building_id='crystal_mine';
    SELECT COALESCE(MAX(level),0) INTO v_deuterium_level FROM public.planet_buildings WHERE planet_id=p_planet_id AND building_id='deuterium_synthesizer';
    SELECT COALESCE(MAX(level),0) INTO v_solar_level FROM public.planet_buildings WHERE planet_id=p_planet_id AND building_id='solar_plant';
    v_item_bonus:=public.get_active_expedition_item_effect(v_player_id,p_planet_id,'production_percent');
    RETURN QUERY SELECT
      30*v_metal_level*power(1.1,v_metal_level)*v_economy_rate*v_production_rate*(1+v_item_bonus/100),
      20*v_crystal_level*power(1.1,v_crystal_level)*v_economy_rate*v_production_rate*(1+v_item_bonus/100),
      10*v_deuterium_level*power(1.1,v_deuterium_level)*v_economy_rate*v_production_rate*(1+v_item_bonus/100),
      20*v_solar_level*power(1.1,v_solar_level)*v_economy_rate*v_production_rate*(1+v_item_bonus/100);
END;
$function$;

CREATE OR REPLACE FUNCTION public.calculate_planet_storage(p_planet_id uuid)
RETURNS TABLE(metal_capacity numeric, crystal_capacity numeric, deuterium_capacity numeric)
LANGUAGE plpgsql STABLE AS $function$
DECLARE v_metal_level integer:=0; v_crystal_level integer:=0; v_deuterium_level integer:=0; v_storage_multiplier numeric:=1; v_item_bonus numeric:=0; v_player_id uuid;
BEGIN
    SELECT p.player_id,COALESCE(u.storage_multiplier,1) INTO v_player_id,v_storage_multiplier FROM public.planets p JOIN public.universes u ON u.id=p.universe_id WHERE p.id=p_planet_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Planeta % no existe',p_planet_id; END IF;
    SELECT COALESCE(MAX(level),0) INTO v_metal_level FROM public.planet_buildings WHERE planet_id=p_planet_id AND building_id='metal_storage';
    SELECT COALESCE(MAX(level),0) INTO v_crystal_level FROM public.planet_buildings WHERE planet_id=p_planet_id AND building_id='crystal_storage';
    SELECT COALESCE(MAX(level),0) INTO v_deuterium_level FROM public.planet_buildings WHERE planet_id=p_planet_id AND building_id='deuterium_tank';
    v_item_bonus:=public.get_active_expedition_item_effect(v_player_id,p_planet_id,'storage_percent');
    v_storage_multiplier:=v_storage_multiplier*(1+v_item_bonus/100);
    metal_capacity:=100000*power(2,v_metal_level)*v_storage_multiplier;
    crystal_capacity:=100000*power(2,v_crystal_level)*v_storage_multiplier;
    deuterium_capacity:=100000*power(2,v_deuterium_level)*v_storage_multiplier;
    RETURN NEXT;
END;
$function$;

CREATE OR REPLACE FUNCTION public.start_building(p_player_id uuid,p_planet_id uuid,p_building_id text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $function$
DECLARE v_universe_id uuid; v_current_level integer; v_target_level integer; v_build_time numeric; v_metal_cost numeric; v_crystal_cost numeric; v_deuterium_cost numeric; v_queue_id uuid; v_item_bonus numeric:=0;
BEGIN
    SELECT universe_id INTO v_universe_id FROM planets WHERE id=p_planet_id AND player_id=p_player_id AND is_destroyed=false FOR UPDATE;
    IF v_universe_id IS NULL THEN RAISE EXCEPTION 'PLANET_NOT_FOUND_OR_NOT_OWNED'; END IF;
    SELECT COALESCE(MAX(level),0) INTO v_current_level FROM planet_buildings WHERE planet_id=p_planet_id AND building_id=p_building_id;
    v_target_level:=v_current_level+1;
    IF NOT EXISTS(SELECT 1 FROM building_definitions WHERE id=p_building_id) THEN RAISE EXCEPTION 'BUILDING_NOT_FOUND: %',p_building_id; END IF;
    IF EXISTS(SELECT 1 FROM building_definitions WHERE id=p_building_id AND max_level IS NOT NULL AND v_target_level>max_level) THEN RAISE EXCEPTION 'BUILDING_MAX_LEVEL_REACHED'; END IF;
    IF EXISTS(SELECT 1 FROM building_prerequisites bp LEFT JOIN planet_buildings pb ON pb.planet_id=p_planet_id AND pb.building_id=bp.prerequisite_building_id WHERE bp.building_id=p_building_id AND COALESCE(pb.level,0)<bp.required_level) THEN RAISE EXCEPTION 'BUILDING_PREREQUISITES_NOT_MET'; END IF;
    IF EXISTS(SELECT 1 FROM building_queue WHERE planet_id=p_planet_id AND UPPER(status) IN('BUILDING','QUEUED','ACTIVE')) THEN RAISE EXCEPTION 'BUILDING_QUEUE_ALREADY_ACTIVE'; END IF;
    IF EXISTS(SELECT 1 FROM planets WHERE id=p_planet_id AND fields_used>=fields_total) THEN RAISE EXCEPTION 'PLANET_FIELDS_FULL'; END IF;
    SELECT c.metal,c.crystal,c.deuterium INTO v_metal_cost,v_crystal_cost,v_deuterium_cost FROM calculate_building_cost(p_building_id,v_target_level) c;
    v_build_time:=calculate_building_time(p_building_id,v_target_level,v_universe_id);
    v_item_bonus:=get_active_expedition_item_effect(p_player_id,p_planet_id,'building_speed_percent');
    v_build_time:=round(v_build_time/(1+v_item_bonus/100),4);
    PERFORM update_planet_resources(p_planet_id);
    PERFORM 1 FROM planet_resources WHERE planet_id=p_planet_id FOR UPDATE;
    UPDATE planet_resources SET metal=metal-v_metal_cost,crystal=crystal-v_crystal_cost,deuterium=deuterium-v_deuterium_cost,updated_at=now() WHERE planet_id=p_planet_id AND metal>=v_metal_cost AND crystal>=v_crystal_cost AND deuterium>=v_deuterium_cost;
    IF NOT FOUND THEN RAISE EXCEPTION 'INSUFFICIENT_RESOURCES'; END IF;
    INSERT INTO building_queue(planet_id,building_id,target_level,started_at,finishes_at,status) VALUES(p_planet_id,p_building_id,v_target_level,now(),now()+(v_build_time*interval '1 second'),'BUILDING') RETURNING id INTO v_queue_id;
    RETURN v_queue_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.start_research(p_player_id uuid,p_planet_id uuid,p_research_id text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $function$
DECLARE v_universe_id uuid; v_current_level integer; v_target_level integer; v_research_time numeric; v_metal_cost numeric; v_crystal_cost numeric; v_deuterium_cost numeric; v_queue_id uuid; v_item_bonus numeric:=0;
BEGIN
    SELECT universe_id INTO v_universe_id FROM planets WHERE id=p_planet_id AND player_id=p_player_id AND is_destroyed=false FOR UPDATE;
    IF v_universe_id IS NULL THEN RAISE EXCEPTION 'PLANET_NOT_FOUND_OR_NOT_OWNED'; END IF;
    IF NOT EXISTS(SELECT 1 FROM research_definitions WHERE id=p_research_id) THEN RAISE EXCEPTION 'RESEARCH_NOT_FOUND: %',p_research_id; END IF;
    SELECT COALESCE(MAX(level),0) INTO v_current_level FROM player_research WHERE player_id=p_player_id AND research_id=p_research_id;
    v_target_level:=v_current_level+1;
    IF EXISTS(SELECT 1 FROM research_definitions WHERE id=p_research_id AND max_level IS NOT NULL AND v_target_level>max_level) THEN RAISE EXCEPTION 'RESEARCH_MAX_LEVEL_REACHED'; END IF;
    IF EXISTS(SELECT 1 FROM research_queue WHERE player_id=p_player_id AND UPPER(status) IN('RESEARCHING','QUEUED','ACTIVE')) THEN RAISE EXCEPTION 'RESEARCH_QUEUE_ALREADY_ACTIVE'; END IF;
    SELECT c.metal,c.crystal,c.deuterium INTO v_metal_cost,v_crystal_cost,v_deuterium_cost FROM calculate_research_cost(p_research_id,v_target_level) c;
    v_research_time:=calculate_research_time(p_research_id,v_target_level,v_universe_id);
    v_item_bonus:=get_active_expedition_item_effect(p_player_id,p_planet_id,'research_speed_percent');
    v_research_time:=round(v_research_time/(1+v_item_bonus/100),4);
    PERFORM update_planet_resources(p_planet_id);
    PERFORM 1 FROM planet_resources WHERE planet_id=p_planet_id FOR UPDATE;
    UPDATE planet_resources SET metal=metal-v_metal_cost,crystal=crystal-v_crystal_cost,deuterium=deuterium-v_deuterium_cost,updated_at=now() WHERE planet_id=p_planet_id AND metal>=v_metal_cost AND crystal>=v_crystal_cost AND deuterium>=v_deuterium_cost;
    IF NOT FOUND THEN RAISE EXCEPTION 'INSUFFICIENT_RESOURCES'; END IF;
    INSERT INTO research_queue(player_id,planet_id,research_id,target_level,started_at,finishes_at,status) VALUES(p_player_id,p_planet_id,p_research_id,v_target_level,now(),now()+(v_research_time*interval '1 second'),'RESEARCHING') RETURNING id INTO v_queue_id;
    RETURN v_queue_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.start_fleet(p_player_id uuid,p_origin_planet_id uuid,p_destination_planet_id uuid,p_ship_id text,p_quantity bigint,p_mission_type text DEFAULT 'TRANSPORT')
RETURNS TABLE(fleet_id uuid,ship_id text,quantity bigint,origin_planet_id uuid,destination_planet_id uuid,mission_type text,started_at timestamptz,arrives_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER AS $function$
DECLARE v_player_id uuid:=p_player_id; v_origin_planet_id uuid:=p_origin_planet_id; v_destination_planet_id uuid:=p_destination_planet_id; v_ship_id text:=p_ship_id; v_quantity bigint:=p_quantity; v_mission_type text:=upper(p_mission_type); v_fleet_id uuid; v_planet_player uuid; v_available bigint; v_universe_id uuid; v_dest_galaxy integer; v_dest_system integer; v_dest_position integer; v_origin_galaxy integer; v_origin_system integer; v_origin_position integer; v_distance numeric; v_ship_speed numeric; v_fleet_speed numeric; v_evolution numeric; v_fleet_rate numeric; v_travel_time numeric; v_started_at timestamptz; v_arrives_at timestamptz; v_bonus numeric:=1; v_slots integer;
BEGIN
    IF v_quantity<=0 THEN RAISE EXCEPTION 'Fleet quantity must be greater than 0'; END IF;
    IF v_mission_type NOT IN('ATTACK','TRANSPORT','DEPLOY','ESPIONAGE','COLONIZE','RECYCLE','EXPEDITION') THEN RAISE EXCEPTION 'Invalid mission type: %',v_mission_type; END IF;
    SELECT p.player_id,p.universe_id,p.galaxy,p.system,p.position INTO v_planet_player,v_universe_id,v_origin_galaxy,v_origin_system,v_origin_position FROM planets p WHERE p.id=v_origin_planet_id AND NOT p.is_destroyed FOR UPDATE;
    IF NOT FOUND OR v_planet_player<>v_player_id THEN RAISE EXCEPTION 'Origin planet does not belong to player'; END IF;
    IF v_mission_type='EXPEDITION' THEN
        v_destination_planet_id:=NULL; v_dest_galaxy:=v_origin_galaxy; v_dest_system:=v_origin_system; v_dest_position:=16;
        v_slots:=get_player_expedition_slots(v_player_id);
        IF get_active_expedition_count(v_player_id)>=v_slots THEN RAISE EXCEPTION 'EXPEDITION_SLOTS_FULL: %/%',get_active_expedition_count(v_player_id),v_slots; END IF;
    ELSIF v_mission_type='RECYCLE' THEN
        IF v_ship_id<>'recycler' THEN RAISE EXCEPTION 'RECYCLE mission requires recycler'; END IF;
        SELECT df.galaxy,df.system,df.position INTO v_dest_galaxy,v_dest_system,v_dest_position FROM debris_fields df WHERE df.universe_id=v_universe_id AND (df.metal>0 OR df.crystal>0) ORDER BY abs(df.galaxy-v_origin_galaxy),abs(df.system-v_origin_system),abs(df.position-v_origin_position) LIMIT 1 FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'No debris field available for RECYCLE'; END IF;
        v_destination_planet_id:=NULL;
    ELSE
        IF v_destination_planet_id IS NULL THEN RAISE EXCEPTION 'Destination planet is required for %',v_mission_type; END IF;
        IF v_origin_planet_id=v_destination_planet_id THEN RAISE EXCEPTION 'Origin and destination planets must be different'; END IF;
        SELECT galaxy,system,position INTO v_dest_galaxy,v_dest_system,v_dest_position FROM planets WHERE id=v_destination_planet_id AND NOT is_destroyed;
        IF NOT FOUND THEN RAISE EXCEPTION 'Destination planet not found or destroyed'; END IF;
    END IF;
    IF NOT EXISTS(SELECT 1 FROM ship_definitions WHERE id=v_ship_id) THEN RAISE EXCEPTION 'Unknown ship: %',v_ship_id; END IF;
    SELECT quantity INTO v_available FROM planet_ships WHERE planet_id=v_origin_planet_id AND ship_id=v_ship_id FOR UPDATE;
    IF COALESCE(v_available,0)<v_quantity THEN RAISE EXCEPTION 'Not enough %: available %, requested %',v_ship_id,COALESCE(v_available,0),v_quantity; END IF;
    IF v_origin_galaxy<>v_dest_galaxy THEN v_distance:=20000*abs(v_origin_galaxy-v_dest_galaxy); ELSIF v_origin_system<>v_dest_system THEN v_distance:=2700+95*abs(v_origin_system-v_dest_system); ELSIF v_origin_position<>v_dest_position THEN v_distance:=1000+5*abs(v_origin_position-v_dest_position); ELSE v_distance:=5; END IF;
    SELECT speed INTO v_ship_speed FROM ship_definitions WHERE id=v_ship_id;
    SELECT fleet_speed INTO v_fleet_speed FROM universes WHERE id=v_universe_id;
    v_evolution:=calculate_universe_evolution_rate(v_universe_id);
    v_bonus:=1+get_active_expedition_item_effect(v_player_id,v_origin_planet_id,'fleet_speed_percent')/100;
    v_fleet_rate:=v_fleet_speed*power(v_evolution,1.0/3.0)*v_bonus;
    IF v_mission_type='EXPEDITION' THEN v_travel_time:=((35000/100)*sqrt(v_distance*10/v_ship_speed)+10)/(COALESCE((SELECT expedition_speed FROM universes WHERE id=v_universe_id),1)*power(v_evolution,1.0/3.0)*v_bonus); ELSE v_travel_time:=(v_distance/v_ship_speed)*3600/v_fleet_rate; END IF;
    v_travel_time:=greatest(v_travel_time,1); v_started_at:=now(); v_arrives_at:=v_started_at+(v_travel_time*interval '1 second');
    UPDATE planet_ships SET quantity=quantity-v_quantity WHERE planet_id=v_origin_planet_id AND ship_id=v_ship_id;
    INSERT INTO fleet_movements(player_id,origin_planet_id,destination_planet_id,mission_type,started_at,arrives_at,status,destination_galaxy,destination_system,destination_position,expedition_hold_seconds) VALUES(v_player_id,v_origin_planet_id,v_destination_planet_id,v_mission_type,v_started_at,v_arrives_at,'OUTBOUND',v_dest_galaxy,v_dest_system,v_dest_position,3600) RETURNING id INTO v_fleet_id;
    INSERT INTO fleet_movement_ships(fleet_id,ship_id,quantity) VALUES(v_fleet_id,v_ship_id,v_quantity);
    RETURN QUERY SELECT v_fleet_id,v_ship_id,v_quantity,v_origin_planet_id,v_destination_planet_id,v_mission_type,v_started_at,v_arrives_at;
END;
$function$;

CREATE OR REPLACE FUNCTION public.resolve_expedition_item(p_fleet_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $function$
DECLARE v_fleet public.fleet_movements%ROWTYPE; v_item_id text; v_item public.expedition_item_definitions%ROWTYPE; v_stack_id uuid;
BEGIN
    SELECT * INTO v_fleet FROM public.fleet_movements WHERE id=p_fleet_id AND mission_type='EXPEDITION' FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Expedition fleet % not found',p_fleet_id; END IF;
    v_item_id:=public.select_expedition_item();
    SELECT * INTO v_item FROM public.expedition_item_definitions WHERE id=v_item_id AND active=true;
    IF NOT FOUND THEN RAISE EXCEPTION 'Item % is not active',v_item_id; END IF;
    SELECT id INTO v_stack_id FROM public.player_expedition_items WHERE player_id=v_fleet.player_id AND item_id=v_item_id AND active=true AND quantity < v_item.max_stacks ORDER BY acquired_at LIMIT 1 FOR UPDATE;
    IF v_stack_id IS NOT NULL THEN
        UPDATE public.player_expedition_items SET quantity=quantity+1 WHERE id=v_stack_id;
    ELSE
        INSERT INTO public.player_expedition_items(player_id,item_id,quantity,expires_at) VALUES(v_fleet.player_id,v_item_id,1,NULL);
    END IF;
    UPDATE public.expedition_results SET item_id=v_item_id,item_quantity=1 WHERE fleet_id=p_fleet_id;
    RETURN jsonb_build_object('item_id',v_item_id,'name',v_item.name,'category',v_item.category,'effect_key',v_item.effect_key,'effect_value',v_item.effect_value,'duration_seconds',v_item.duration_seconds);
END;
$function$;

CREATE OR REPLACE FUNCTION public.use_expedition_item(p_player_id uuid,p_item_id text,p_planet_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $function$
DECLARE v_item public.expedition_item_definitions%ROWTYPE; v_stack public.player_expedition_items%ROWTYPE; v_expiry timestamptz;
BEGIN
    SELECT * INTO v_item FROM public.expedition_item_definitions WHERE id=p_item_id AND active=true;
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown or inactive item %',p_item_id; END IF;
    UPDATE public.player_expedition_items SET quantity=quantity-1 WHERE id=(SELECT id FROM public.player_expedition_items WHERE player_id=p_player_id AND item_id=p_item_id AND active=true AND quantity>0 ORDER BY acquired_at LIMIT 1) RETURNING * INTO v_stack;
    IF NOT FOUND THEN RAISE EXCEPTION 'Item % not available for player %',p_item_id,p_player_id; END IF;
    IF v_stack.quantity=0 THEN UPDATE public.player_expedition_items SET active=false WHERE id=v_stack.id; END IF;
    v_expiry:=CASE WHEN v_item.duration_seconds>0 THEN now()+make_interval(secs=>v_item.duration_seconds) ELSE NULL END;
    INSERT INTO public.expedition_item_uses(player_id,item_id,planet_id,quantity,effect_snapshot) VALUES(p_player_id,p_item_id,p_planet_id,1,jsonb_build_object('effect_key',v_item.effect_key,'effect_value',v_item.effect_value,'expires_at',v_expiry));
    RETURN jsonb_build_object('item_id',p_item_id,'effect_key',v_item.effect_key,'effect_value',v_item.effect_value,'expires_at',v_expiry);
END;
$function$;
