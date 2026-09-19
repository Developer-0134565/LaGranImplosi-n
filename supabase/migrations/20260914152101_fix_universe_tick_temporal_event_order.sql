CREATE OR REPLACE FUNCTION public.process_building_queue_for_planet(p_planet_id uuid)
RETURNS TABLE(queue_id uuid, planet_id uuid, building_id text, completed_level integer)
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_queue record;
    v_completed_level integer;
BEGIN
    FOR v_queue IN
        SELECT bq.id, bq.planet_id, bq.building_id
        FROM public.building_queue AS bq
        WHERE bq.planet_id = p_planet_id
          AND UPPER(bq.status) = 'BUILDING'
          AND bq.finishes_at <= now()
        ORDER BY bq.finishes_at ASC, bq.created_at ASC, bq.id ASC
        FOR UPDATE SKIP LOCKED
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
        ORDER BY bq.finishes_at ASC, bq.created_at ASC, bq.id ASC
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
    v_building RECORD;
    v_research RECORD;
    v_building_completed integer := 0;
    v_research_completed integer := 0;
BEGIN
    CREATE TEMP TABLE _universe_tick_building_counts(
        planet_id uuid PRIMARY KEY,
        completed integer NOT NULL
    ) ON COMMIT DROP;

    CREATE TEMP TABLE _universe_tick_research_counts(
        player_id uuid PRIMARY KEY,
        completed integer NOT NULL
    ) ON COMMIT DROP;

    /*
     * Settle completed economic events globally in chronological order.
     * Building and research completions both change future production, so
     * processing one entire queue before the other can move a planet's
     * resource clock backwards. The previous implementation had exactly that
     * risk: all buildings were completed, then all researches.
     */
    LOOP
        v_building := NULL;
        v_research := NULL;

        SELECT bq.id, bq.finishes_at, bq.planet_id
        INTO v_building
        FROM public.building_queue bq
        JOIN public.planets p ON p.id = bq.planet_id
        WHERE p.universe_id = p_universe_id
          AND bq.status = 'BUILDING'
          AND bq.finishes_at <= now()
        ORDER BY bq.finishes_at ASC, bq.created_at ASC, bq.id ASC
        LIMIT 1;

        SELECT rq.id, rq.finishes_at, rq.player_id, rq.target_level
        INTO v_research
        FROM public.research_queue rq
        WHERE rq.status = 'RESEARCHING'
          AND rq.finishes_at <= now()
          AND EXISTS (
              SELECT 1
              FROM public.planets p
              WHERE p.player_id = rq.player_id
                AND p.universe_id = p_universe_id
                AND NOT p.is_destroyed
          )
        ORDER BY rq.finishes_at ASC, rq.created_at ASC, rq.id ASC
        LIMIT 1;

        IF v_building.id IS NULL AND v_research.id IS NULL THEN
            EXIT;
        END IF;

        IF v_building.id IS NOT NULL
           AND (v_research.id IS NULL OR v_building.finishes_at <= v_research.finishes_at) THEN
            PERFORM public.complete_building(v_building.id);
            INSERT INTO _universe_tick_building_counts(planet_id, completed)
            VALUES (v_building.planet_id, 1)
            ON CONFLICT (planet_id)
            DO UPDATE SET completed = _universe_tick_building_counts.completed + 1;
            v_building_completed := v_building_completed + 1;
        ELSE
            PERFORM public.complete_research(v_research.id);
            INSERT INTO _universe_tick_research_counts(player_id, completed)
            VALUES (v_research.player_id, 1)
            ON CONFLICT (player_id)
            DO UPDATE SET completed = _universe_tick_research_counts.completed + 1;
            v_research_completed := v_research_completed + 1;
        END IF;
    END LOOP;

    /*
     * Only after all completed economic events have been settled may we move
     * each planet's resource clock to NOW and process non-resource queues.
     */
    FOR v_planet IN
        SELECT p.id, p.player_id
        FROM public.planets AS p
        WHERE p.universe_id = p_universe_id
          AND NOT p.is_destroyed
        ORDER BY p.created_at ASC, p.id ASC
    LOOP
        SELECT * INTO v_result
        FROM public.process_planet_tick_local(v_planet.id);

        RETURN QUERY
        SELECT
            v_result.planet_id,
            v_result.metal,
            v_result.crystal,
            v_result.deuterium,
            v_result.energy,
            COALESCE((SELECT c.completed FROM _universe_tick_building_counts c WHERE c.planet_id = v_planet.id), 0),
            COALESCE((SELECT c.completed FROM _universe_tick_research_counts c WHERE c.player_id = v_planet.player_id), 0);
    END LOOP;
END;
$function$;