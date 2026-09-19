CREATE OR REPLACE FUNCTION public.calculate_expedition_resource_multiplier(p_fleet_id uuid)
RETURNS numeric LANGUAGE plpgsql STABLE AS $function$
DECLARE v_universe_id uuid; v_player_id uuid; v_planet_id uuid; v_multiplier numeric:=1; v_item_bonus numeric:=0;
BEGIN
    SELECT fm.player_id,fm.origin_planet_id,p.universe_id INTO v_player_id,v_planet_id,v_universe_id
    FROM public.fleet_movements fm JOIN public.planets p ON p.id=fm.origin_planet_id
    WHERE fm.id=p_fleet_id AND fm.mission_type='EXPEDITION';
    IF NOT FOUND THEN RAISE EXCEPTION 'Expedition fleet not found: %',p_fleet_id; END IF;
    SELECT COALESCE(reward_multiplier_resources,1) INTO v_multiplier FROM public.expedition_settings WHERE universe_id=v_universe_id;
    v_item_bonus:=public.get_active_expedition_item_effect(v_player_id,v_planet_id,'expedition_reward_percent');
    RETURN COALESCE(v_multiplier,1)*(1+COALESCE(v_item_bonus,0)/100);
END;
$function$;

CREATE OR REPLACE FUNCTION public.calculate_expedition_ship_reward_multiplier(p_fleet_id uuid)
RETURNS numeric LANGUAGE plpgsql STABLE AS $function$
DECLARE v_universe_id uuid; v_player_id uuid; v_planet_id uuid; v_multiplier numeric:=1; v_item_bonus numeric:=0;
BEGIN
    SELECT fm.player_id,fm.origin_planet_id,p.universe_id INTO v_player_id,v_planet_id,v_universe_id
    FROM public.fleet_movements fm JOIN public.planets p ON p.id=fm.origin_planet_id
    WHERE fm.id=p_fleet_id AND fm.mission_type='EXPEDITION';
    IF NOT FOUND THEN RAISE EXCEPTION 'Expedition fleet not found: %',p_fleet_id; END IF;
    SELECT COALESCE(reward_multiplier_ships,1) INTO v_multiplier FROM public.expedition_settings WHERE universe_id=v_universe_id;
    v_item_bonus:=public.get_active_expedition_item_effect(v_player_id,v_planet_id,'expedition_reward_percent');
    RETURN COALESCE(v_multiplier,1)*(1+COALESCE(v_item_bonus,0)/100);
END;
$function$;

CREATE OR REPLACE FUNCTION public.calculate_expedition_dark_matter_amount(p_fleet_id uuid)
RETURNS numeric LANGUAGE plpgsql STABLE AS $function$
DECLARE v_universe_id uuid; v_player_id uuid; v_planet_id uuid; v_multiplier numeric:=1; v_class_multiplier numeric:=1; v_tier_multiplier numeric:=1; v_item_bonus numeric:=0; v_base numeric;
BEGIN
    SELECT fm.player_id,fm.origin_planet_id,p.universe_id INTO v_player_id,v_planet_id,v_universe_id FROM public.fleet_movements fm JOIN public.planets p ON p.id=fm.origin_planet_id WHERE fm.id=p_fleet_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Expedition fleet % not found',p_fleet_id; END IF;
    SELECT COALESCE(reward_multiplier_dark_matter,1) INTO v_multiplier FROM public.expedition_settings WHERE universe_id=v_universe_id;
    SELECT COALESCE(dark_matter_multiplier,1) INTO v_class_multiplier FROM public.player_expedition_modifiers WHERE player_id=v_player_id;
    SELECT COALESCE(reward_multiplier,1) INTO v_tier_multiplier FROM public.expedition_results WHERE fleet_id=p_fleet_id;
    v_item_bonus:=public.get_active_expedition_item_effect(v_player_id,v_planet_id,'expedition_reward_percent');
    v_base:=floor(random()*81)+20;
    RETURN greatest(20,round(v_base*COALESCE(v_multiplier,1)*COALESCE(v_class_multiplier,1)*COALESCE(v_tier_multiplier,1)*(1+COALESCE(v_item_bonus,0)/100)));
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_player_fleet_speed_multiplier(p_player_id uuid,p_planet_id uuid)
RETURNS numeric LANGUAGE sql STABLE AS $function$
    SELECT 1 + COALESCE(public.get_active_expedition_item_effect(p_player_id,p_planet_id,'fleet_speed_percent'),0)/100;
$function$;

CREATE OR REPLACE FUNCTION public.calculate_fleet_time(p_origin_planet_id uuid,p_destination_planet_id uuid,p_ship_id text,p_quantity bigint DEFAULT 1)
RETURNS numeric LANGUAGE plpgsql STABLE AS $function$
DECLARE v_distance numeric; v_ship_speed numeric; v_universe_id uuid; v_fleet_speed numeric; v_evolution numeric; v_rate numeric; v_bonus numeric:=1; v_time numeric; v_player_id uuid;
BEGIN
    IF p_quantity<=0 THEN RAISE EXCEPTION 'Quantity must be greater than 0'; END IF;
    SELECT universe_id,player_id INTO v_universe_id,v_player_id FROM public.planets WHERE id=p_origin_planet_id AND NOT is_destroyed;
    IF NOT FOUND THEN RAISE EXCEPTION 'Origin planet not found or destroyed'; END IF;
    IF NOT EXISTS(SELECT 1 FROM public.planets WHERE id=p_destination_planet_id AND NOT is_destroyed) THEN RAISE EXCEPTION 'Destination planet not found or destroyed'; END IF;
    SELECT speed INTO v_ship_speed FROM public.ship_definitions WHERE id=p_ship_id;
    IF NOT FOUND OR v_ship_speed<=0 THEN RAISE EXCEPTION 'Ship has invalid speed'; END IF;
    SELECT fleet_speed INTO v_fleet_speed FROM public.universes WHERE id=v_universe_id;
    v_evolution:=public.calculate_universe_evolution_rate(v_universe_id);
    v_bonus:=public.get_player_fleet_speed_multiplier(v_player_id,p_origin_planet_id);
    v_rate:=v_fleet_speed*power(v_evolution,1.0/3.0)*v_bonus;
    v_distance:=public.calculate_fleet_distance(p_origin_planet_id,p_destination_planet_id);
    v_time:=(v_distance/v_ship_speed)*3600/v_rate;
    RETURN round(greatest(v_time,1),4);
END;
$function$;
