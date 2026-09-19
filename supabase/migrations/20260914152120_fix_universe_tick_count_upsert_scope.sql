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
BEGIN
    CREATE TEMP TABLE _universe_tick_building_counts(
        planet_id uuid PRIMARY KEY,
        completed integer NOT NULL
    ) ON COMMIT DROP;

    CREATE TEMP TABLE _universe_tick_research_counts(
        player_id uuid PRIMARY KEY,
        completed integer NOT NULL
    ) ON COMMIT DROP;

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
            INSERT INTO _universe_tick_building_counts AS bc(planet_id, completed)
            VALUES (v_building.planet_id, 1)
            ON CONFLICT (planet_id)
            DO UPDATE SET completed = bc.completed + 1;
        ELSE
            PERFORM public.complete_research(v_research.id);
            INSERT INTO _universe_tick_research_counts AS rc(player_id, completed)
            VALUES (v_research.player_id, 1)
            ON CONFLICT (player_id)
            DO UPDATE SET completed = rc.completed + 1;
        END IF;
    END LOOP;

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