-- Restore the custom construction evolution mechanic that was accidentally overwritten.
CREATE OR REPLACE FUNCTION public.calculate_building_time(p_building_id text, p_target_level integer, p_universe_id uuid)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_base_time numeric;
    v_time_factor numeric;
    v_building_speed numeric;
    v_evolution numeric;
    v_building_rate numeric;
BEGIN
    IF p_target_level < 1 THEN
        RAISE EXCEPTION 'El nivel objetivo debe ser >= 1';
    END IF;

    SELECT bd.base_build_time_seconds, bd.time_factor
    INTO v_base_time, v_time_factor
    FROM public.building_definitions bd
    WHERE bd.id = p_building_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El edificio % no existe', p_building_id;
    END IF;

    IF v_time_factor IS NULL OR v_time_factor <= 0 THEN
        RAISE EXCEPTION 'El edificio % tiene un time_factor inválido: %', p_building_id, v_time_factor;
    END IF;

    SELECT u.building_speed
    INTO v_building_speed
    FROM public.universes u
    WHERE u.id = p_universe_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El universo % no existe', p_universe_id;
    END IF;

    v_evolution := public.calculate_universe_evolution_rate(p_universe_id);
    v_building_rate := v_building_speed * sqrt(v_evolution);

    IF v_building_rate <= 0 THEN
        RAISE EXCEPTION 'La velocidad efectiva de construcción es inválida: %', v_building_rate;
    END IF;

    RETURN round(
        (v_base_time * power(v_time_factor, p_target_level - 1)) / v_building_rate,
        4
    );
END;
$function$;

-- Ensure every direct research-time path uses the evolving research rate.
CREATE OR REPLACE FUNCTION public.calculate_research_time(p_research_id text, p_target_level integer, p_universe_id uuid)
RETURNS numeric
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_base_time numeric;
    v_time_factor numeric;
    v_research_speed numeric;
    v_evolution numeric;
    v_research_rate numeric;
    v_max_level integer;
BEGIN
    IF p_target_level < 1 THEN
        RAISE EXCEPTION 'El nivel objetivo debe ser >= 1';
    END IF;

    SELECT rd.base_research_time_seconds, rd.time_factor, rd.max_level
    INTO v_base_time, v_time_factor, v_max_level
    FROM public.research_definitions rd
    WHERE rd.id = p_research_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'La investigación % no existe', p_research_id;
    END IF;

    IF v_max_level IS NOT NULL AND p_target_level > v_max_level THEN
        RAISE EXCEPTION 'La investigación % no puede superar el nivel %', p_research_id, v_max_level;
    END IF;

    IF v_time_factor IS NULL OR v_time_factor <= 0 THEN
        RAISE EXCEPTION 'La investigación % tiene un time_factor inválido: %', p_research_id, v_time_factor;
    END IF;

    SELECT u.research_speed INTO v_research_speed
    FROM public.universes u WHERE u.id = p_universe_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El universo % no existe', p_universe_id;
    END IF;

    v_evolution := public.calculate_universe_evolution_rate(p_universe_id);
    v_research_rate := v_research_speed * sqrt(v_evolution);

    IF v_research_rate <= 0 THEN
        RAISE EXCEPTION 'La velocidad efectiva de investigación es inválida: %', v_research_rate;
    END IF;

    RETURN round(
        (v_base_time * power(v_time_factor, p_target_level - 1)) / v_research_rate,
        4
    );
END;
$function$;

-- Fleet travel uses the cube-root evolution curve consistently.
CREATE OR REPLACE FUNCTION public.calculate_fleet_time(p_origin_planet_id uuid, p_destination_planet_id uuid, p_ship_id text, p_quantity bigint DEFAULT 1)
RETURNS numeric
LANGUAGE plpgsql STABLE SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_distance numeric; v_ship_speed numeric; v_universe_id uuid; v_fleet_speed numeric; v_evolution numeric; v_rate numeric; v_bonus numeric:=1; v_time numeric; v_player_id uuid;
BEGIN
    IF p_quantity<=0 THEN RAISE EXCEPTION 'Quantity must be greater than 0'; END IF;
    SELECT universe_id,player_id INTO v_universe_id,v_player_id FROM public.planets WHERE id=p_origin_planet_id AND NOT is_destroyed;
    IF NOT FOUND THEN RAISE EXCEPTION 'Origin planet not found or destroyed'; END IF;
    IF NOT EXISTS(SELECT 1 FROM public.planets WHERE id=p_destination_planet_id AND NOT is_destroyed) THEN RAISE EXCEPTION 'Destination planet not found or destroyed'; END IF;
    SELECT speed INTO v_ship_speed FROM public.ship_definitions WHERE id=p_ship_id;
    IF NOT FOUND OR v_ship_speed<=0 THEN RAISE EXCEPTION 'Ship has invalid speed'; END IF;
    SELECT fleet_speed INTO v_fleet_speed FROM public.universes WHERE id=v_universe_id;
    IF v_fleet_speed IS NULL OR v_fleet_speed<=0 THEN RAISE EXCEPTION 'Invalid universe fleet speed'; END IF;
    v_evolution:=public.calculate_universe_evolution_rate(v_universe_id);
    v_bonus:=public.get_player_fleet_speed_multiplier(v_player_id,p_origin_planet_id);
    v_rate:=v_fleet_speed*power(v_evolution,1.0/3.0)*v_bonus;
    v_distance:=public.calculate_fleet_distance(p_origin_planet_id,p_destination_planet_id);
    v_time:=(v_distance/v_ship_speed)*3600/v_rate;
    RETURN round(greatest(v_time,1),4);
END;
$function$;

-- Expedition delay is a fleet-time effect, so it must evolve with the fleet rate too.
CREATE OR REPLACE FUNCTION public.calculate_expedition_delay_seconds(p_fleet_id uuid, p_multiplier numeric)
RETURNS numeric
LANGUAGE plpgsql STABLE SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_universe_id uuid;
    v_fleet_speed numeric;
    v_evolution numeric;
    v_fleet_rate numeric;
    v_holding_seconds numeric := 3600;
    v_additional_delay numeric;
BEGIN
    IF p_multiplier NOT IN (2, 3, 5) THEN
        RAISE EXCEPTION 'Delay multiplier must be 2, 3 or 5';
    END IF;
    SELECT p.universe_id INTO v_universe_id
    FROM public.fleet_movements fm JOIN public.planets p ON p.id=fm.origin_planet_id
    WHERE fm.id=p_fleet_id AND fm.mission_type='EXPEDITION';
    IF NOT FOUND THEN RAISE EXCEPTION 'Expedition fleet % not found', p_fleet_id; END IF;
    SELECT u.fleet_speed INTO v_fleet_speed FROM public.universes u WHERE u.id=v_universe_id;
    IF v_fleet_speed IS NULL OR v_fleet_speed<=0 THEN RAISE EXCEPTION 'Invalid universe fleet speed for expedition %',p_fleet_id; END IF;
    v_evolution:=public.calculate_universe_evolution_rate(v_universe_id);
    v_fleet_rate:=v_fleet_speed*power(v_evolution,1.0/3.0);
    v_additional_delay:=floor((v_holding_seconds*p_multiplier)/v_fleet_rate);
    RETURN greatest(v_additional_delay,1);
END;
$function$;

-- Colonization already used evolution; keep its fleet curve explicit and validated.
CREATE OR REPLACE FUNCTION public.start_colonize_fleet(p_player_id uuid, p_origin_planet_id uuid, p_galaxy integer, p_system integer, p_position integer)
RETURNS TABLE(fleet_id uuid, ship_id text, quantity bigint, origin_planet_id uuid, destination_planet_id uuid, mission_type text, started_at timestamp with time zone, arrives_at timestamp with time zone)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_origin record; v_available bigint; v_ship_speed numeric; v_fleet_speed numeric; v_evolution numeric; v_bonus numeric:=1; v_distance numeric; v_time numeric; v_fleet_rate numeric; v_fleet_id uuid; v_started timestamptz; v_arrives timestamptz; v_auth_user uuid;
BEGIN
    v_auth_user:=auth.uid();
    IF v_auth_user IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.players pl WHERE pl.id=p_player_id AND pl.user_id=v_auth_user) THEN RAISE EXCEPTION 'Player does not belong to authenticated user'; END IF;
    IF v_auth_user IS NULL AND NOT EXISTS(SELECT 1 FROM public.players pl WHERE pl.id=p_player_id AND coalesce(pl.is_guest,false)=true) THEN RAISE EXCEPTION 'Authentication required'; END IF;
    IF p_galaxy<1 OR p_system<1 OR p_position<1 OR p_position>15 THEN RAISE EXCEPTION 'Invalid colonization coordinate'; END IF;
    SELECT p.* INTO v_origin FROM public.planets p WHERE p.id=p_origin_planet_id AND NOT p.is_destroyed FOR UPDATE;
    IF NOT FOUND OR v_origin.player_id<>p_player_id THEN RAISE EXCEPTION 'Origin planet does not belong to player'; END IF;
    IF EXISTS(SELECT 1 FROM public.planets p WHERE p.universe_id=v_origin.universe_id AND p.galaxy=p_galaxy AND p.system=p_system AND p.position=p_position AND NOT p.is_destroyed) THEN RAISE EXCEPTION 'COLONIZE_TARGET_OCCUPIED'; END IF;
    SELECT ps.quantity INTO v_available FROM public.planet_ships ps WHERE ps.planet_id=p_origin_planet_id AND ps.ship_id='colony_ship' FOR UPDATE;
    IF COALESCE(v_available,0)<1 THEN RAISE EXCEPTION 'Not enough colony_ship'; END IF;
    SELECT sd.speed INTO v_ship_speed FROM public.ship_definitions sd WHERE sd.id='colony_ship';
    SELECT u.fleet_speed INTO v_fleet_speed FROM public.universes u WHERE u.id=v_origin.universe_id;
    IF v_fleet_speed IS NULL OR v_fleet_speed<=0 THEN RAISE EXCEPTION 'Invalid universe fleet speed'; END IF;
    v_evolution:=public.calculate_universe_evolution_rate(v_origin.universe_id);
    v_fleet_rate:=v_fleet_speed*power(v_evolution,1.0/3.0);
    v_bonus:=1+(COALESCE(public.get_active_expedition_item_effect(p_player_id,p_origin_planet_id,'fleet_speed_percent'),0)+COALESCE(public.get_active_lifeform_research_effect(p_player_id,'fleet_speed_percent'),0))/100;
    v_distance:=CASE WHEN v_origin.galaxy<>p_galaxy THEN 20000*abs(v_origin.galaxy-p_galaxy) WHEN v_origin.system<>p_system THEN 2700+95*abs(v_origin.system-p_system) ELSE 1000+5*abs(v_origin.position-p_position) END;
    v_time:=greatest((v_distance/v_ship_speed)*3600/(v_fleet_rate*v_bonus),1);
    v_started:=now(); v_arrives:=v_started+v_time*interval '1 second';
    UPDATE public.planet_ships ps SET quantity=ps.quantity-1 WHERE ps.planet_id=p_origin_planet_id AND ps.ship_id='colony_ship';
    INSERT INTO public.fleet_movements(player_id,origin_planet_id,destination_planet_id,mission_type,started_at,arrives_at,status,destination_galaxy,destination_system,destination_position,expedition_hold_seconds) VALUES(p_player_id,p_origin_planet_id,NULL,'COLONIZE',v_started,v_arrives,'OUTBOUND',p_galaxy,p_system,p_position,3600) RETURNING id INTO v_fleet_id;
    INSERT INTO public.fleet_movement_ships(fleet_id,ship_id,quantity) VALUES(v_fleet_id,'colony_ship',1);
    RETURN QUERY SELECT v_fleet_id,'colony_ship'::text,1::bigint,p_origin_planet_id,NULL::uuid,'COLONIZE'::text,v_started,v_arrives;
END;
$function$;