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
    v_player_id uuid;
    v_result record;
    v_building_id uuid;
    v_building_finishes_at timestamptz;
    v_research_id uuid;
    v_research_finishes_at timestamptz;
    v_building_completed integer := 0;
    v_researches_completed integer := 0;
BEGIN
    SELECT p.player_id
    INTO v_player_id
    FROM public.planets p
    WHERE p.id = p_planet_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'PLANET_NOT_FOUND';
    END IF;

    /*
     * Temporal correctness is critical here.
     *
     * A completed building/research can change resource production. Therefore
     * we must settle all completed economic events in chronological order
     * BEFORE advancing the planet's resource clock to now(). Each completion
     * function advances resources exactly to its own finishes_at boundary using
     * the old production rules, then applies the new level.
     *
     * This prevents the classic error:
     *   update resources to NOW -> complete an old building -> lose the
     *   production that should have existed after the building finished.
     */
    LOOP
        v_building_id := NULL;
        v_building_finishes_at := NULL;
        v_research_id := NULL;
        v_research_finishes_at := NULL;

        SELECT b.id, b.finishes_at
        INTO v_building_id, v_building_finishes_at
        FROM public.building_queue b
        WHERE b.planet_id = p_planet_id
          AND UPPER(b.status) = 'BUILDING'
          AND b.finishes_at <= now()
        ORDER BY b.finishes_at ASC, b.created_at ASC, b.id ASC
        LIMIT 1;

        IF v_player_id IS NOT NULL THEN
            SELECT r.id, r.finishes_at
            INTO v_research_id, v_research_finishes_at
            FROM public.research_queue r
            WHERE r.player_id = v_player_id
              AND UPPER(r.status) = 'RESEARCHING'
              AND r.finishes_at <= now()
            ORDER BY r.finishes_at ASC, r.created_at ASC, r.id ASC
            LIMIT 1;
        END IF;

        IF v_building_id IS NULL AND v_research_id IS NULL THEN
            EXIT;
        END IF;

        IF v_building_id IS NOT NULL
           AND (v_research_id IS NULL OR v_building_finishes_at <= v_research_finishes_at) THEN
            PERFORM public.complete_building(v_building_id);
            v_building_completed := v_building_completed + 1;
        ELSE
            PERFORM public.complete_research(v_research_id);
            v_researches_completed := v_researches_completed + 1;
        END IF;
    END LOOP;

    /* Resource clock can now safely advance to the present. */
    SELECT *
    INTO v_result
    FROM public.process_planet_tick_local(p_planet_id);

    RETURN QUERY
    SELECT
        v_result.planet_id,
        v_result.metal,
        v_result.crystal,
        v_result.deuterium,
        v_result.energy,
        v_building_completed,
        v_researches_completed;
END;
$function$;