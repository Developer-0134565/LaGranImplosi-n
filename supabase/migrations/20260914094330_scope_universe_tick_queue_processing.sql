CREATE OR REPLACE FUNCTION public.process_building_queue_for_universe(p_universe_id uuid)
RETURNS TABLE(queue_id uuid, planet_id uuid, building_id text, completed_level integer)
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_queue RECORD;
    v_completed_level integer;
BEGIN
    FOR v_queue IN
        SELECT bq.id, bq.planet_id, bq.building_id
        FROM public.building_queue AS bq
        JOIN public.planets AS p ON p.id = bq.planet_id
        WHERE p.universe_id = p_universe_id
          AND bq.status = 'BUILDING'
          AND bq.finishes_at <= now()
        ORDER BY bq.created_at ASC
        FOR UPDATE OF bq SKIP LOCKED
    LOOP
        v_completed_level := public.complete_building(v_queue.id);
        queue_id := v_queue.id;
        planet_id := v_queue.planet_id;
        building_id := v_queue.building_id;
        completed_level := v_completed_level;
        RETURN NEXT;
    END LOOP;
END;
$function$;

CREATE OR REPLACE FUNCTION public.process_research_queue_for_universe(p_universe_id uuid)
RETURNS TABLE(queue_id uuid, player_id uuid, research_id text, completed_level integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_queue RECORD;
    v_completed boolean;
    v_level integer;
BEGIN
    FOR v_queue IN
        SELECT DISTINCT rq.id, rq.player_id, rq.research_id, rq.target_level
        FROM public.research_queue AS rq
        JOIN public.planets AS p ON p.player_id = rq.player_id
        WHERE p.universe_id = p_universe_id
          AND NOT p.is_destroyed
          AND UPPER(rq.status) = 'RESEARCHING'
          AND rq.finishes_at <= now()
        ORDER BY rq.finishes_at ASC
        FOR UPDATE OF rq SKIP LOCKED
    LOOP
        v_completed := public.complete_research(v_queue.id);
        IF v_completed THEN
            v_level := v_queue.target_level;
            queue_id := v_queue.id;
            player_id := v_queue.player_id;
            research_id := v_queue.research_id;
            completed_level := v_level;
            RETURN NEXT;
        END IF;
    END LOOP;
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
    FROM public.process_building_queue_for_universe(p_universe_id) b
    GROUP BY b.planet_id;

    INSERT INTO _universe_tick_research_counts(player_id, completed)
    SELECT r.player_id, COUNT(*)::integer
    FROM public.process_research_queue_for_universe(p_universe_id) r
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