CREATE OR REPLACE FUNCTION public.calculate_expedition_time(p_origin_planet_id uuid,p_ship_id text,p_quantity bigint DEFAULT 1)
RETURNS numeric
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
 v_universe_id uuid; v_ship_speed numeric; v_expedition_speed numeric; v_evolution numeric; v_rate numeric; v_distance numeric; v_time_seconds numeric;
 v_speed_percent numeric:=10;
BEGIN
 IF p_quantity<=0 THEN RAISE EXCEPTION 'Quantity must be greater than 0'; END IF;
 SELECT p.universe_id INTO v_universe_id FROM public.planets p WHERE p.id=p_origin_planet_id AND NOT p.is_destroyed;
 IF NOT FOUND THEN RAISE EXCEPTION 'Origin planet not found or destroyed'; END IF;
 SELECT sd.speed INTO v_ship_speed FROM public.ship_definitions sd WHERE sd.id=p_ship_id;
 IF NOT FOUND OR v_ship_speed<=0 THEN RAISE EXCEPTION 'Invalid expedition ship: %',p_ship_id; END IF;
 SELECT u.expedition_speed INTO v_expedition_speed FROM public.universes u WHERE u.id=v_universe_id;
 IF v_expedition_speed IS NULL OR v_expedition_speed<=0 THEN RAISE EXCEPTION 'Invalid universe expedition speed'; END IF;
 v_evolution:=public.calculate_universe_evolution_rate(v_universe_id);
 v_rate:=v_expedition_speed*power(v_evolution,1.0/3.0);
 v_distance:=public.calculate_expedition_distance(p_origin_planet_id);
 -- OGameX/open-source formula: (35000/(speed_percent*10)*sqrt(distance*10/slowest_ship_speed)+10)/fleet_speed.
 -- We retain our dynamic expedition-speed multiplier as the final universe modifier.
 v_time_seconds:=((35000/(v_speed_percent*10))*sqrt(v_distance*10/v_ship_speed)+10)/v_rate;
 RETURN round(greatest(v_time_seconds,1),4);
END;
$function$;