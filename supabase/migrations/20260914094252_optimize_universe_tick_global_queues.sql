CREATE OR REPLACE FUNCTION public.process_planet_tick_local(p_planet_id uuid)
RETURNS TABLE(
    planet_id uuid,
    metal numeric,
    crystal numeric,
    deuterium numeric,
    energy numeric,
    buildings_completed integer,
    researches_completed integer
)
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_metal numeric;
    v_crystal numeric;
    v_deuterium numeric;
    v_energy numeric;
BEGIN
    SELECT r.metal, r.crystal, r.deuterium, r.energy
    INTO v_metal, v_crystal, v_deuterium, v_energy
    FROM public.update_planet_resources(p_planet_id) r;

    PERFORM public.process_lifeform_tick(p_planet_id);
    PERFORM public.process_shipyard_queue(p_planet_id);

    RETURN QUERY
    SELECT p_planet_id, v_metal, v_crystal, v_deuterium, v_energy, 0, 0;
END;
$function$;

CREATE OR REPLACE FUNCTION public.process_planet_tick(p_planet_id uuid)
RETURNS TABLE(
    planet_id uuid,
    metal numeric,
    crystal numeric,
    deuterium numeric,
    energy numeric,
    buildings_completed integer,
    researches_completed integer
)
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_result RECORD;
    v_buildings_completed integer := 0;
    v_researches_completed integer := 0;
BEGIN
    SELECT * INTO v_result
    FROM public.process_planet_tick_local(p_planet_id);

    SELECT COUNT(*)
    INTO v_buildings_completed
    FROM public.process_building_queue() b
    WHERE b.planet_id = p_planet_id;

    SELECT COUNT(*)
    INTO v_researches_completed
    FROM public.process_research_queue() r
    WHERE r.player_id = (
        SELECT p.player_id
        FROM public.planets p
        WHERE p.id = p_planet_id
    );

    RETURN QUERY
    SELECT
        v_result.planet_id,
        v_result.metal,
        v_result.crystal,
        v_result.deuterium,
        v_result.energy,
        v_buildings_completed,
        v_researches_completed;
END;
$function$;

CREATE OR REPLACE FUNCTION public.process_universe_tick(p_universe_id uuid)
RETURNS TABLE(
    planet_id uuid,
    metal numeric,
    crystal numeric,
    deuterium numeric,
    energy numeric,
    buildings_completed integer,
    researches_completed integer
)
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_planet RECORD;
    v_result RECORD;
    v_buildings_completed integer := 0;
    v_researches_completed integer := 0;
    v_player_id uuid;
BEGIN
    CREATE TEMP TABLE _universe_tick_building_counts(
        planet_id uuid PRIMARY KEY,
        completed integer NOT NULL
    ) ON COMMIT DROP;

    CREATE TEMP TABLE _universe_tick_research_counts(
        player_id uuid PRIMARY KEY,
        completed integer NOT NULL
    ) ON COMMIT DROP;

    INSERT INTO _universe_tick_building_counts(planet_id, completed)
    SELECT b.planet_id, COUNT(*)::integer
    FROM public.process_building_queue() b
    WHERE EXISTS (
        SELECT 1
        FROM public.planets p
        WHERE p.id = b.planet_id
          AND p.universe_id = p_universe_id
    )
    GROUP BY b.planet_id;

    INSERT INTO _universe_tick_research_counts(player_id, completed)
    SELECT r.player_id, COUNT(*)::integer
    FROM public.process_research_queue() r
    WHERE EXISTS (
        SELECT 1
        FROM public.planets p
        WHERE p.player_id = r.player_id
          AND p.universe_id = p_universe_id
          AND NOT p.is_destroyed
    )
    GROUP BY r.player_id;

    FOR v_planet IN
        SELECT p.id, p.player_id
        FROM public.planets AS p
        WHERE p.universe_id = p_universe_id
          AND NOT p.is_destroyed
        ORDER BY p.created_at ASC
    LOOP
        SELECT * INTO v_result
        FROM public.process_planet_tick_local(v_planet.id);

        SELECT COALESCE(c.completed, 0)
        INTO v_buildings_completed
        FROM _universe_tick_building_counts c
        WHERE c.planet_id = v_planet.id;

        SELECT COALESCE(c.completed, 0)
        INTO v_researches_completed
        FROM _universe_tick_research_counts c
        WHERE c.player_id = v_planet.player_id;

        RETURN QUERY
        SELECT
            v_result.planet_id,
            v_result.metal,
            v_result.crystal,
            v_result.deuterium,
            v_result.energy,
            COALESCE(v_buildings_completed, 0),
            COALESCE(v_researches_completed, 0);
    END LOOP;
END;
$function$;