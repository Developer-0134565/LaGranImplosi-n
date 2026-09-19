CREATE OR REPLACE FUNCTION public.start_colonize_fleet(p_player_id uuid,p_origin_planet_id uuid,p_galaxy integer,p_system integer,p_position integer) RETURNS TABLE(fleet_id uuid,ship_id text,quantity bigint,origin_planet_id uuid,destination_planet_id uuid,mission_type text,started_at timestamptz,arrives_at timestamptz) LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $function$
DECLARE v_origin record; v_available bigint; v_ship_speed numeric; v_fleet_speed numeric; v_evolution numeric; v_bonus numeric:=1; v_distance numeric; v_time numeric; v_fleet_id uuid; v_started timestamptz; v_arrives timestamptz;
BEGIN
 IF p_galaxy<1 OR p_system<1 OR p_position<1 OR p_position>15 THEN RAISE EXCEPTION 'Invalid colonization coordinate'; END IF;
 SELECT p.* INTO v_origin FROM public.planets p WHERE p.id=p_origin_planet_id AND NOT p.is_destroyed FOR UPDATE;
 IF NOT FOUND OR v_origin.player_id<>p_player_id THEN RAISE EXCEPTION 'Origin planet does not belong to player'; END IF;
 IF EXISTS(SELECT 1 FROM public.planets p WHERE p.universe_id=v_origin.universe_id AND p.galaxy=p_galaxy AND p.system=p_system AND p.position=p_position AND NOT p.is_destroyed) THEN RAISE EXCEPTION 'COLONIZE_TARGET_OCCUPIED'; END IF;
 SELECT quantity INTO v_available FROM public.planet_ships WHERE planet_id=p_origin_planet_id AND ship_id='colony_ship' FOR UPDATE;
 IF COALESCE(v_available,0)<1 THEN RAISE EXCEPTION 'Not enough colony_ship'; END IF;
 SELECT speed INTO v_ship_speed FROM public.ship_definitions WHERE id='colony_ship';
 SELECT fleet_speed INTO v_fleet_speed FROM public.universes WHERE id=v_origin.universe_id;
 v_evolution:=public.calculate_universe_evolution_rate(v_origin.universe_id);
 v_bonus:=1+(COALESCE(public.get_active_expedition_item_effect(p_player_id,p_origin_planet_id,'fleet_speed_percent'),0)+COALESCE(public.get_active_lifeform_research_effect(p_player_id,'fleet_speed_percent'),0))/100;
 v_distance:=CASE WHEN v_origin.galaxy<>p_galaxy THEN 20000*abs(v_origin.galaxy-p_galaxy) WHEN v_origin.system<>p_system THEN 2700+95*abs(v_origin.system-p_system) ELSE 1000+5*abs(v_origin.position-p_position) END;
 v_time:=greatest((v_distance/v_ship_speed)*3600/(v_fleet_speed*power(v_evolution,1.0/3.0)*v_bonus),1);
 v_started:=now(); v_arrives:=v_started+v_time*interval '1 second';
 UPDATE public.planet_ships SET quantity=quantity-1 WHERE planet_id=p_origin_planet_id AND ship_id='colony_ship';
 INSERT INTO public.fleet_movements(player_id,origin_planet_id,destination_planet_id,mission_type,started_at,arrives_at,status,destination_galaxy,destination_system,destination_position,expedition_hold_seconds) VALUES(p_player_id,p_origin_planet_id,NULL,'COLONIZE',v_started,v_arrives,'OUTBOUND',p_galaxy,p_system,p_position,3600) RETURNING id INTO v_fleet_id;
 INSERT INTO public.fleet_movement_ships(fleet_id,ship_id,quantity) VALUES(v_fleet_id,'colony_ship',1);
 RETURN QUERY SELECT v_fleet_id,'colony_ship'::text,1::bigint,p_origin_planet_id,NULL::uuid,'COLONIZE'::text,v_started,v_arrives;
END;$function$;
REVOKE ALL ON FUNCTION public.start_colonize_fleet(uuid,uuid,integer,integer,integer) FROM PUBLIC; GRANT EXECUTE ON FUNCTION public.start_colonize_fleet(uuid,uuid,integer,integer,integer) TO service_role;