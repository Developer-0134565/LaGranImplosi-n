-- Keep the existing guest-access model, but make every exposed game-action RPC
-- enforce the same player/auth relationship before performing its work.
-- This does not remove anonymous guest access; it only prevents an authenticated
-- caller from supplying another player's ID to a SECURITY DEFINER function.

CREATE OR REPLACE FUNCTION public.start_building(p_player_id uuid, p_planet_id uuid, p_building_id text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
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

    IF v_auth_user IS NULL AND NOT EXISTS (
        SELECT 1 FROM public.players pl
        WHERE pl.id = p_player_id
          AND coalesce(pl.is_guest, false) = true
    ) THEN
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
    PERFORM public.update_planet_resources(p_planet_id);
    PERFORM 1 FROM public.planet_resources WHERE planet_id=p_planet_id FOR UPDATE;
    UPDATE public.planet_resources SET metal=metal-v_metal_cost,crystal=crystal-v_crystal_cost,deuterium=deuterium-v_deuterium_cost,updated_at=now() WHERE planet_id=p_planet_id AND metal>=v_metal_cost AND crystal>=v_crystal_cost AND deuterium>=v_deuterium_cost;
    IF NOT FOUND THEN RAISE EXCEPTION 'INSUFFICIENT_RESOURCES'; END IF;
    INSERT INTO public.building_queue(planet_id,building_id,target_level,started_at,finishes_at,status) VALUES(p_planet_id,p_building_id,v_target_level,now(),now()+(v_build_time*interval '1 second'),'BUILDING') RETURNING id INTO v_queue_id;
    RETURN v_queue_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.start_research(p_player_id uuid, p_planet_id uuid, p_research_id text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
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
BEGIN
    v_auth_user := auth.uid();

    IF v_auth_user IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.players pl
        WHERE pl.id = p_player_id
          AND pl.user_id = v_auth_user
    ) THEN
        RAISE EXCEPTION 'Player does not belong to authenticated user';
    END IF;

    IF v_auth_user IS NULL AND NOT EXISTS (
        SELECT 1 FROM public.players pl
        WHERE pl.id = p_player_id
          AND coalesce(pl.is_guest, false) = true
    ) THEN
        RAISE EXCEPTION 'Authentication required';
    END IF;

    SELECT universe_id INTO v_universe_id FROM public.planets WHERE id=p_planet_id AND player_id=p_player_id AND is_destroyed=false FOR UPDATE;
    IF v_universe_id IS NULL THEN RAISE EXCEPTION 'PLANET_NOT_FOUND_OR_NOT_OWNED'; END IF;
    IF NOT EXISTS(SELECT 1 FROM public.research_definitions WHERE id=p_research_id) THEN RAISE EXCEPTION 'RESEARCH_NOT_FOUND: %',p_research_id; END IF;
    SELECT COALESCE(MAX(level),0) INTO v_current_level FROM public.player_research WHERE player_id=p_player_id AND research_id=p_research_id;
    v_target_level:=v_current_level+1;
    IF EXISTS(SELECT 1 FROM public.research_definitions WHERE id=p_research_id AND max_level IS NOT NULL AND v_target_level>max_level) THEN RAISE EXCEPTION 'RESEARCH_MAX_LEVEL_REACHED'; END IF;
    IF EXISTS(SELECT 1 FROM public.research_queue WHERE player_id=p_player_id AND UPPER(status) IN('RESEARCHING','QUEUED','ACTIVE')) THEN RAISE EXCEPTION 'RESEARCH_QUEUE_ALREADY_ACTIVE'; END IF;
    SELECT c.metal,c.crystal,c.deuterium INTO v_metal_cost,v_crystal_cost,v_deuterium_cost FROM public.calculate_research_cost(p_research_id,v_target_level) c;
    v_research_time:=public.calculate_research_time(p_research_id,v_target_level,v_universe_id);
    v_item_bonus:=public.get_active_expedition_item_effect(p_player_id,p_planet_id,'research_speed_percent');
    v_research_time:=round(v_research_time/(1+v_item_bonus/100),4);
    PERFORM public.update_planet_resources(p_planet_id);
    PERFORM 1 FROM public.planet_resources WHERE planet_id=p_planet_id FOR UPDATE;
    UPDATE public.planet_resources SET metal=metal-v_metal_cost,crystal=crystal-v_crystal_cost,deuterium=deuterium-v_deuterium_cost,updated_at=now() WHERE planet_id=p_planet_id AND metal>=v_metal_cost AND crystal>=v_crystal_cost AND deuterium>=v_deuterium_cost;
    IF NOT FOUND THEN RAISE EXCEPTION 'INSUFFICIENT_RESOURCES'; END IF;
    INSERT INTO public.research_queue(player_id,planet_id,research_id,target_level,started_at,finishes_at,status) VALUES(p_player_id,p_planet_id,p_research_id,v_target_level,now(),now()+(v_research_time*interval '1 second'),'RESEARCHING') RETURNING id INTO v_queue_id;
    RETURN v_queue_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.start_colonize_fleet(p_player_id uuid, p_origin_planet_id uuid, p_galaxy integer, p_system integer, p_position integer)
RETURNS TABLE(fleet_id uuid, ship_id text, quantity bigint, origin_planet_id uuid, destination_planet_id uuid, mission_type text, started_at timestamp with time zone, arrives_at timestamp with time zone)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_origin record;
    v_available bigint;
    v_ship_speed numeric;
    v_fleet_speed numeric;
    v_evolution numeric;
    v_bonus numeric := 1;
    v_distance numeric;
    v_time numeric;
    v_fleet_id uuid;
    v_started timestamptz;
    v_arrives timestamptz;
    v_auth_user uuid;
BEGIN
    v_auth_user := auth.uid();

    IF v_auth_user IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.players pl
        WHERE pl.id = p_player_id AND pl.user_id = v_auth_user
    ) THEN
        RAISE EXCEPTION 'Player does not belong to authenticated user';
    END IF;

    IF v_auth_user IS NULL AND NOT EXISTS (
        SELECT 1 FROM public.players pl
        WHERE pl.id = p_player_id AND coalesce(pl.is_guest, false) = true
    ) THEN
        RAISE EXCEPTION 'Authentication required';
    END IF;

    IF p_galaxy<1 OR p_system<1 OR p_position<1 OR p_position>15 THEN RAISE EXCEPTION 'Invalid colonization coordinate'; END IF;
    SELECT p.* INTO v_origin FROM public.planets p WHERE p.id=p_origin_planet_id AND NOT p.is_destroyed FOR UPDATE;
    IF NOT FOUND OR v_origin.player_id<>p_player_id THEN RAISE EXCEPTION 'Origin planet does not belong to player'; END IF;
    IF EXISTS(SELECT 1 FROM public.planets p WHERE p.universe_id=v_origin.universe_id AND p.galaxy=p_galaxy AND p.system=p_system AND p.position=p_position AND NOT p.is_destroyed) THEN RAISE EXCEPTION 'COLONIZE_TARGET_OCCUPIED'; END IF;
    SELECT ps.quantity INTO v_available FROM public.planet_ships ps WHERE ps.planet_id=p_origin_planet_id AND ps.ship_id='colony_ship' FOR UPDATE;
    IF COALESCE(v_available,0)<1 THEN RAISE EXCEPTION 'Not enough colony_ship'; END IF;
    SELECT sd.speed INTO v_ship_speed FROM public.ship_definitions sd WHERE sd.id='colony_ship';
    SELECT u.fleet_speed INTO v_fleet_speed FROM public.universes u WHERE u.id=v_origin.universe_id;
    v_evolution:=public.calculate_universe_evolution_rate(v_origin.universe_id);
    v_bonus:=1+(COALESCE(public.get_active_expedition_item_effect(p_player_id,p_origin_planet_id,'fleet_speed_percent'),0)+COALESCE(public.get_active_lifeform_research_effect(p_player_id,'fleet_speed_percent'),0))/100;
    v_distance:=CASE WHEN v_origin.galaxy<>p_galaxy THEN 20000*abs(v_origin.galaxy-p_galaxy) WHEN v_origin.system<>p_system THEN 2700+95*abs(v_origin.system-p_system) ELSE 1000+5*abs(v_origin.position-p_position) END;
    v_time:=greatest((v_distance/v_ship_speed)*3600/(v_fleet_speed*power(v_evolution,1.0/3.0)*v_bonus),1);
    v_started:=now(); v_arrives:=v_started+v_time*interval '1 second';
    UPDATE public.planet_ships ps SET quantity=ps.quantity-1 WHERE ps.planet_id=p_origin_planet_id AND ps.ship_id='colony_ship';
    INSERT INTO public.fleet_movements(player_id,origin_planet_id,destination_planet_id,mission_type,started_at,arrives_at,status,destination_galaxy,destination_system,destination_position,expedition_hold_seconds) VALUES(p_player_id,p_origin_planet_id,NULL,'COLONIZE',v_started,v_arrives,'OUTBOUND',p_galaxy,p_system,p_position,3600) RETURNING id INTO v_fleet_id;
    INSERT INTO public.fleet_movement_ships(fleet_id,ship_id,quantity) VALUES(v_fleet_id,'colony_ship',1);
    RETURN QUERY SELECT v_fleet_id,'colony_ship'::text,1::bigint,p_origin_planet_id,NULL::uuid,'COLONIZE'::text,v_started,v_arrives;
END;
$function$;

CREATE OR REPLACE FUNCTION public.start_ship(p_player_id uuid, p_planet_id uuid, p_ship_id text, p_quantity bigint DEFAULT 1)
RETURNS TABLE(queue_id uuid, ship_id text, quantity bigint, started_at timestamp with time zone, finishes_at timestamp with time zone, metal_cost numeric, crystal_cost numeric, deuterium_cost numeric)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
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

    IF v_auth_user IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.players pl WHERE pl.id=p_player_id AND pl.user_id=v_auth_user
    ) THEN
        RAISE EXCEPTION 'Player does not belong to authenticated user';
    END IF;

    IF v_auth_user IS NULL AND NOT EXISTS (
        SELECT 1 FROM public.players pl WHERE pl.id=p_player_id AND coalesce(pl.is_guest,false)=true
    ) THEN
        RAISE EXCEPTION 'Authentication required';
    END IF;

    IF p_quantity <= 0 THEN RAISE EXCEPTION 'Quantity must be greater than 0'; END IF;
    SELECT p.player_id INTO v_planet_player FROM public.planets p WHERE p.id=p_planet_id AND NOT p.is_destroyed FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Planet not found or destroyed'; END IF;
    IF v_planet_player <> p_player_id THEN RAISE EXCEPTION 'Planet does not belong to player'; END IF;
    IF NOT EXISTS (SELECT 1 FROM public.ship_definitions sd WHERE sd.id = p_ship_id) THEN RAISE EXCEPTION 'Unknown ship: %', p_ship_id; END IF;
    PERFORM public.update_planet_resources(p_planet_id);
    SELECT r.reason INTO v_reason FROM public.check_ship_requirements(p_planet_id,p_ship_id) AS r WHERE NOT r.allowed LIMIT 1;
    IF v_reason IS NOT NULL THEN RAISE EXCEPTION '%', v_reason; END IF;
    SELECT c.metal,c.crystal,c.deuterium INTO v_metal,v_crystal,v_deuterium FROM public.calculate_ship_cost(p_ship_id,p_quantity) AS c;
    SELECT pr.metal,pr.crystal,pr.deuterium INTO v_metal_available,v_crystal_available,v_deuterium_available FROM public.planet_resources pr WHERE pr.planet_id=p_planet_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Planet resources not found'; END IF;
    IF v_metal_available < v_metal THEN RAISE EXCEPTION 'Not enough metal'; END IF;
    IF v_crystal_available < v_crystal THEN RAISE EXCEPTION 'Not enough crystal'; END IF;
    IF v_deuterium_available < v_deuterium THEN RAISE EXCEPTION 'Not enough deuterium'; END IF;
    v_unit_time := public.calculate_ship_build_time(p_planet_id,p_ship_id);
    v_total_time := v_unit_time * p_quantity;
    SELECT MAX(sq.finishes_at) INTO v_started_at FROM public.shipyard_queue sq WHERE sq.planet_id=p_planet_id AND sq.status='BUILDING' AND sq.finishes_at>now();
    v_started_at := GREATEST(COALESCE(v_started_at,now()),now());
    v_finishes_at := v_started_at + make_interval(secs => v_total_time);
    UPDATE public.planet_resources SET metal=metal-v_metal,crystal=crystal-v_crystal,deuterium=deuterium-v_deuterium,updated_at=now() WHERE planet_id=p_planet_id;
    INSERT INTO public.shipyard_queue(planet_id,ship_id,quantity,started_at,finishes_at,status) VALUES(p_planet_id,p_ship_id,p_quantity,v_started_at,v_finishes_at,'BUILDING') RETURNING id INTO v_queue_id;
    RETURN QUERY SELECT v_queue_id,p_ship_id,p_quantity,v_started_at,v_finishes_at,v_metal,v_crystal,v_deuterium;
END;
$function$;

CREATE OR REPLACE FUNCTION public.start_lifeform_building(p_planet_id uuid, p_building_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_def public.lifeform_building_definitions%ROWTYPE;
    v_player uuid;
    v_lf text;
    v_level integer := 0;
    v_target integer;
    v_id uuid;
    v_m numeric;
    v_c numeric;
    v_d numeric;
    v_auth_user uuid;
BEGIN
    v_auth_user := auth.uid();
    SELECT p.player_id, pl.lifeform_id INTO v_player, v_lf
    FROM public.planets p
    JOIN public.planet_lifeforms pl ON pl.planet_id=p.id AND pl.active=true
    WHERE p.id=p_planet_id AND p.is_destroyed=false FOR UPDATE;
    IF v_player IS NULL THEN RAISE EXCEPTION 'PLANET_NOT_FOUND_OR_NO_ACTIVE_LIFEFORM'; END IF;

    IF v_auth_user IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.players WHERE id=v_player AND user_id=v_auth_user) THEN
        RAISE EXCEPTION 'Player does not belong to authenticated user';
    END IF;
    IF v_auth_user IS NULL AND NOT EXISTS (SELECT 1 FROM public.players WHERE id=v_player AND coalesce(is_guest,false)=true) THEN
        RAISE EXCEPTION 'Authentication required';
    END IF;

    SELECT * INTO v_def FROM public.lifeform_building_definitions WHERE id=p_building_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown lifeform building %',p_building_id; END IF;
    IF v_lf<>v_def.lifeform_id THEN RAISE EXCEPTION 'Active lifeform does not match building'; END IF;
    SELECT COALESCE(MAX(level),0) INTO v_level FROM public.planet_lifeform_buildings WHERE planet_id=p_planet_id AND building_id=p_building_id;
    v_target:=v_level+1;
    IF v_target>v_def.max_level THEN RAISE EXCEPTION 'Max level reached'; END IF;
    SELECT metal,crystal,deuterium INTO v_m,v_c,v_d FROM public.calculate_lifeform_building_cost(p_building_id,v_target);
    PERFORM public.update_planet_resources(p_planet_id);
    PERFORM 1 FROM public.planet_resources WHERE planet_id=p_planet_id FOR UPDATE;
    UPDATE public.planet_resources SET metal=metal-v_m,crystal=crystal-v_c,deuterium=deuterium-v_d,updated_at=now() WHERE planet_id=p_planet_id AND metal>=v_m AND crystal>=v_c AND deuterium>=v_d;
    IF NOT FOUND THEN RAISE EXCEPTION 'Insufficient resources for % level %',p_building_id,v_target; END IF;
    INSERT INTO public.planet_lifeform_buildings(planet_id,building_id,level) VALUES(p_planet_id,p_building_id,v_target) ON CONFLICT (planet_id,building_id) DO UPDATE SET level=EXCLUDED.level,updated_at=now();
    INSERT INTO public.lifeform_building_queue(planet_id,building_id,target_level,started_at,finishes_at,status) VALUES(p_planet_id,p_building_id,v_target,now(),now(),'COMPLETED') RETURNING id INTO v_id;
    RETURN jsonb_build_object('queue_id',v_id,'building_id',p_building_id,'level',v_target,'completed',true,'accelerated',true,'cost',jsonb_build_object('metal',v_m,'crystal',v_c,'deuterium',v_d));
END;
$function$;

CREATE OR REPLACE FUNCTION public.start_lifeform_research(p_planet_id uuid, p_research_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_def public.lifeform_research_definitions%ROWTYPE;
    v_active text;
    v_player uuid;
    v_discovered boolean;
    v_population numeric;
    v_previous_slots integer;
    v_level integer := 0;
    v_target integer;
    v_id uuid;
    v_m numeric;
    v_c numeric;
    v_d numeric;
    v_auth_user uuid;
BEGIN
    v_auth_user := auth.uid();
    SELECT p.player_id,pl.lifeform_id,pl.population_t1+pl.population_t2+pl.population_t3 INTO v_player,v_active,v_population
    FROM public.planets p JOIN public.planet_lifeforms pl ON pl.planet_id=p.id AND pl.active=true
    WHERE p.id=p_planet_id AND p.is_destroyed=false FOR UPDATE;
    IF v_player IS NULL OR v_active IS NULL THEN RAISE EXCEPTION 'PLANET_NOT_FOUND_OR_NO_ACTIVE_LIFEFORM'; END IF;

    IF v_auth_user IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.players WHERE id=v_player AND user_id=v_auth_user) THEN
        RAISE EXCEPTION 'Player does not belong to authenticated user';
    END IF;
    IF v_auth_user IS NULL AND NOT EXISTS (SELECT 1 FROM public.players WHERE id=v_player AND coalesce(is_guest,false)=true) THEN
        RAISE EXCEPTION 'Authentication required';
    END IF;

    SELECT * INTO v_def FROM public.lifeform_research_definitions WHERE id=p_research_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown lifeform research %',p_research_id; END IF;
    SELECT COALESCE(bool_or(discovered),false) INTO v_discovered FROM public.player_lifeform_discoveries WHERE player_id=v_player AND lifeform_id=v_def.lifeform_id;
    IF NOT v_discovered THEN RAISE EXCEPTION 'Lifeform % has not been discovered',v_def.lifeform_id; END IF;
    IF COALESCE(v_population,0)<public.get_lifeform_research_population_requirement(v_def.slot) THEN RAISE EXCEPTION 'Population %. Required for slot %: %',COALESCE(v_population,0),v_def.slot,public.get_lifeform_research_population_requirement(v_def.slot); END IF;
    IF v_def.tier>1 THEN
        SELECT count(*) INTO v_previous_slots FROM public.planet_lifeform_research WHERE planet_id=p_planet_id AND slot BETWEEN ((v_def.tier-1)*6-5) AND ((v_def.tier-1)*6);
        IF v_previous_slots<6 THEN RAISE EXCEPTION 'Tier % requires all previous 6 research slots',v_def.tier; END IF;
    END IF;
    IF v_active<>v_def.lifeform_id THEN RAISE EXCEPTION 'Active lifeform does not match research'; END IF;
    SELECT COALESCE(MAX(level),0) INTO v_level FROM public.planet_lifeform_research WHERE planet_id=p_planet_id AND slot=v_def.slot;
    v_target:=v_level+1;
    IF v_target>v_def.max_level THEN RAISE EXCEPTION 'Max level reached'; END IF;
    SELECT metal,crystal,deuterium INTO v_m,v_c,v_d FROM public.calculate_lifeform_research_cost(p_research_id,v_target);
    PERFORM public.update_planet_resources(p_planet_id);
    PERFORM 1 FROM public.planet_resources WHERE planet_id=p_planet_id FOR UPDATE;
    UPDATE public.planet_resources SET metal=metal-v_m,crystal=crystal-v_c,deuterium=deuterium-v_d,updated_at=now() WHERE planet_id=p_planet_id AND metal>=v_m AND crystal>=v_c AND deuterium>=v_d;
    IF NOT FOUND THEN RAISE EXCEPTION 'Insufficient resources for % level %',p_research_id,v_target; END IF;
    INSERT INTO public.planet_lifeform_research(planet_id,slot,research_id,level) VALUES(p_planet_id,v_def.slot,p_research_id,v_target) ON CONFLICT (planet_id,slot) DO UPDATE SET research_id=EXCLUDED.research_id,level=EXCLUDED.level,updated_at=now();
    INSERT INTO public.lifeform_research_queue(planet_id,research_id,target_level,started_at,finishes_at,status) VALUES(p_planet_id,p_research_id,v_target,now(),now(),'COMPLETED') RETURNING id INTO v_id;
    RETURN jsonb_build_object('queue_id',v_id,'research_id',p_research_id,'slot',v_def.slot,'level',v_target,'completed',true,'accelerated',true,'cost',jsonb_build_object('metal',v_m,'crystal',v_c,'deuterium',v_d));
END;
$function$;
