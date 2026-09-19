CREATE OR REPLACE FUNCTION public.calculate_ship_build_time(p_planet_id uuid, p_ship_id text)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_base_time numeric;
    v_shipyard_level integer;
    v_universe_id uuid;
    v_building_speed numeric;
    v_evolution numeric;
    v_building_rate numeric;
BEGIN
    SELECT p.universe_id INTO v_universe_id
    FROM public.planets p
    WHERE p.id = p_planet_id AND NOT p.is_destroyed;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Planet not found or destroyed';
    END IF;

    SELECT sd.base_build_time_seconds INTO v_base_time
    FROM public.ship_definitions sd
    WHERE sd.id = p_ship_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown ship: %', p_ship_id;
    END IF;

    SELECT COALESCE(pb.level, 0) INTO v_shipyard_level
    FROM public.planet_buildings pb
    WHERE pb.planet_id = p_planet_id
      AND pb.building_id = 'shipyard';

    v_shipyard_level := COALESCE(v_shipyard_level, 0);

    SELECT u.building_speed INTO v_building_speed
    FROM public.universes u
    WHERE u.id = v_universe_id;

    IF v_building_speed IS NULL OR v_building_speed <= 0 THEN
        RAISE EXCEPTION 'Invalid universe building speed';
    END IF;

    v_evolution := public.calculate_universe_evolution_rate(v_universe_id);
    v_building_rate := v_building_speed * sqrt(v_evolution);

    IF v_building_rate <= 0 THEN
        RAISE EXCEPTION 'Invalid effective building rate';
    END IF;

    RETURN round(
        (v_base_time / greatest(v_shipyard_level, 1)) / v_building_rate,
        4
    );
END;
$function$;